-- ============================================================
-- UAT fixtures refresh v2: also seeds payable_shift_records for the
-- past fixture days so get_location_attendance_overview has data.
-- UAT Entity A/B only; postgres-only; re-runnable.
-- ============================================================

create or replace function public.uat_fixtures_refresh()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_ea  constant uuid := 'a0000000-0000-4000-8000-000000000001';
  c_eb  constant uuid := 'a0000000-0000-4000-8000-000000000002';
  c_la1 constant uuid := 'a0000000-0000-4000-8000-000000000011';
  c_la2 constant uuid := 'a0000000-0000-4000-8000-000000000012';
  c_lb1 constant uuid := 'a0000000-0000-4000-8000-000000000013';
  c_pos_barista constant uuid := 'a0000000-0000-4000-8000-000000000021';
  c_pos_lm      constant uuid := 'a0000000-0000-4000-8000-000000000023';
  c_pos_tea     constant uuid := 'a0000000-0000-4000-8000-000000000024';
  c_emp_a  constant uuid := 'a0000000-0000-4000-8000-000000000031';
  c_emp_b  constant uuid := 'a0000000-0000-4000-8000-000000000032';
  c_emp_c  constant uuid := 'a0000000-0000-4000-8000-000000000033';
  c_emp_lm constant uuid := 'a0000000-0000-4000-8000-000000000034';
  c_emp_ns constant uuid := 'a0000000-0000-4000-8000-000000000035';
  c_lt_a_annual constant uuid := 'a0000000-0000-4000-8000-000000000041';
  c_lt_a_sick   constant uuid := 'a0000000-0000-4000-8000-000000000042';
  c_lt_b_annual constant uuid := 'a0000000-0000-4000-8000-000000000043';
  c_ecr_pending constant uuid := 'a0000000-0000-4000-8000-000000000092';
  c_leave_pending constant uuid := 'a0000000-0000-4000-8000-000000000101';
  c_doc_expiring constant uuid := 'a0000000-0000-4000-8000-000000000111';
  c_doc_renewal  constant uuid := 'a0000000-0000-4000-8000-000000000112';
  c_doc_visa_a   constant uuid := '31ac51d1-1fd4-4cb4-b6a9-cbbbcf463c25';
  c_run_pub   constant uuid := 'a0000000-0000-4000-8000-000000000201';
  c_run_draft constant uuid := 'a0000000-0000-4000-8000-000000000202';
  c_grant_ns  constant uuid := 'a0000000-0000-4000-8000-000000000301';
  c_rule_ids  constant uuid[] := array[
    'a0000000-0000-4000-8000-000000000401', 'a0000000-0000-4000-8000-000000000402',
    'a0000000-0000-4000-8000-000000000403', 'a0000000-0000-4000-8000-000000000404',
    'a0000000-0000-4000-8000-000000000405', 'a0000000-0000-4000-8000-000000000406',
    'a0000000-0000-4000-8000-000000000407', 'a0000000-0000-4000-8000-000000000411']::uuid[];
  c_tag constant text := 'UAT fixture';

  v_owner uuid;
  v_ea_admin uuid;
  v_emp_a_user uuid;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_week date;
  v_prev_month_start date;
  v_month_start date;
  d date;
  i integer;
  r record;
  v_shift uuid;
  v_bounds record;
  v_shift_count integer := 0;
  v_att_count integer := 0;
  v_run_id uuid;
  v_run_status text;
  v_pub_run uuid;
  v_draft_run uuid;
begin
  if session_user not in ('postgres', 'supabase_admin') then
    raise exception 'uat_fixtures_refresh may only be run by postgres' using errcode = '42501';
  end if;
  if (select count(*) from public.entities where id in (c_ea, c_eb) and name in ('UAT Entity A', 'UAT Entity B')) <> 2 then
    raise exception 'UAT entities not found with expected names; refusing to seed';
  end if;

  select id into v_owner from auth.users where email = 'uat.owner@example.com';
  select id into v_ea_admin from auth.users where email = 'uat.entityadmin.a@example.com';
  select id into v_emp_a_user from auth.users where email = 'uat.employee.a@example.com';
  if v_owner is null or v_ea_admin is null or v_emp_a_user is null then
    raise exception 'UAT users missing; refusing to seed';
  end if;

  -- Act as the UAT owner for the rest of this transaction so every
  -- trigger / RPC records a real actor (auth.uid()) and audit rows are
  -- attributed to the UAT owner, never to a real account.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  perform set_config('tshr.uat_maintenance', 'on', true);

  v_week := date_trunc('week', v_today)::date;                 -- Monday of this week
  v_month_start := date_trunc('month', v_today)::date;
  v_prev_month_start := (v_month_start - interval '1 month')::date;

  -- Quiet fixture workflow rules while shifts are rebuilt (no notification spam).
  update public.workflow_rules set is_active = false where id = any(c_rule_ids);

  -- ----------------------------------------------------------
  -- Employees: new starter (pre_boarding) for the pending grant
  -- ----------------------------------------------------------
  insert into public.employees (id, entity_id, home_location_id, position_id, full_name, email, phone,
                                employment_type, employment_status, join_date, notes)
  values (c_emp_ns, c_ea, c_la1, c_pos_barista, 'UAT New Starter', 'uat.newstarter@example.com', '+971500000035',
          'full_time', 'pre_boarding', v_today + 14, c_tag)
  on conflict (id) do nothing;

  -- ----------------------------------------------------------
  -- Compensation + identity (used by payroll and negative-access tests)
  -- ----------------------------------------------------------
  insert into public.employee_compensation (employee_id, pay_type, pay_rate, overtime_multiplier, holiday_multiplier)
  values (c_emp_a, 'hourly', 35, 1.5, 2), (c_emp_b, 'hourly', 35, 1.5, 2), (c_emp_c, 'hourly', 30, 1.5, 2),
         (c_emp_lm, 'monthly', 9000, 1.5, 2), (c_emp_ns, 'hourly', 30, 1.5, 2)
  on conflict (employee_id) do update
    set pay_type = excluded.pay_type, pay_rate = excluded.pay_rate,
        overtime_multiplier = excluded.overtime_multiplier, holiday_multiplier = excluded.holiday_multiplier;

  insert into public.employee_identity_documents (employee_id, passport_no, visa_no, labor_card_no, bank_name, bank_iban)
  values (c_emp_a, 'UATP0000031', 'UATV0000031', 'UATL0000031', 'UAT Bank', 'AE000000000000000000031'),
         (c_emp_b, 'UATP0000032', 'UATV0000032', 'UATL0000032', 'UAT Bank', 'AE000000000000000000032'),
         (c_emp_c, 'UATP0000033', 'UATV0000033', 'UATL0000033', 'UAT Bank', 'AE000000000000000000033')
  on conflict (employee_id) do nothing;

  -- ----------------------------------------------------------
  -- Shifts: last / this / next week (published) + 1 draft
  -- ----------------------------------------------------------
  delete from public.notifications n
   where n.entity_id in (c_ea, c_eb) and n.target_type = 'shifts'
     and n.target_id in (select s.id from public.shifts s where s.entity_id in (c_ea, c_eb) and s.notes like c_tag || '%');
  delete from public.attendance_records a
   where a.entity_id in (c_ea, c_eb)
     and a.shift_id in (select s.id from public.shifts s where s.entity_id in (c_ea, c_eb) and s.notes like c_tag || '%');
  delete from public.timesheet_entry_sources tes
   using public.payable_shift_records p, public.shifts s
   where tes.payable_shift_record_id = p.id and p.shift_id = s.id
     and s.entity_id in (c_ea, c_eb) and s.notes like c_tag || '%';
  delete from public.shifts s where s.entity_id in (c_ea, c_eb) and s.notes like c_tag || '%';

  for r in
    select * from (values
      (c_emp_a,  c_ea, c_la1, c_pos_barista, time '09:00', time '17:00', 6),
      (c_emp_b,  c_ea, c_la2, c_pos_barista, time '12:00', time '20:00', 6),
      (c_emp_c,  c_eb, c_lb1, c_pos_tea,     time '10:00', time '18:00', 6),
      (c_emp_lm, c_ea, c_la1, c_pos_lm,      time '08:00', time '16:00', 5)
    ) as t(emp, ent, loc, pos, st, et, days_per_week)
  loop
    for i in 0..20 loop
      d := v_week - 7 + i;
      if extract(isodow from d) <= r.days_per_week then
        insert into public.shifts (entity_id, location_id, position_id, employee_id, shift_date, start_time, end_time,
                                   status, notes, created_by, is_published)
        values (r.ent, r.loc, r.pos, r.emp, d, r.st, r.et, 'assigned', c_tag, v_owner, true);
        v_shift_count := v_shift_count + 1;
      end if;
    end loop;
  end loop;

  -- Draft (unpublished) shift next Sunday for employee A: not staff-visible.
  insert into public.shifts (entity_id, location_id, position_id, employee_id, shift_date, start_time, end_time,
                             status, notes, created_by, is_published)
  values (c_ea, c_la1, c_pos_barista, c_emp_a, v_week + 13, time '10:00', time '14:00', 'assigned',
          c_tag || ' (draft)', v_owner, false);

  -- ----------------------------------------------------------
  -- Workflow rules: one active rule per trigger (Entity A) + Entity B
  -- ----------------------------------------------------------
  insert into public.workflow_rules (id, entity_id, name, module, trigger_event, condition_field, condition_operator,
                                     condition_value, action_type, action_target_role, action_message_template,
                                     is_active, created_by, activated_at)
  values
    (c_rule_ids[1], c_ea, 'UAT: leave request needs review', 'leave', 'leave_submitted', 'days_requested', 'gte', '1',
     'notify_role', 'location_manager', 'A leave request is waiting for your review.', true, v_owner, now()),
    (c_rule_ids[2], c_ea, 'UAT: document expiring within 30 days', 'document', 'document_expiring_soon', 'days_to_expiry', 'lte', '30',
     'notify_role', 'entity_admin', 'A staff document expires within 30 days.', true, v_owner, now()),
    (c_rule_ids[3], c_ea, 'UAT: document submitted for review', 'document', 'submitted_for_review', null, null, null,
     'notify_role', 'entity_admin', 'A document was submitted and is waiting for review.', true, v_owner, now()),
    (c_rule_ids[4], c_ea, 'UAT: late clock-in (10+ min)', 'attendance', 'late_clock_in', 'late_minutes', 'gte', '10',
     'notify_role', 'location_manager', 'A team member clocked in late.', true, v_owner, now()),
    (c_rule_ids[5], c_ea, 'UAT: schedule published', 'schedule', 'schedule_published', null, null, null,
     'notify_employee', null, 'Your schedule has been published.', true, v_owner, now()),
    (c_rule_ids[6], c_ea, 'UAT: shift changed', 'schedule', 'shift_adjusted', null, null, null,
     'notify_employee', null, 'One of your published shifts was changed.', true, v_owner, now()),
    (c_rule_ids[7], c_ea, 'UAT: payslip published', 'payroll', 'payslip_published', null, null, null,
     'notify_employee', null, 'Your payslip is ready to view.', true, v_owner, now()),
    (c_rule_ids[8], c_eb, 'UAT B: leave request submitted', 'leave', 'leave_submitted', null, null, null,
     'notify_role', 'entity_admin', 'A leave request was submitted.', true, v_owner, now())
  on conflict (id) do update set
    entity_id = excluded.entity_id, name = excluded.name, module = excluded.module,
    trigger_event = excluded.trigger_event, condition_field = excluded.condition_field,
    condition_operator = excluded.condition_operator, condition_value = excluded.condition_value,
    action_type = excluded.action_type, action_target_role = excluded.action_target_role,
    action_message_template = excluded.action_message_template, is_active = true,
    activated_at = now(), deactivated_at = null, updated_at = now();

  -- ----------------------------------------------------------
  -- Attendance for the 5 business days before today.
  --   employee A: late (+17 min) two days ago
  --   employee B: missing clock-out yesterday (open record)
  -- ----------------------------------------------------------
  for r in
    select s.id, s.entity_id, s.location_id, s.employee_id, s.shift_date, s.start_time, s.end_time
      from public.shifts s
     where s.entity_id in (c_ea, c_eb) and s.notes = c_tag
       and s.shift_date between v_today - 5 and v_today - 1
     order by s.shift_date, s.employee_id
  loop
    select * into v_bounds from public._shift_planned_bounds(r.shift_date, r.start_time, r.end_time);
    if r.employee_id = c_emp_b and r.shift_date = (
         select max(s2.shift_date) from public.shifts s2
          where s2.employee_id = c_emp_b and s2.notes = c_tag and s2.shift_date < v_today) then
      insert into public.attendance_records (entity_id, location_id, employee_id, shift_id, clock_in_at, clock_out_at)
      values (r.entity_id, r.location_id, r.employee_id, r.id, v_bounds.planned_start - interval '3 minutes', null);
    elsif r.employee_id = c_emp_a and r.shift_date = (
         select max(s2.shift_date) from public.shifts s2
          where s2.employee_id = c_emp_a and s2.notes = c_tag and s2.shift_date < v_today - 1) then
      insert into public.attendance_records (entity_id, location_id, employee_id, shift_id, clock_in_at, clock_out_at)
      values (r.entity_id, r.location_id, r.employee_id, r.id, v_bounds.planned_start + interval '17 minutes',
              v_bounds.planned_end + interval '5 minutes');
    else
      insert into public.attendance_records (entity_id, location_id, employee_id, shift_id, clock_in_at, clock_out_at)
      values (r.entity_id, r.location_id, r.employee_id, r.id, v_bounds.planned_start - interval '4 minutes',
              v_bounds.planned_end + interval '2 minutes');
    end if;
    v_att_count := v_att_count + 1;
  end loop;

  -- Payable-time records for the past days so the manager attendance
  -- overview has data (same RPC managers use; idempotent per shift).
  perform public.seed_payable_shift_records(c_la1, v_week - 7, v_today - 1);
  perform public.seed_payable_shift_records(c_la2, v_week - 7, v_today - 1);
  perform public.seed_payable_shift_records(c_lb1, v_week - 7, v_today - 1);

  -- ----------------------------------------------------------
  -- Leave: fixed balances + one pending request (employee A)
  -- ----------------------------------------------------------
  delete from public.leave_requests where id = c_leave_pending;
  insert into public.leave_balances (employee_id, leave_type_id, balance_days)
  values (c_emp_a, c_lt_a_annual, 17), (c_emp_a, c_lt_a_sick, 10.83),
         (c_emp_b, c_lt_a_annual, 21), (c_emp_b, c_lt_a_sick, 10.83),
         (c_emp_lm, c_lt_a_annual, 21), (c_emp_lm, c_lt_a_sick, 10.83),
         (c_emp_ns, c_lt_a_annual, 0), (c_emp_ns, c_lt_a_sick, 0),
         (c_emp_c, c_lt_b_annual, 21)
  on conflict (employee_id, leave_type_id) do update set balance_days = excluded.balance_days, updated_at = now();

  -- Inserting as pending reserves the balance (log_leave_request_changes).
  insert into public.leave_requests (id, employee_id, leave_type_id, start_date, end_date, days_requested, status, reason)
  values (c_leave_pending, c_emp_a, c_lt_a_annual, v_week + 21, v_week + 22, 2, 'pending', 'UAT fixture: family visit');

  -- ----------------------------------------------------------
  -- Documents: B passport expiring in 20 days (approved, current);
  --            A visa renewal Pending Review (supersedes current visa)
  -- ----------------------------------------------------------
  delete from public.employee_documents where id = c_doc_renewal and review_status = 'pending_review';
  if not exists (select 1 from public.employee_documents where supersedes_document_id = c_doc_expiring) then
    delete from public.employee_documents where id = c_doc_expiring;
    insert into public.employee_documents (id, employee_id, doc_type, expiry_date, notes, review_status, is_current,
                                           storage_path, submitted_by, submitted_at, reviewed_by, reviewed_at,
                                           uploaded_by, upload_confirmed, upload_confirmed_at)
    values (c_doc_expiring, c_emp_b, 'passport', v_today + 20, c_tag, 'approved', true,
            'uat-fixtures/placeholder-passport-employee-b.pdf', v_ea_admin, now(), v_owner, now(),
            v_ea_admin, true, now());
  end if;

  if exists (select 1 from public.employee_documents
              where id = c_doc_visa_a and is_current and review_status = 'approved')
     and not exists (select 1 from public.employee_documents where id = c_doc_renewal) then
    insert into public.employee_documents (id, employee_id, doc_type, expiry_date, notes, review_status, is_current,
                                           version_number, supersedes_document_id, storage_path, submitted_by,
                                           submitted_at, uploaded_by, upload_confirmed, upload_confirmed_at)
    values (c_doc_renewal, c_emp_a, 'visa', v_today + 730, c_tag || ': visa renewal', 'pending_review', false,
            1, c_doc_visa_a, 'uat-fixtures/placeholder-visa-renewal-employee-a.pdf', v_emp_a_user,
            now(), v_emp_a_user, true, now());
  end if;

  -- ----------------------------------------------------------
  -- Payroll (Entity A): PUBLISHED previous month + DRAFT current month.
  -- One original run per entity/period is allowed, so an existing UAT
  -- run for the period is reused. A draft is rebuilt; an already
  -- published run is immutable and left exactly as it is.
  -- ----------------------------------------------------------
  select pr.id, pr.status into v_run_id, v_run_status from public.payroll_runs pr
   where pr.entity_id = c_ea and pr.revises_payroll_run_id is null
     and pr.period_start = v_prev_month_start and pr.period_end = v_month_start - 1;
  if v_run_id is null then
    v_run_id := c_run_pub;
    insert into public.payroll_runs (id, entity_id, period_start, period_end, status, tip_distribution_rule, created_by,
                                     overtime_holiday_pay_confirmed, tips_distribution_confirmed)
    values (v_run_id, c_ea, v_prev_month_start, v_month_start - 1, 'draft', 'equal', v_owner, true, true);
    v_run_status := 'draft';
  end if;
  if v_run_status in ('draft', 'in_review') then
    delete from public.payslips where payroll_run_id = v_run_id;
    delete from public.payslip_deductions where payroll_run_id = v_run_id;
    delete from public.tips_pools where payroll_run_id = v_run_id;
    delete from public.timesheet_entries where payroll_run_id = v_run_id;
    update public.payroll_runs set status = 'draft', overtime_holiday_pay_confirmed = true,
                                   tips_distribution_confirmed = true, tip_distribution_rule = 'equal'
     where id = v_run_id;
    insert into public.timesheet_entries (payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes)
    values (v_run_id, c_emp_a, 160, 4, 0, c_tag), (v_run_id, c_emp_b, 150, 0, 8, c_tag),
           (v_run_id, c_emp_lm, 0, 0, 0, c_tag);
    insert into public.tips_pools (payroll_run_id, location_id, total_amount, notes)
    values (v_run_id, c_la1, 900, c_tag);
    insert into public.payslip_deductions (payroll_run_id, employee_id, deduction_type, amount, notes)
    values (v_run_id, c_emp_a, 'uniform', 50, 'UAT fixture: uniform replacement');
    perform public.run_payroll_calculation(v_run_id);
    update public.payroll_runs set status = 'approved', approved_by = v_owner, approved_at = now() where id = v_run_id;
  end if;
  v_pub_run := v_run_id;

  v_run_id := null; v_run_status := null;
  select pr.id, pr.status into v_run_id, v_run_status from public.payroll_runs pr
   where pr.entity_id = c_ea and pr.revises_payroll_run_id is null
     and pr.period_start = v_month_start and pr.period_end = (v_month_start + interval '1 month')::date - 1;
  if v_run_id is null then
    v_run_id := c_run_draft;
    insert into public.payroll_runs (id, entity_id, period_start, period_end, status, tip_distribution_rule, created_by,
                                     overtime_holiday_pay_confirmed, tips_distribution_confirmed)
    values (v_run_id, c_ea, v_month_start, (v_month_start + interval '1 month')::date - 1, 'draft', 'equal', v_owner,
            true, true);
    v_run_status := 'draft';
  end if;
  if v_run_status in ('draft', 'in_review') then
    delete from public.payslips where payroll_run_id = v_run_id;
    delete from public.payslip_deductions where payroll_run_id = v_run_id;
    delete from public.tips_pools where payroll_run_id = v_run_id;
    delete from public.timesheet_entries where payroll_run_id = v_run_id;
    update public.payroll_runs set status = 'draft', overtime_holiday_pay_confirmed = true,
                                   tips_distribution_confirmed = true, tip_distribution_rule = 'equal'
     where id = v_run_id;
    insert into public.timesheet_entries (payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes)
    values (v_run_id, c_emp_a, 120, 2, 0, c_tag), (v_run_id, c_emp_b, 110, 0, 0, c_tag),
           (v_run_id, c_emp_lm, 0, 0, 0, c_tag);
    insert into public.tips_pools (payroll_run_id, location_id, total_amount, notes)
    values (v_run_id, c_la1, 600, c_tag);
    perform public.run_payroll_calculation(v_run_id);
  end if;
  v_draft_run := v_run_id;

  -- ----------------------------------------------------------
  -- Access: pending grant for uat.newstarter (staff, Entity A)
  -- ----------------------------------------------------------
  if not exists (select 1 from public.access_grants where id = c_grant_ns and status = 'applied') then
    delete from public.access_grants where id = c_grant_ns;
    if not exists (select 1 from public.access_grants where email = 'uat.newstarter@example.com' and status = 'pending') then
      insert into public.access_grants (id, email, role, entity_id, location_id, employee_id, status, granted_by, granted_at)
      values (c_grant_ns, 'uat.newstarter@example.com', 'staff', c_ea, c_la1, c_emp_ns, 'pending', v_owner, now());
    end if;
  end if;

  -- ----------------------------------------------------------
  -- Pending employee change request (employee B)
  -- ----------------------------------------------------------
  insert into public.employee_change_requests (id, employee_id, field_name, old_value, new_value, reason, status, requested_at)
  values (c_ecr_pending, c_emp_b, 'emergency_contact_phone', null, '+971501234567',
          'UAT fixture: new emergency contact number', 'pending', now())
  on conflict (id) do update set status = 'pending', new_value = excluded.new_value, decided_by = null,
                                 decided_at = null, decision_reason = null, requested_at = now();

  perform set_config('tshr.uat_maintenance', '', true);
  perform set_config('request.jwt.claims', '', true);

  return jsonb_build_object(
    'business_date', v_today, 'week_start', v_week,
    'shifts_published', v_shift_count, 'draft_shifts', 1, 'attendance_records', v_att_count,
    'pending_leave_request', c_leave_pending, 'expiring_document', c_doc_expiring,
    'pending_renewal', c_doc_renewal, 'published_run', v_pub_run, 'draft_run', v_draft_run,
    'pending_grant', c_grant_ns, 'pending_change_request', c_ecr_pending,
    'workflow_rules', to_jsonb(c_rule_ids));
end;
$$;
revoke all on function public.uat_fixtures_refresh() from public, anon, authenticated;

select public.uat_fixtures_refresh();
