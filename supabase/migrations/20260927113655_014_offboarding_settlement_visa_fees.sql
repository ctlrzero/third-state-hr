-- =====================================================================
-- Migration 014 — link the final settlement to a real payroll run
-- (instead of a hand-ticked checklist item), and record visa/work-permit
-- fees. Depends on: 001–013, payroll v2 (payroll_open_off_cycle,
-- payroll_prepare, _payroll_money).
-- =====================================================================

-- --------------------------------------------------------- settlement
alter table public.offboarding_cases
  add column if not exists settlement_payroll_period_id uuid references public.payroll_periods(id);

-- Opens (or returns the existing) off-cycle payroll period for this
-- leaver's final settlement and prepares it, so HR/payroll work the real
-- payslip instead of a separate reminder. Idempotent per case.
create or replace function public.start_offboarding_settlement(p_case_id uuid, p_pay_date date default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  c public.offboarding_cases;
  e public.employees;
  v_period uuid;
  v_prep jsonb;
begin
  select * into c from public.offboarding_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  if not (public._off_can(c.id, 'manage') or public._off_can(c.id, 'payroll')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if c.status <> 'open' then raise exception 'This offboarding is closed' using errcode = '22023'; end if;
  if c.settlement_payroll_period_id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'period_id', c.settlement_payroll_period_id);
  end if;
  select * into e from public.employees where id = c.employee_id;
  -- payroll_open_off_cycle re-checks the caller's own payroll 'prepare' capability.
  v_period := public.payroll_open_off_cycle(c.entity_id, coalesce(p_pay_date, c.settlement_due_date),
    'Final settlement – ' || e.full_name);
  v_prep := public.payroll_prepare(v_period, array[e.id]);
  update public.offboarding_cases set settlement_payroll_period_id = v_period, row_version = row_version + 1, updated_at = now()
   where id = c.id;
  perform public._off_audit(c, c.id, 'offboarding_settlement_started', null,
    jsonb_build_object('period_id', v_period, 'pay_date', coalesce(p_pay_date, c.settlement_due_date)));
  return jsonb_build_object('ok', true, 'already', false, 'period_id', v_period, 'prepare_result', v_prep);
end;
$$;

-- Follows the linked payroll record's real payment status, the same way
-- onboarding tasks follow their source records — the checklist cannot be
-- ticked by hand once a payroll run is linked (the "not needed" override
-- with a reason from an HR/owner login is still available if the
-- settlement is genuinely handled outside the app).
create or replace function public._off_sync_settlement(p_case_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare c public.offboarding_cases; v_status text;
begin
  select * into c from public.offboarding_cases where id = p_case_id;
  if c.id is null or c.settlement_payroll_period_id is null then return; end if;
  select m.payment_status into v_status
    from public.payroll_records r
    cross join lateral public._payroll_money(r.id) m
   where r.period_id = c.settlement_payroll_period_id and r.employee_id = c.employee_id
     and r.superseded_by_record_id is null;
  if v_status = 'paid' then
    update public.offboarding_tasks set status = 'done', completed_by = null, completed_at = coalesce(completed_at, now()),
           notes = coalesce(notes, 'Paid through payroll')
     where case_id = c.id and item_key = 'final_settlement' and status = 'not_started';
  end if;
end;
$$;

-- ------------------------------------------------------------ visa fees
alter table public.employee_immigration_steps
  add column if not exists fee_amount numeric(10,2) check (fee_amount is null or fee_amount >= 0),
  add column if not exists fee_paid_by text check (fee_paid_by is null or fee_paid_by in ('company', 'employee'));

drop function if exists public.update_immigration_step(uuid, text, text, date, date, text);
create or replace function public.update_immigration_step(p_step_id uuid, p_status text, p_reference text default null,
  p_expiry_date date default null, p_due_date date default null, p_notes text default null,
  p_fee_amount numeric default null, p_fee_paid_by text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare s public.employee_immigration_steps; c public.employee_immigration_cases;
begin
  select * into s from public.employee_immigration_steps where id = p_step_id for update;
  if s.id is null then raise exception 'Step not found' using errcode = 'P0002'; end if;
  select * into c from public.employee_immigration_cases where id = s.case_id;
  perform public._imm_require(c.entity_id);
  if c.status <> 'open' then raise exception 'This case is closed' using errcode = '22023'; end if;
  if p_status not in ('not_started', 'in_progress', 'done', 'not_needed', 'failed') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if p_status in ('not_needed', 'failed') and nullif(btrim(coalesce(p_notes, '')), '') is null then
    raise exception 'Add a note saying why' using errcode = '22023';
  end if;
  if p_fee_amount is not null and p_fee_paid_by is null then
    raise exception 'Say who paid the fee (company or employee)' using errcode = '22023';
  end if;
  update public.employee_immigration_steps set status = p_status,
         reference_number = coalesce(nullif(btrim(coalesce(p_reference, '')), ''), reference_number),
         expiry_date = coalesce(p_expiry_date, expiry_date), due_date = coalesce(p_due_date, due_date),
         notes = coalesce(nullif(btrim(coalesce(p_notes, '')), ''), notes),
         fee_amount = coalesce(p_fee_amount, fee_amount), fee_paid_by = coalesce(p_fee_paid_by, fee_paid_by),
         started_at = case when p_status = 'in_progress' and started_at is null then now() else started_at end,
         completed_at = case when p_status = 'done' then now() when p_status in ('not_started', 'in_progress') then null else completed_at end,
         updated_by = auth.uid(), updated_at = now()
   where id = s.id;
  if p_status = 'done' and nullif(btrim(coalesce(p_reference, '')), '') is not null then
    update public.employee_immigration_cases set
      work_permit_number = case when s.step_key = 'work_permit' then btrim(p_reference) else work_permit_number end,
      uid_number = case when s.step_key in ('entry_permit', 'residence_visa') and uid_number is null then btrim(p_reference) else uid_number end,
      visa_file_number = case when s.step_key = 'residence_visa' then btrim(p_reference) else visa_file_number end,
      updated_at = now()
     where id = c.id;
  end if;
  perform public._imm_audit(c, s.id, 'immigration_step_updated', jsonb_build_object('step', s.step_key, 'status', s.status),
    jsonb_build_object('step', s.step_key, 'status', p_status, 'reference', p_reference, 'expiry_date', p_expiry_date,
      'notes', p_notes, 'fee_amount', p_fee_amount, 'fee_paid_by', p_fee_paid_by));
  if c.onboarding_instance_id is not null then perform public._onb_touch(c.onboarding_instance_id); perform public._onb_recompute(c.onboarding_instance_id); end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- Company-paid visa/permit cost total (for one case, or a company total).
create or replace function public.immigration_cost_summary(p_entity_id uuid, p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_from date := coalesce(p_from, (now() at time zone 'Asia/Dubai')::date - 365); v_to date := coalesce(p_to, (now() at time zone 'Asia/Dubai')::date);
begin
  perform public._imm_require(p_entity_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object('employee_id', x.employee_id, 'name', x.name, 'case_id', x.case_id,
        'company_paid', x.company_paid, 'employee_paid', x.employee_paid) order by x.opened_at desc)
      from (
        select c.id as case_id, e.id as employee_id, e.full_name as name, c.opened_at,
               coalesce(sum(s.fee_amount) filter (where s.fee_paid_by = 'company'), 0) as company_paid,
               coalesce(sum(s.fee_amount) filter (where s.fee_paid_by = 'employee'), 0) as employee_paid
          from public.employee_immigration_cases c
          join public.employees e on e.id = c.employee_id
          join public.employee_immigration_steps s on s.case_id = c.id
         where c.entity_id = p_entity_id and s.fee_amount is not null
           and c.opened_at::date between v_from and v_to
         group by c.id, e.id, e.full_name
      ) x), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------- read hooks
-- get_offboarding_case: sync the settlement task from the real payroll
-- record before returning, and expose the linked period id.
create or replace function public.get_offboarding_case(p_case_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  c public.offboarding_cases;
  e public.employees;
  v_hr boolean;
  v_pay boolean;
  v_grat jsonb;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  select * into c from public.offboarding_cases where id = p_case_id;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  if not public._off_can(c.id, 'view') then raise exception 'Not authorized' using errcode = '42501'; end if;
  perform public._off_sync_settlement(c.id);
  v_hr := public._off_can(c.id, 'manage');
  v_pay := public._off_can(c.id, 'payroll');
  select * into e from public.employees where id = c.employee_id;
  if v_pay then
    begin
      v_grat := public.payroll_gratuity_preview(e.id, c.last_working_date);
    exception when others then v_grat := jsonb_build_object('ok', false, 'reason', sqlerrm);
    end;
  end if;
  return jsonb_build_object(
    'case', (to_jsonb(c) - 'reason' - 'notice_shortfall_reason')
            || case when v_hr then jsonb_build_object('reason', c.reason, 'notice_shortfall_reason', c.notice_shortfall_reason) else '{}'::jsonb end,
    'employee', jsonb_build_object('id', e.id, 'name', e.full_name, 'employee_number', e.employee_number, 'join_date', e.join_date,
      'employment_status', e.employment_status,
      'branch', (select name from public.locations where id = e.home_location_id),
      'position', (select title from public.positions where id = e.position_id)),
    'permissions', jsonb_build_object('manage', v_hr, 'payroll', v_pay, 'operate', public._off_can(c.id, 'operate')),
    'notice_days', c.last_working_date - c.notice_date,
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'item_key', t.item_key, 'label', t.label, 'owner_role', t.owner_role,
        'is_required', t.is_required, 'status', t.status, 'due_date', t.due_date, 'notes', t.notes, 'completed_at', t.completed_at,
        'overdue', t.status = 'not_started' and t.due_date < v_today) order by t.sort_order)
      from public.offboarding_tasks t where t.case_id = c.id
       and (v_hr or v_pay or t.owner_role = 'location_manager')), '[]'::jsonb),
    'future_published_shifts', (select count(*) from public.shifts s where s.employee_id = e.id and s.shift_date > c.last_working_date
                                  and s.is_published and s.status <> 'cancelled'),
    'settlement', case when v_pay then jsonb_build_object('due_date', c.settlement_due_date, 'gratuity', v_grat,
      'payroll_period_id', c.settlement_payroll_period_id,
      'leave_balances', coalesce((select jsonb_agg(jsonb_build_object('leave_type', lt.name, 'balance_days', lb.balance_days))
                                    from public.leave_balances lb join public.leave_types lt on lt.id = lb.leave_type_id
                                   where lb.employee_id = e.id and lb.balance_days <> 0), '[]'::jsonb)) end,
    'timeline', case when v_hr then coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'at', a.changed_at, 'by', pr.full_name) order by a.changed_at desc)
       from public.audit_log a left join public.profiles pr on pr.id = a.changed_by
      where a.new_value ->> 'offboarding_case_id' = c.id::text), '[]'::jsonb) end);
end;
$$;

-- complete_offboarding: sync once more right before the required-tasks
-- check, so a settlement paid moments ago is picked up without needing a
-- prior get_offboarding_case call.
create or replace function public.complete_offboarding(p_case_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  c public.offboarding_cases;
  e public.employees;
  v_open text;
  v_inst public.onboarding_instances;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  select * into c from public.offboarding_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  if not public._off_can(c.id, 'manage') then raise exception 'Only the owner or entity admin can finish offboarding' using errcode = '42501'; end if;
  if c.status <> 'open' then return jsonb_build_object('ok', true, 'already', true); end if;
  if c.last_working_date > v_today then
    raise exception 'The last working day (%) has not passed yet', to_char(c.last_working_date, 'DD Mon YYYY') using errcode = '22023';
  end if;
  perform public._off_sync_settlement(c.id);
  select string_agg(label, ', ' order by sort_order) into v_open from public.offboarding_tasks
   where case_id = c.id and is_required and status = 'not_started';
  if v_open is not null then raise exception 'Still open: %', v_open using errcode = '22023'; end if;

  select * into e from public.employees where id = c.employee_id;
  if e.employment_status = 'active' then
    perform public.set_employee_status(e.id, 'inactive', 'End of employment (' || replace(c.separation_type, '_', ' ') || ')');
  end if;
  select * into v_inst from public.onboarding_instances where employee_id = e.id and status not in ('completed', 'cancelled', 'withdrawn');
  if v_inst.id is not null then
    perform public._onb_set_status(v_inst.id, 'cancelled', 'Employment ended');
    update public.onboarding_instances set ended_at = now(), ended_by = auth.uid(), end_reason = 'Employment ended (offboarding)' where id = v_inst.id;
    update public.onboarding_tasks set status = 'cancelled', updated_at = now()
     where instance_id = v_inst.id and status not in ('approved', 'waived', 'cancelled');
  end if;
  update public.employee_immigration_cases set status = 'cancelled', closed_by = auth.uid(), closed_at = now(),
         close_reason = 'Employment ended', updated_at = now()
   where employee_id = e.id and status = 'open';

  update public.offboarding_cases set status = 'completed', closed_by = auth.uid(), closed_at = now(),
         close_notes = nullif(btrim(coalesce(p_notes, '')), ''), row_version = row_version + 1, updated_at = now()
   where id = c.id;
  perform public._off_audit(c, c.id, 'offboarding_completed', null, jsonb_build_object('notes', p_notes));
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['_off_sync_settlement(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['start_offboarding_settlement(uuid, date)', 'update_immigration_step(uuid, text, text, date, date, text, numeric, text)',
    'immigration_cost_summary(uuid, date, date)', 'get_offboarding_case(uuid)', 'complete_offboarding(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
;
