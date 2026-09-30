-- Suite 08: payroll workflow (payroll v2). Self-contained: one throwaway entity with fixed far-future months
-- (Jan-Jun 2098), throwaway people and payroll periods/records/payments. Everything is rolled back by the final
-- RAISE 'RESULT ...'. Record states (approved, net, payments) are set up directly as fixtures; the functions under
-- test are called the way the app calls them.
-- Covers: (a) off-cycle for a salary month, (b) payroll_set_schedule rules, (c) run_scheduled_payslip_publishing,
-- (d) staff payroll_my_payslips, (e) payroll_prepare double-pay guard, (f) legacy payroll_runs insert guard,
-- (g) get_payroll_changes previous salary month across regular / off-cycle / legacy sources.
-- Note: run_scheduled_payslip_publishing is a system job (no signed-in user); this file calls it with the JWT claims
-- cleared. It also processes any real due periods in the database; all of that is rolled back too.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; la uuid;
  u_adm uuid := gen_random_uuid(); u_admx uuid := gen_random_uuid(); u_st uuid := gen_random_uuid();
  em1 uuid; em2 uuid; em3 uuid; em4 uuid; em5 uuid; em_a uuid; em_b uuid; em_c uuid;
  p_oc1 uuid; p_oc2 uuid; p_reg4 uuid; p_sched uuid; p_lost uuid; p_oc_e uuid; p_feb uuid; p_off_feb uuid; p_mar uuid;
  r1 uuid; r2 uuid; r3 uuid; r4 uuid; rc1 uuid; rc2 uuid; rl uuid; r_oc5 uuid; r_oce uuid;
  v_base uuid; l1 uuid; l2 uuid;
  pp public.payroll_periods; j jsonb; jr jsonb; res jsonb; v_pub timestamptz; n int; d date; s text;
  r text[] := '{}';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S08') returning id into e1;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s08-adm@example.invalid','authenticated','authenticated'),(u_admx,'zz-s08-admx@example.invalid','authenticated','authenticated'),
    (u_st,'zz-s08-st@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Em1','active') returning id into em1;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Em2','active') returning id into em2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Em3','active') returning id into em3;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Em4','active') returning id into em4;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Em5 Staff','active') returning id into em5;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ EmA','active') returning id into em_a;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ EmB','active') returning id into em_b;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ EmC','active') returning id into em_c;
  perform public.admin_grant_access('zz-s08-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s08-admx@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s08-st@example.invalid','staff',e1,la,em5);

  -- grants of the RPCs under test
  r := r || (case when has_function_privilege('authenticated','public.payroll_set_schedule(uuid,date,timestamptz,boolean)','execute')
                   and has_function_privilege('authenticated','public.payroll_open_off_cycle(uuid,date,text,date)','execute')
                   and has_function_privilege('authenticated','public.payroll_prepare(uuid,uuid[])','execute')
                   and has_function_privilege('authenticated','public.payroll_my_payslips()','execute')
                   and has_function_privilege('authenticated','public.get_payroll_changes(uuid)','execute')
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: API role can execute the payroll RPCs')::text;
  r := r || (case when not has_function_privilege('authenticated','public.run_scheduled_payslip_publishing()','execute')
                   and not has_function_privilege('anon','public.run_scheduled_payslip_publishing()','execute')
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: scheduler job is not callable by API roles')::text;

  -- ===== (a) off-cycle payroll for a salary month =====
  p_oc1 := public.payroll_open_off_cycle(e1, date '2098-03-20', 'ZZ March bonus', date '2098-03-15');
  select * into pp from public.payroll_periods where id = p_oc1;
  r := r || (case when pp.kind = 'off_cycle' and pp.for_month = date '2098-03-01' and pp.period_start = date '2098-03-01'
                   and pp.period_end = date '2098-03-31' and pp.pay_date = date '2098-03-20'
                  then 'PASS ' else 'FAIL ' end
             || format('payroll-wf: off-cycle with for_month spans that month and stores pay_date (%s..%s for_month=%s pay_date=%s)', pp.period_start, pp.period_end, pp.for_month, pp.pay_date))::text;
  p_oc2 := public.payroll_open_off_cycle(e1, date '2098-05-10', 'ZZ settlement', null);
  select * into pp from public.payroll_periods where id = p_oc2;
  r := r || (case when pp.for_month is null and pp.period_start = date '2098-05-10' and pp.period_end = date '2098-05-10' and pp.pay_date = date '2098-05-10'
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: off-cycle without for_month is the pay date only and stores pay_date')::text;
  begin perform public.payroll_open_off_cycle(e1, date '2098-05-10', '   ', null); r := r || 'FAIL payroll-wf: off-cycle label required (allowed)'::text;
  exception when others then r := r || 'PASS payroll-wf: off-cycle label required'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  begin perform public.payroll_open_off_cycle(e1, date '2098-05-10', 'ZZ staff try', null); r := r || 'FAIL payroll-wf: staff cannot open off-cycle (allowed)'::text;
  exception when others then r := r || 'PASS payroll-wf: staff cannot open off-cycle'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- ===== (b) payroll_set_schedule =====
  p_reg4 := public.payroll_open_period(e1, date '2098-04-10');
  begin perform public.payroll_set_schedule(p_reg4, date '2098-03-31', null, true); r := r || 'FAIL payroll-wf: pay date before the salary month refused (regular) (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%before the salary month%' then 'PASS ' else 'FAIL ' end || 'payroll-wf: pay date before the salary month refused (regular) (' || sqlerrm || ')')::text; end;
  begin perform public.payroll_set_schedule(p_oc1, date '2098-02-28', null, true); r := r || 'FAIL payroll-wf: pay date before for_month refused (off-cycle) (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%before the salary month%' then 'PASS ' else 'FAIL ' end || 'payroll-wf: pay date before for_month refused (off-cycle) (' || sqlerrm || ')')::text; end;
  res := public.payroll_set_schedule(p_reg4, date '2098-05-20', now() + interval '1 day', true);
  r := r || (case when (res->>'pay_date')::date = date '2098-05-20' and res->>'warning' is not null then 'PASS ' else 'FAIL ' end
             || 'payroll-wf: schedule saved with a late-payment warning for a pay date over 15 days after due')::text;
  update public.payroll_periods set publish_payslips_at = now() - interval '1 hour' where id = p_reg4;
  select publish_payslips_at into v_pub from public.payroll_periods where id = p_reg4;
  begin
    res := public.payroll_set_schedule(p_reg4, date '2098-05-06', v_pub, true);
    select pay_date, publish_payslips_at into d, v_pub from public.payroll_periods where id = p_reg4;
    r := r || (case when d = date '2098-05-06' and (res->>'ok')::boolean then 'PASS ' else 'FAIL ' end || 'payroll-wf: pay date can be edited after the publish time has passed (publish time unchanged)')::text;
  exception when others then r := r || ('FAIL payroll-wf: pay date can be edited after the publish time has passed (' || sqlerrm || ')')::text; end;
  begin perform public.payroll_set_schedule(p_reg4, date '2098-05-06', now() - interval '2 hours', true); r := r || 'FAIL payroll-wf: a new publish time in the past refused (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%future%' then 'PASS ' else 'FAIL ' end || 'payroll-wf: a new publish time in the past refused (' || sqlerrm || ')')::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  begin perform public.payroll_set_schedule(p_reg4, date '2098-05-06', null, true); r := r || 'FAIL payroll-wf: staff cannot set a schedule (allowed)'::text;
  exception when others then r := r || 'PASS payroll-wf: staff cannot set a schedule'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  update public.payroll_periods set publish_payslips_at = null where id = p_reg4;  -- keep this month out of the scheduler run below

  -- ===== (e) double-pay guard in payroll_prepare =====
  p_oc_e := public.payroll_open_off_cycle(e1, date '2098-04-28', 'ZZ April extra', date '2098-04-01');
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_oc_e, em_c, 'approved', 400, 400) returning id into r_oce;
  j := public.payroll_prepare(p_reg4, null);
  r := r || (case when not exists (select 1 from public.payroll_records where period_id = p_reg4 and employee_id = em_c)
                   and exists (select 1 from jsonb_array_elements(j->'skipped') sk where sk->>'id' = em_c::text and sk->>'reason' like 'Already paid for this month%')
                  then 'PASS ' else 'FAIL ' end || format('payroll-wf: prepare (all) skips someone already approved in an off-cycle for the same month (skipped=%s)', j->'skipped'))::text;
  r := r || (case when (select count(*) from public.payroll_records where period_id = p_reg4 and employee_id in (em1, em2, em3, em4, em5, em_a, em_b)) = 7
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: prepare (all) still prepares everyone else')::text;
  j := public.payroll_prepare(p_reg4, array[em_c]);
  r := r || (case when exists (select 1 from public.payroll_records where period_id = p_reg4 and employee_id = em_c)
                   and (j->>'created')::int = 1 and jsonb_array_length(j->'skipped') = 0
                  then 'PASS ' else 'FAIL ' end || format('payroll-wf: prepare adds the person when selected explicitly (%s)', j))::text;

  -- ===== (f) legacy payroll_runs insert guard =====
  begin
    insert into public.payroll_runs(entity_id, period_start, period_end) values (e1, date '2098-01-01', date '2098-01-31');
    r := r || 'FAIL payroll-wf: new legacy payroll_runs insert refused (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%new Payroll screen%' then 'PASS ' else 'FAIL ' end || 'payroll-wf: new legacy payroll_runs insert refused (' || sqlerrm || ')')::text; end;
  select id into v_base from public.payroll_runs order by created_at limit 1;
  if v_base is null then  -- no production run to revise: create a base run with the maintenance switch, then switch it off again
    perform set_config('tshr.uat_maintenance', 'on', true);
    insert into public.payroll_runs(entity_id, period_start, period_end) values (e1, date '2097-12-01', date '2097-12-31') returning id into v_base;
    perform set_config('tshr.uat_maintenance', 'off', true);
  end if;
  begin
    insert into public.payroll_runs(entity_id, period_start, period_end, revises_payroll_run_id) values (e1, date '2098-01-01', date '2098-01-31', v_base) returning id into l1;
    insert into public.payroll_runs(entity_id, period_start, period_end, revises_payroll_run_id) values (e1, date '2098-02-01', date '2098-02-28', v_base) returning id into l2;
    r := r || 'PASS payroll-wf: a revision payroll_run (revises_payroll_run_id set) is allowed'::text;
  exception when others then r := r || ('FAIL payroll-wf: a revision payroll_run (revises_payroll_run_id set) is allowed (' || sqlerrm || ')')::text; end;

  -- ===== (g) get_payroll_changes previous salary month across sources =====
  -- Jan 2098: legacy only (EmA 300). Feb 2098: regular (EmB 1000) + off-cycle for Feb (EmB 500) + legacy (EmB 200). Mar 2098: regular (EmB 1800).
  insert into public.payslips(payroll_run_id, employee_id, net_pay, total_deductions) values (l1, em_a, 300, 50), (l2, em_b, 200, 0);
  update public.payroll_runs set status = 'approved' where id in (l1, l2);
  insert into public.payroll_periods(entity_id, kind, period_start, period_end) values (e1, 'regular', date '2098-02-01', date '2098-02-28') returning id into p_feb;
  insert into public.payroll_periods(entity_id, kind, period_start, period_end, label, pay_date, for_month)
    values (e1, 'off_cycle', date '2098-02-01', date '2098-02-28', 'ZZ Feb extra', date '2098-02-25', date '2098-02-01') returning id into p_off_feb;
  insert into public.payroll_periods(entity_id, kind, period_start, period_end) values (e1, 'regular', date '2098-03-01', date '2098-03-31') returning id into p_mar;
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_feb, em_b, 'approved', 1000, 1000), (p_off_feb, em_b, 'approved', 500, 500);
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_mar, em_b, 'draft', 1800, 1800);
  perform set_config('role', 'authenticated', true);
  j := public.get_payroll_changes(p_mar);
  select e into jr from jsonb_array_elements(j->'employees') e where e->>'employee_id' = em_b::text;
  r := r || (case when j->>'previous_label' = 'February 2098' then 'PASS ' else 'FAIL ' end || format('payroll-wf: changes compares with the previous salary month (%s)', j->>'previous_label'))::text;
  r := r || (case when (jr->>'net_prev')::numeric = 1700 and (jr->>'net_change')::numeric = 100 and (jr->>'new_this_month')::boolean = false
                  then 'PASS ' else 'FAIL ' end || format('payroll-wf: previous month = regular 1000 + off-cycle 500 + legacy 200 (net_prev=%s change=%s)', jr->>'net_prev', jr->>'net_change'))::text;
  r := r || (case when (j->'totals'->>'net_prev')::numeric = 1700 and (j->'totals'->>'net_now')::numeric = 1800 and jsonb_array_length(j->'left_since_last_month') = 0
                  then 'PASS ' else 'FAIL ' end || format('payroll-wf: changes totals across sources (%s)', j->'totals'))::text;
  j := public.get_payroll_changes(p_feb);
  select e into jr from jsonb_array_elements(j->'employees') e where e->>'employee_id' = em_b::text;
  r := r || (case when j->>'previous_label' = 'January 2098' and (jr->>'new_this_month')::boolean and jr->>'net_prev' is null
                  then 'PASS ' else 'FAIL ' end || format('payroll-wf: a legacy-only previous month is used (%s)', j->>'previous_label'))::text;
  r := r || (case when exists (select 1 from jsonb_array_elements(j->'left_since_last_month') l where l->>'employee_id' = em_a::text and (l->>'net_prev')::numeric = 300)
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: someone paid only in the previous (legacy) month shows as left since last month')::text;
  perform set_config('role', 'postgres', true);

  -- ===== (c) scheduled payslip publishing =====
  insert into public.payroll_periods(entity_id, kind, period_start, period_end) values (e1, 'regular', date '2098-05-01', date '2098-05-31') returning id into p_sched;
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_sched, em1, 'approved', 1000, 1000) returning id into r1;
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_sched, em2, 'approved', 1000, 1000) returning id into r2;
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_sched, em3, 'draft', 0, 0) returning id into r3;
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_sched, em4, 'approved', 800, 800) returning id into r4;
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_sched, em5, 'approved', 1000, 1000) returning id into rc1;
  insert into public.payroll_payments(record_id, amount, paid_on, method, status, idempotency_key) values
    (r1, 1000, current_date, 'bank_transfer', 'recorded', 'zz-s08-' || r1),
    (rc1, 1000, current_date, 'bank_transfer', 'recorded', 'zz-s08-' || rc1);
  insert into public.payroll_payments(record_id, amount, paid_on, method, status, failure_reason, idempotency_key)
    values (r4, 800, current_date, 'bank_transfer', 'failed', 'ZZ bounced', 'zz-s08-' || r4);
  update public.payroll_records set published_at = now() - interval '1 day' where id = rc1;  -- already-published, already-paid payslip
  -- a correction to the paid payslip (draft until it is approved)
  res := public.payroll_create_correction(rc1, 'ZZ fix allowance');
  rc2 := (res->>'record_id')::uuid;
  r := r || (case when (res->>'ok')::boolean and rc2 is not null then 'PASS ' else 'FAIL ' end || format('payroll-wf: correction created for a published payslip (%s)', res))::text;
  update public.payroll_records set net = 1000, gross = 1000, record_status = 'approved' where id = rc2;
  -- an off-cycle payslip for the staff member, published earlier
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net, published_at) values (p_oc1, em5, 'approved', 100, 100, now() - interval '2 days') returning id into r_oc5;

  -- ===== (d) staff payslip list BEFORE the scheduler publishes the correction =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j := public.payroll_my_payslips();
  perform set_config('role', 'postgres', true);
  r := r || (case when jsonb_array_length(j) = 2 then 'PASS ' else 'FAIL ' end || format('payroll-wf: staff sees their 2 published payslips (%s)', jsonb_array_length(j)))::text;
  r := r || (case when exists (select 1 from jsonb_array_elements(j) i where i->>'record_id' = rc1::text and i->>'title' = 'May 2098' and (i->>'superseded')::boolean)
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: staff keeps the payslip while its correction is still a draft (title = month)')::text;
  r := r || (case when exists (select 1 from jsonb_array_elements(j) i where i->>'record_id' = r_oc5::text and i->>'title' = 'March 2098')
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: off-cycle payslip is titled by its salary month, not its label')::text;
  r := r || (case when not exists (select 1 from jsonb_array_elements(j) i where i->>'record_id' = rc2::text)
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: staff does not see the unpublished correction')::text;

  -- lost-access period: scheduled by an admin who is then revoked
  insert into public.payroll_periods(entity_id, kind, period_start, period_end, label, pay_date, for_month)
    values (e1, 'off_cycle', date '2098-06-01', date '2098-06-30', 'ZZ June extra', date '2098-06-25', date '2098-06-01') returning id into p_lost;
  insert into public.payroll_records(period_id, employee_id, record_status, gross, net) values (p_lost, em1, 'approved', 500, 500) returning id into rl;
  insert into public.payroll_payments(record_id, amount, paid_on, method, status, idempotency_key) values (rl, 500, current_date, 'bank_transfer', 'recorded', 'zz-s08-' || rl);
  update public.payroll_periods set publish_payslips_at = now() - interval '1 hour', publish_requires_paid = true, schedule_set_by = u_adm where id = p_sched;
  update public.payroll_periods set publish_payslips_at = now() - interval '1 hour', publish_requires_paid = true, schedule_set_by = u_admx where id = p_lost;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  perform public.admin_revoke_access(u_admx, null, 'ZZ suite: scheduler user lost access');

  -- the scheduler is a system job: refused with a signed-in user, runs with no user
  begin perform public.run_scheduled_payslip_publishing(); r := r || 'FAIL payroll-wf: scheduler refuses a signed-in user (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%System job only%' then 'PASS ' else 'FAIL ' end || 'payroll-wf: scheduler refuses a signed-in user (' || sqlerrm || ')')::text; end;
  perform set_config('request.jwt.claims', '', true);
  perform public.run_scheduled_payslip_publishing();
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  r := r || (case when (select published_at from public.payroll_records where id = r1) is not null then 'PASS ' else 'FAIL ' end || 'payroll-wf: scheduler publishes an approved + paid payslip')::text;
  r := r || (case when (select count(*) from public.payroll_records where id in (r2, r3, r4) and published_at is not null) = 0 then 'PASS ' else 'FAIL ' end
             || 'payroll-wf: scheduler leaves unpaid, failed-payment and unapproved payslips unpublished')::text;
  r := r || (case when (select published_at from public.payroll_records where id = rc2) is not null then 'PASS ' else 'FAIL ' end
             || 'payroll-wf: scheduler publishes a correction to an already-paid payslip')::text;
  select count(*) into n from public.notifications where employee_id = em1 and notification_type = 'payslip_available' and target_id = r1;
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'payroll-wf: employee notified when the scheduler publishes')::text;
  select message into s from public.notifications where recipient_user_id = u_adm and notification_type = 'payroll_schedule_blocked' and target_id = p_sched;
  r := r || (case when s like '%1 not approved%' and s like '%2 not paid%' then 'PASS ' else 'FAIL ' end
             || format('payroll-wf: admin gets a blocked notice listing what is waiting (%s)', coalesce(s, 'no notice')))::text;
  r := r || (case when (select publish_attempted_at from public.payroll_periods where id = p_sched) is not null then 'PASS ' else 'FAIL ' end || 'payroll-wf: attempt time recorded')::text;
  r := r || (case when (select published_at from public.payroll_records where id = rl) is null then 'PASS ' else 'FAIL ' end
             || 'payroll-wf: scheduler publishes nothing when the scheduling user lost payroll access')::text;
  select count(*) into n from public.notifications where notification_type = 'payroll_schedule_blocked' and target_id = p_lost and message like '%can no longer approve payroll%';
  r := r || (case when n >= 1 then 'PASS ' else 'FAIL ' end || 'payroll-wf: lost-access period raises a blocked notice that says so')::text;

  -- ===== (d) staff payslip list AFTER the correction is published =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j := public.payroll_my_payslips();
  perform set_config('role', 'postgres', true);
  r := r || (case when exists (select 1 from jsonb_array_elements(j) i where i->>'record_id' = rc2::text and (i->>'is_correction')::boolean and i->>'title' = 'May 2098')
                   and not exists (select 1 from jsonb_array_elements(j) i where i->>'record_id' = rc1::text)
                  then 'PASS ' else 'FAIL ' end || 'payroll-wf: once the correction is published staff sees it instead of the original')::text;

  raise exception 'RESULT suite08 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
