-- ============================================================
-- Payroll v2 — business workflow tests.
-- Creates a throw-away company, branches, employees and logins, runs the
-- scenarios as each persona (PostgREST-style impersonation) and ROLLS BACK.
-- Nothing persists. Run as postgres (SQL editor / MCP execute_sql).
-- The final statement raises an exception whose message lists every result.
-- ============================================================
begin;

create temp table t_results(n serial, name text, pass boolean, detail text);
grant all on t_results to authenticated;
grant usage on sequence t_results_n_seq to authenticated;
create temp table t_ctx(k text primary key, v text);
grant all on t_ctx to authenticated;

create function pg_temp.login(p_sub uuid) returns void language plpgsql as $f$
begin
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
  set local role authenticated;
end $f$;
create function pg_temp.ok(p_name text, p_cond boolean, p_detail text default null) returns void language sql as $f$
  insert into t_results(name, pass, detail) values (p_name, coalesce(p_cond, false), p_detail);
$f$;
create function pg_temp.put(k text, v text) returns void language sql as $f$
  insert into t_ctx values (k, v) on conflict (k) do update set v = excluded.v;
$f$;
create function pg_temp.get(k text) returns text language sql security definer as $f$ select v from t_ctx where t_ctx.k = get.k; $f$;
create function pg_temp.rec(p_emp uuid) returns uuid language sql security definer as $f$
  select id from public.payroll_records where period_id = pg_temp.get('period')::uuid and employee_id = p_emp
     and superseded_by_record_id is null;
$f$;
create function pg_temp.net(p_emp uuid) returns numeric language sql security definer as $f$
  select net from public.payroll_records where id = pg_temp.rec(p_emp);
$f$;
create function pg_temp.ver(p_emp uuid) returns int language sql security definer as $f$
  select calc_version from public.payroll_records where id = pg_temp.rec(p_emp);
$f$;
create function pg_temp.has_att(p_emp uuid, p_code text) returns boolean language sql security definer as $f$
  select exists (select 1 from public.payroll_records r, jsonb_array_elements(r.attention) a
                  where r.id = pg_temp.rec(p_emp) and a ->> 'code' = p_code);
$f$;
create function pg_temp.line(p_emp uuid, p_code text) returns numeric language sql security definer as $f$
  select coalesce(sum(amount), 0) from public.payroll_lines where record_id = pg_temp.rec(p_emp) and code = p_code;
$f$;

create function pg_temp.money(p uuid) returns table(paid numeric, outstanding numeric, payment_status text, failed_attempts int)
  language sql security definer as $f$ select * from public._payroll_money(p) $f$;

-- ---------------------------------------------------------------- fixtures
set local session_replication_role = replica;
insert into auth.users (id, email, aud, role) values
  ('b1000000-0000-4000-8000-000000000001', 'pv2.owner@example.test', 'authenticated', 'authenticated'),
  ('b1000000-0000-4000-8000-000000000002', 'pv2.admin@example.test', 'authenticated', 'authenticated'),
  ('b1000000-0000-4000-8000-000000000003', 'pv2.admin2@example.test', 'authenticated', 'authenticated'),
  ('b1000000-0000-4000-8000-000000000004', 'pv2.lm@example.test', 'authenticated', 'authenticated'),
  ('b1000000-0000-4000-8000-000000000005', 'pv2.staff@example.test', 'authenticated', 'authenticated'),
  ('b1000000-0000-4000-8000-000000000006', 'pv2.acct@example.test', 'authenticated', 'authenticated');
insert into public.entities (id, name, default_currency) values
  ('b2000000-0000-4000-8000-000000000001', 'PV2 Test Cafe', 'AED'),
  ('b2000000-0000-4000-8000-000000000002', 'PV2 Other Co', 'AED');
insert into public.locations (id, entity_id, name) values
  ('b3000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001', 'PV2 Branch 1'),
  ('b3000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000001', 'PV2 Branch 2'),
  ('b3000000-0000-4000-8000-000000000003', 'b2000000-0000-4000-8000-000000000002', 'PV2 Other Branch');
insert into public.profiles (id, full_name, role, entity_id, location_id, is_active) values
  ('b1000000-0000-4000-8000-000000000001', 'PV2 Owner', 'owner', null, null, true),
  ('b1000000-0000-4000-8000-000000000002', 'PV2 Admin', 'entity_admin', 'b2000000-0000-4000-8000-000000000001', null, true),
  ('b1000000-0000-4000-8000-000000000003', 'PV2 Admin Other', 'entity_admin', 'b2000000-0000-4000-8000-000000000002', null, true),
  ('b1000000-0000-4000-8000-000000000004', 'PV2 Branch Mgr', 'location_manager', 'b2000000-0000-4000-8000-000000000001',
   'b3000000-0000-4000-8000-000000000001', true),
  ('b1000000-0000-4000-8000-000000000005', 'PV2 Staff', 'staff', 'b2000000-0000-4000-8000-000000000001',
   'b3000000-0000-4000-8000-000000000001', true),
  ('b1000000-0000-4000-8000-000000000006', 'PV2 Accountant', 'staff', 'b2000000-0000-4000-8000-000000000001', null, true);
insert into public.payroll_permissions (user_id, entity_id, preset) values
  ('b1000000-0000-4000-8000-000000000006', 'b2000000-0000-4000-8000-000000000001', 'accountant');
insert into public.positions (id, entity_id, title) values
  ('b4000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001', 'PV2 Barista'),
  ('b4000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000001', 'PV2 Server');
insert into public.tip_role_points (position_id, points) values
  ('b4000000-0000-4000-8000-000000000001', 2), ('b4000000-0000-4000-8000-000000000002', 1);
-- M1 monthly 6000 + housing 1500 | M2 monthly 3000 (staff login) | H1 hourly 20 | J1 joiner 16 Sep | X1 other company
insert into public.employees (id, entity_id, home_location_id, position_id, auth_user_id, full_name, employment_status, join_date) values
  ('b5000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001', 'b3000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000001', null, 'PV2 M1 Monthly', 'active', '2025-01-01'),
  ('b5000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000001', 'b3000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000002', 'b1000000-0000-4000-8000-000000000005', 'PV2 M2 Monthly', 'active', '2025-01-01'),
  ('b5000000-0000-4000-8000-000000000003', 'b2000000-0000-4000-8000-000000000001', 'b3000000-0000-4000-8000-000000000002',
   'b4000000-0000-4000-8000-000000000002', null, 'PV2 H1 Hourly', 'active', '2025-01-01'),
  ('b5000000-0000-4000-8000-000000000004', 'b2000000-0000-4000-8000-000000000001', 'b3000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000002', null, 'PV2 J1 Joiner', 'active', '2026-09-16'),
  ('b5000000-0000-4000-8000-000000000005', 'b2000000-0000-4000-8000-000000000002', 'b3000000-0000-4000-8000-000000000003',
   null, null, 'PV2 X1 Other', 'active', '2025-01-01');
insert into public.compensation_versions (employee_id, effective_from, pay_type, basic_monthly, hourly_rate, overtime_eligible) values
  ('b5000000-0000-4000-8000-000000000001', '2025-01-01', 'monthly', 6000, null, true),
  ('b5000000-0000-4000-8000-000000000002', '2025-01-01', 'monthly', 3000, null, true),
  ('b5000000-0000-4000-8000-000000000003', '2025-01-01', 'hourly', null, 20, true),
  ('b5000000-0000-4000-8000-000000000004', '2026-09-16', 'monthly', 3000, null, false),
  ('b5000000-0000-4000-8000-000000000005', '2025-01-01', 'monthly', 4000, null, true);
insert into public.compensation_components (employee_id, kind, code, label, monthly_amount, prorate, effective_from) values
  ('b5000000-0000-4000-8000-000000000001', 'earning', 'housing', 'Housing allowance', 1500, true, '2025-01-01');
insert into public.leave_types (id, entity_id, name, payroll_treatment) values
  ('b6000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001', 'PV2 Unpaid', 'unpaid');
insert into public.leave_requests (employee_id, leave_type_id, start_date, end_date, days_requested, status) values
  ('b5000000-0000-4000-8000-000000000002', 'b6000000-0000-4000-8000-000000000001', '2026-09-10', '2026-09-11', 2, 'approved');
set local session_replication_role = origin;

-- ================================================================= tests
do $t$
declare
  v_owner uuid := 'b1000000-0000-4000-8000-000000000001';
  v_admin uuid := 'b1000000-0000-4000-8000-000000000002';
  v_admin2 uuid := 'b1000000-0000-4000-8000-000000000003';
  v_lm uuid := 'b1000000-0000-4000-8000-000000000004';
  v_staff uuid := 'b1000000-0000-4000-8000-000000000005';
  v_acct uuid := 'b1000000-0000-4000-8000-000000000006';
  v_ent uuid := 'b2000000-0000-4000-8000-000000000001';
  v_l1 uuid := 'b3000000-0000-4000-8000-000000000001';
  m1 uuid := 'b5000000-0000-4000-8000-000000000001';
  m2 uuid := 'b5000000-0000-4000-8000-000000000002';
  h1 uuid := 'b5000000-0000-4000-8000-000000000003';
  j1 uuid := 'b5000000-0000-4000-8000-000000000004';
  x1 uuid := 'b5000000-0000-4000-8000-000000000005';
  v_period uuid;
  v_period2 uuid;
  j jsonb;
  v_n numeric;
  v_n2 numeric;
  v_code text;
  v_m1_orig uuid;
  v_m1_net numeric;
  v_m2_net numeric;
  v_h1_net numeric;
  v_cnt integer;
begin
  -- ------------------------------------------------ workspace + prepare
  perform pg_temp.login(v_admin);
  v_period := public.payroll_open_period(v_ent, '2026-09-15');
  perform pg_temp.put('period', v_period::text);
  v_period2 := public.payroll_open_period(v_ent, '2026-09-01');
  perform pg_temp.ok('one workspace per company and month', v_period = v_period2);

  j := public.payroll_prepare(v_period, null);
  perform pg_temp.ok('prepare creates eligible employees (4, not the other company)', (j ->> 'created')::int = 4, j::text);
  j := public.payroll_prepare(v_period, null);
  perform pg_temp.ok('repeated prepare creates no duplicates', (j ->> 'created')::int = 0
      and (select count(*) from public.payroll_records where period_id = v_period) = 4, j::text);

  perform pg_temp.ok('monthly employee without timesheet is included at full pay', pg_temp.net(m1) = 7500,
    pg_temp.net(m1)::text);
  perform pg_temp.ok('missing timesheet shown as exception', pg_temp.has_att(m1, 'no_timesheet'));
  perform pg_temp.ok('joiner prorated by calendar days (3000 x 15/30 = 1500)', pg_temp.net(j1) = 1500, pg_temp.net(j1)::text);
  perform pg_temp.ok('hourly employee without hours blocks (not silently zero)', pg_temp.has_att(h1, 'no_hours'));
  perform pg_temp.ok('unpaid leave deducted once (3000/30 x 2 = 200)', pg_temp.line(m2, 'unpaid_leave') = 200,
    pg_temp.line(m2, 'unpaid_leave')::text);

  -- -------------------------------------------------------- hours & OT
  j := public.payroll_set_hours(v_period, h1, 100, 0, 0, 0, true, 'test');
  perform pg_temp.ok('hourly pay from confirmed hours (100 x 20)', pg_temp.net(h1) = 2000, pg_temp.net(h1)::text);
  j := public.payroll_set_hours(v_period, m2, 0, 10, 0, 0, false, 'test');
  perform pg_temp.ok('pending overtime is a visible pending item, not dropped', pg_temp.has_att(m2, 'overtime_pending')
      and pg_temp.line(m2, 'overtime') = 0);
  j := public.payroll_confirm_hours(v_period, array[m2]);
  perform pg_temp.ok('confirmed overtime = 10 x 3000/240 x 1.25 = 156.25', pg_temp.line(m2, 'overtime') = 156.25,
    pg_temp.line(m2, 'overtime')::text);
  perform pg_temp.ok('overtime + unpaid leave net (3000 + 156.25 - 200)', pg_temp.net(m2) = 2956.25, pg_temp.net(m2)::text);
  j := public.payroll_set_hours(v_period, j1, 0, 5, 0, 0, true, 'test');
  perform pg_temp.ok('overtime eligibility separate from pay type (J1 not eligible)', pg_temp.has_att(j1, 'ot_not_eligible')
      and pg_temp.line(j1, 'overtime') = 0);

  -- -------------------------------------------------------------- tips
  j := public.payroll_tip_confirm(v_period, v_l1, '2026-09-01', '2026-09-30', 100.00, 'payroll', 'equal', array[m1, m2, j1]);
  perform pg_temp.ok('tips reconcile exactly to the pool', (j ->> 'allocated')::numeric = 100.00, j::text);
  perform pg_temp.ok('tips rounding gives 33.34 + 33.33 + 33.33',
    (select array_agg(amount order by amount desc) from public.tip_allocations where pool_id = (j ->> 'pool_id')::uuid)
      = array[33.34, 33.33, 33.33]::numeric[]);
  j := public.payroll_tip_confirm(v_period, v_l1, '2026-09-01', '2026-09-30', 100.00, 'payroll', 'equal', array[m1, m2, j1]);
  perform pg_temp.ok('the same tip pool cannot be imported twice', (j ->> 'ok')::boolean = false, j ->> 'reason');
  v_n := pg_temp.net(m1);
  j := public.payroll_tip_confirm(v_period, v_l1, '2026-09-01', '2026-09-30', 60.00, 'cash_paid', 'role_points', array[m1, m2]);
  perform pg_temp.ok('cash-paid tips shown but not added to net', pg_temp.net(m1) = v_n
      and pg_temp.line(m1, 'tips_cash') = 40.00, format('net %s->%s cash %s', v_n, pg_temp.net(m1), pg_temp.line(m1, 'tips_cash')));
  j := public.payroll_tip_preview(v_period, v_l1, '2026-09-01', '2026-09-30', 10.00, 'payroll', 'hours_points', array[m1, m2]);
  perform pg_temp.ok('hours x points split skips staff with no hours', jsonb_array_length(j -> 'items') = 1
      and (j -> 'items' -> 0 ->> 'amount')::numeric = 10.00, j::text);

  -- ------------------------------------------------------- adjustments
  j := public.payroll_add_adjustment(v_period, array[m1, m2, j1], 'earning', 'bonus', 100.00, 'distributed', 'Test bonus pool', true);
  perform pg_temp.ok('bulk preview writes nothing', not exists (select 1 from public.payroll_adjustments where period_id = v_period));
  perform pg_temp.ok('distributed total splits exactly', (select sum((x ->> 'amount')::numeric) from jsonb_array_elements(j -> 'items') x) = 100.00);
  j := public.payroll_add_adjustment(v_period, array[m1, m2, j1, x1], 'earning', 'bonus', 100.00, 'distributed', 'Test bonus pool', false);
  perform pg_temp.ok('bulk adjust excludes other-company employee with reason',
    jsonb_array_length(j -> 'skipped') = 1 and (j -> 'skipped' -> 0 ->> 'reason') = 'Belongs to another company', j::text);
  j := public.payroll_add_adjustment(v_period, array[m1, m2, j1], 'deduction', 'uniform', 50, 'per_employee', 'Uniform', false);
  perform pg_temp.ok('per-employee amount applied to each (impact -150)', (j ->> 'impact')::numeric = -150, j::text);

  -- ---------------------------------------------------------- advances
  j := public.payroll_create_advance(h1, 1000, '2026-09-05', 'cash', '2026-09-01', 3, 'Test advance');
  perform pg_temp.ok('advance instalment 333.34, deducted this month', pg_temp.line(h1, 'advance_repayment') = 333.34,
    pg_temp.line(h1, 'advance_repayment')::text);

  -- --------------------------------------------------------- approval
  j := public.payroll_approve(jsonb_build_array(jsonb_build_object('record_id', pg_temp.rec(m1), 'calc_version', pg_temp.ver(m1))), false);
  perform pg_temp.ok('two-step: preparer cannot approve own preparation', (j ->> 'processed')::int = 0
      and (j -> 'skipped' -> 0 ->> 'reason') like 'You prepared it%', j::text);
  perform pg_temp.login(v_owner);
  j := public.payroll_approve(jsonb_build_array(jsonb_build_object('record_id', pg_temp.rec(m1), 'calc_version', pg_temp.ver(m1) - 1)), false);
  perform pg_temp.ok('stale calculation version refused', (j ->> 'processed')::int = 0
      and (j -> 'skipped' -> 0 ->> 'reason') like 'Amounts changed%', j::text);
  j := public.payroll_approve(jsonb_build_array(
         jsonb_build_object('record_id', pg_temp.rec(m1), 'calc_version', pg_temp.ver(m1)),
         jsonb_build_object('record_id', pg_temp.rec(h1), 'calc_version', pg_temp.ver(h1))), false);
  perform pg_temp.ok('approve selected records', (j ->> 'processed')::int = 2, j::text);
  perform pg_temp.ok('advance repayment locked at approval',
    (select sum(ar.amount) from public.advance_repayments ar join public.salary_advances a on a.id = ar.advance_id
      where a.employee_id = h1) = 333.34);

  -- --------------------------------------- mixed month / frozen records
  v_m1_net := pg_temp.net(m1);
  v_h1_net := pg_temp.net(h1);
  perform pg_temp.login(v_admin);
  j := public.payroll_recalculate(array[pg_temp.rec(m1), pg_temp.rec(m2), pg_temp.rec(h1), pg_temp.rec(j1)]);
  perform pg_temp.ok('bulk recalculate skips approved, processes drafts', (j ->> 'processed')::int = 2
      and jsonb_array_length(j -> 'skipped') = 2, j::text);
  j := public.payroll_set_hours(v_period, m1, 10, 0, 0, 0, true, 'late change');
  perform pg_temp.ok('inputs refused for an approved record', (j ->> 'ok')::boolean = false and pg_temp.net(m1) = v_m1_net, j::text);
  j := public.payroll_add_adjustment(v_period, array[m1, m2], 'earning', 'bonus', 10, 'per_employee', 'x', false);
  perform pg_temp.ok('bulk adjustment excludes approved record with reason', (j ->> 'processed')::int = 1
      and pg_temp.net(m1) = v_m1_net, j::text);

  -- ---------------------------------------------------------- payments
  perform pg_temp.login(v_acct);
  begin
    j := public.payroll_prepare(v_period, null);
    perform pg_temp.ok('accountant cannot prepare', false, 'no error');
  exception when others then
    perform pg_temp.ok('accountant cannot prepare', sqlstate = '42501', sqlerrm);
  end;
end $t$;

do $t$
declare
  v_owner uuid := 'b1000000-0000-4000-8000-000000000001';
  v_admin uuid := 'b1000000-0000-4000-8000-000000000002';
  v_admin2 uuid := 'b1000000-0000-4000-8000-000000000003';
  v_lm uuid := 'b1000000-0000-4000-8000-000000000004';
  v_staff uuid := 'b1000000-0000-4000-8000-000000000005';
  v_acct uuid := 'b1000000-0000-4000-8000-000000000006';
  v_ent uuid := 'b2000000-0000-4000-8000-000000000001';
  m1 uuid := 'b5000000-0000-4000-8000-000000000001';
  m2 uuid := 'b5000000-0000-4000-8000-000000000002';
  h1 uuid := 'b5000000-0000-4000-8000-000000000003';
  j1 uuid := 'b5000000-0000-4000-8000-000000000004';
  v_period uuid := pg_temp.get('period')::uuid;
  j jsonb;
  v_m1 uuid;
  v_m1_net numeric;
  v_m2_net numeric;
  v_h1_net numeric;
  v_corr uuid;
  m record;
  v_exp uuid;
begin
  perform pg_temp.login(v_acct);
  v_m1 := pg_temp.rec(m1);
  v_m1_net := pg_temp.net(m1);
  j := public.payroll_record_payments(jsonb_build_array(jsonb_build_object('record_id', v_m1, 'amount', 1000)),
         '2026-09-27', 'bank_transfer', 'TRX-FAIL', 'failed', 'req-1', 'Bank rejected: wrong IBAN');
  select * into m from pg_temp.money(v_m1);
  perform pg_temp.ok('failed payment does not count as paid', m.paid = 0 and m.payment_status = 'failed', row_to_json(m)::text);
  j := public.payroll_record_payments(jsonb_build_array(jsonb_build_object('record_id', v_m1, 'amount', 1000)),
         '2026-09-27', 'bank_transfer', 'TRX-1', 'recorded', 'req-2');
  select * into m from pg_temp.money(v_m1);
  perform pg_temp.ok('partial payment', m.paid = 1000 and m.payment_status = 'partial' and m.outstanding = v_m1_net - 1000,
    row_to_json(m)::text);
  j := public.payroll_record_payments(jsonb_build_array(jsonb_build_object('record_id', v_m1, 'amount', 1000)),
         '2026-09-27', 'bank_transfer', 'TRX-1', 'recorded', 'req-2');
  perform pg_temp.ok('duplicate submission records nothing', (j ->> 'processed')::int = 0
      and (select count(*) from public.payroll_payments where record_id = v_m1 and status = 'recorded') = 1, j::text);
  j := public.payroll_record_payments(jsonb_build_array(jsonb_build_object('record_id', v_m1, 'amount', v_m1_net)),
         '2026-09-27', 'bank_transfer', 'TRX-2', 'recorded', 'req-3');
  perform pg_temp.ok('overpayment refused', (j ->> 'processed')::int = 0, j::text);
  j := public.payroll_record_payments(jsonb_build_array(jsonb_build_object('record_id', v_m1)),
         '2026-09-27', 'bank_transfer', 'TRX-3', 'recorded', 'req-4');
  select * into m from pg_temp.money(v_m1);
  perform pg_temp.ok('pay the outstanding balance -> paid', m.payment_status = 'paid' and m.outstanding = 0, row_to_json(m)::text);
  j := public.payroll_record_payments(jsonb_build_array(jsonb_build_object('record_id', v_m1)),
         '2026-09-27', 'bank_transfer', 'TRX-4', 'recorded', 'req-5');
  perform pg_temp.ok('settled amount cannot be paid again', (j ->> 'processed')::int = 0, j::text);

  -- ------------------------------------------ export + return to draft
  j := public.payroll_create_export(array[pg_temp.rec(h1), pg_temp.rec(m1), pg_temp.rec(m2)]);
  v_exp := (j ->> 'export_id')::uuid;
  perform pg_temp.ok('export includes only approved outstanding records', jsonb_array_length(j -> 'rows') = 1
      and jsonb_array_length(j -> 'skipped') = 2, j::text);
  select * into m from pg_temp.money(pg_temp.rec(h1));
  perform pg_temp.ok('export does not mark anyone paid', m.paid = 0 and m.payment_status = 'unpaid');

  perform pg_temp.login(v_admin);
  j := public.payroll_return_to_draft(array[pg_temp.rec(h1), v_m1], 'Hours were wrong');
  perform pg_temp.ok('return to draft: unpaid yes, paid no', (j ->> 'processed')::int = 1
      and (j -> 'skipped' -> 0 ->> 'reason') like 'A payment is recorded%', j::text);
  perform pg_temp.ok('return to draft invalidates the export',
    (select invalidated_at is not null from public.payroll_exports where id = v_exp));
  perform pg_temp.ok('return to draft releases the locked advance repayment',
    not exists (select 1 from public.advance_repayments ar join public.salary_advances a on a.id = ar.advance_id where a.employee_id = h1));

  -- ------------------------------------------------ paid correction
  v_m2_net := pg_temp.net(m2);
  v_h1_net := pg_temp.net(h1);
  j := public.payroll_create_correction(v_m1, 'Missed bonus');
  v_corr := (j ->> 'record_id')::uuid;
  perform pg_temp.ok('correction created for paid record', v_corr is not null and pg_temp.rec(m1) = v_corr, j::text);
  j := public.payroll_add_adjustment(v_period, array[m1], 'earning', 'bonus', 200, 'individual', 'Missed bonus', false);
  perform pg_temp.ok('original paid record preserved', (select net from public.payroll_records where id = v_m1) = v_m1_net
      and (select record_status from public.payroll_records where id = v_m1) = 'approved');
  perform pg_temp.login(v_owner);
  j := public.payroll_approve(jsonb_build_array(jsonb_build_object('record_id', v_corr, 'calc_version', pg_temp.ver(m1))), false);
  select * into m from pg_temp.money(v_corr);
  perform pg_temp.ok('corrected entitlement: only the difference (200) is outstanding',
    m.outstanding = 200 and m.paid = v_m1_net and m.payment_status = 'partial', row_to_json(m)::text);
  perform pg_temp.ok('individual correction did not change other records', pg_temp.net(m2) = v_m2_net and pg_temp.net(h1) = v_h1_net);
  perform pg_temp.ok('one live entitlement per employee', (select count(*) from public.payroll_records
     where period_id = v_period and employee_id = m1 and superseded_by_record_id is null) = 1);

  -- --------------------------------------------- publish + privacy
  j := public.payroll_approve(jsonb_build_array(jsonb_build_object('record_id', pg_temp.rec(m2), 'calc_version', pg_temp.ver(m2))), false);
  j := public.payroll_publish(array[pg_temp.rec(m2), pg_temp.rec(j1)]);
  perform pg_temp.ok('publish approved only (draft skipped)', (j ->> 'processed')::int = 1
      and (j -> 'skipped' -> 0 ->> 'reason') = 'Approve it first', j::text);
  perform pg_temp.login(v_staff);
  perform pg_temp.ok('employee sees own published payslip', jsonb_array_length(public.payroll_my_payslips()) = 1);
  perform pg_temp.ok('employee table access limited to own published record',
    (select count(*) from public.payroll_records) = 1 and (select count(*) from public.payroll_lines l
      join public.payroll_records r on r.id = l.record_id where r.employee_id <> m2) = 0);
  begin
    perform public.payroll_record_detail(pg_temp.rec(m1));
    perform pg_temp.ok('employee cannot open another payroll record', false);
  exception when others then
    perform pg_temp.ok('employee cannot open another payroll record', sqlstate = '42501', sqlerrm);
  end;
  begin
    perform public.payroll_my_payslip(pg_temp.rec(j1));
    perform pg_temp.ok('employee cannot open another payslip', false);
  exception when others then
    perform pg_temp.ok('employee cannot open another payslip', sqlstate = 'P0002', sqlerrm);
  end;

  -- ------------------------------------------------ company isolation
  perform pg_temp.login(v_admin2);
  begin
    perform public.payroll_workspace(v_period);
    perform pg_temp.ok('other company admin cannot open the workspace', false);
  exception when others then
    perform pg_temp.ok('other company admin cannot open the workspace', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.ok('other company admin sees no records or pay', (select count(*) from public.payroll_records) = 0
      and (select count(*) from public.compensation_versions where employee_id = m1) = 0);

  -- --------------------------------------------------- branch manager
  perform pg_temp.login(v_lm);
  j := public.payroll_set_hours(v_period, j1, 0, 2, 0, 0, false, 'LM entry');
  perform pg_temp.ok('branch manager enters hours for own branch', (j ->> 'ok')::boolean, j::text);
  begin
    perform public.payroll_set_hours(v_period, h1, 1, 0, 0, 0, false, 'x');
    perform pg_temp.ok('branch manager blocked for another branch', false);
  exception when others then
    perform pg_temp.ok('branch manager blocked for another branch', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.ok('branch manager sees no salaries', (select count(*) from public.payroll_records) = 0
      and (select count(*) from public.compensation_versions) = 0);
  begin
    perform public.payroll_workspace(v_period);
    perform pg_temp.ok('branch manager cannot open pay workspace', false);
  exception when others then
    perform pg_temp.ok('branch manager cannot open pay workspace', sqlstate = '42501', sqlerrm);
  end;

  -- ------------------------------------------- owner single-step
  perform pg_temp.login(v_owner);
  j := public.payroll_save_settings(v_ent, '2026-09-01', jsonb_build_object('approval_mode', 'owner_single_step'));
  j := public.payroll_prepare(v_period, array[j1]);
  j := public.payroll_approve(jsonb_build_array(jsonb_build_object('record_id', pg_temp.rec(j1), 'calc_version', pg_temp.ver(j1))), false);
  perform pg_temp.ok('owner single-step approval when explicitly configured', (j ->> 'processed')::int = 1, j::text);
  begin
    perform public.payroll_save_settings(v_ent, '2026-10-01', jsonb_build_object('overtime_multiplier', 1.1));
    perform pg_temp.ok('settings refuse overtime below legal minimum', false);
  exception when others then
    perform pg_temp.ok('settings refuse overtime below legal minimum', sqlstate = '22023', sqlerrm);
  end;

  -- ------------------------------------------------- arithmetic check
  perform pg_temp.ok('every record: net = gross - deductions = sum of lines',
    not exists (select 1 from public.payroll_records r where r.period_id = v_period and (
      r.net <> r.gross - r.deductions
      or r.gross <> coalesce((select sum(amount) from public.payroll_lines l where l.record_id = r.id and l.kind = 'earning'), 0)
      or r.deductions <> coalesce((select sum(amount) from public.payroll_lines l where l.record_id = r.id and l.kind = 'deduction'), 0))));
  j := public.payroll_report(v_period, 'register');
  perform pg_temp.ok('register report lists live records', jsonb_array_length(j) = 4, jsonb_array_length(j)::text);
  j := public.payroll_workspace(v_period);
  perform pg_temp.ok('workspace summary adds up', (j -> 'summary' ->> 'employees')::int = 4
      and (j -> 'summary' ->> 'total_net')::numeric = (select sum(net) from public.payroll_records
          where period_id = v_period and superseded_by_record_id is null), (j -> 'summary')::text);
end $t$;

reset role;
do $$ begin
  raise exception 'PAYROLL_V2_TESTS % passed / % total || FAILED: % || ALL: %',
    (select count(*) from t_results where pass), (select count(*) from t_results),
    coalesce((select string_agg(name || ' [' || coalesce(detail, '') || ']', ' ;; ' order by n) from t_results where not pass), 'none'),
    (select string_agg(n || '.' || name, ' | ' order by n) from t_results);
end $$;
rollback;
