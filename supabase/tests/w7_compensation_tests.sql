-- ============================================================
-- W7 compensation admin — rolled-back verification.
-- Creates temporary auth.users / profiles / entities / employees /
-- payroll run INSIDE one DO block, impersonates each persona exactly
-- like PostgREST (set local role authenticated + request.jwt.claims),
-- and ends with RAISE EXCEPTION carrying the results so NOTHING persists.
-- Run as postgres (SQL editor / MCP). Read the error message: every
-- line must start with PASS.
-- ============================================================
do $$
declare
  v_ent uuid; v_ent2 uuid; v_loc uuid; v_loc2 uuid;
  u_owner uuid := gen_random_uuid(); u_ea uuid := gen_random_uuid();
  u_lm uuid := gen_random_uuid(); u_st uuid := gen_random_uuid(); u_ea2 uuid := gen_random_uuid();
  e1 uuid; e2 uuid; e3 uuid; e4 uuid; e5 uuid; e6 uuid; e_ea uuid;
  v_run uuid;
  out text := '';
begin
  execute $f$
    create function pg_temp.try(p_sub uuid, p_sql text) returns text language plpgsql as $b$
    declare v text;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
      set local role authenticated;
      execute p_sql into v;
      reset role;
      return 'ok:' || coalesce(v, 'null');
    exception when others then
      reset role;
      return sqlstate || ':' || sqlerrm;
    end $b$ $f$;
  execute $f$
    create function pg_temp.chk(p_name text, p_got text, p_expect_prefix text) returns text language sql as $b$
      select case when p_got like p_expect_prefix || '%' then 'PASS ' else 'FAIL ' end || p_name || ' => ' || left(p_got, 110) || E'\n'
    $b$ $f$;

  -- ---------------------------------------------------------- fixtures
  insert into public.entities (name) values ('W7 TEST ENTITY') returning id into v_ent;
  insert into public.entities (name) values ('W7 TEST OTHER') returning id into v_ent2;
  insert into public.locations (entity_id, name) values (v_ent, 'W7 LOC') returning id into v_loc;
  insert into public.locations (entity_id, name) values (v_ent2, 'W7 LOC 2') returning id into v_loc2;

  insert into auth.users (id, email, aud, role) values
    (u_owner, 'w7owner@test.invalid', 'authenticated', 'authenticated'),
    (u_ea, 'w7ea@test.invalid', 'authenticated', 'authenticated'),
    (u_lm, 'w7lm@test.invalid', 'authenticated', 'authenticated'),
    (u_st, 'w7st@test.invalid', 'authenticated', 'authenticated'),
    (u_ea2, 'w7ea2@test.invalid', 'authenticated', 'authenticated');
  insert into public.profiles (id, full_name, role, entity_id, location_id) values
    (u_owner, 'W7 Owner', 'owner', null, null),
    (u_ea, 'W7 EA', 'entity_admin', v_ent, null),
    (u_lm, 'W7 LM', 'location_manager', v_ent, v_loc),
    (u_st, 'W7 Staff', 'staff', v_ent, v_loc),
    (u_ea2, 'W7 EA2', 'entity_admin', v_ent2, null);

  insert into public.employees (entity_id, home_location_id, full_name, employment_status, join_date)
    values (v_ent, v_loc, 'W7 E1 active', 'active', '2026-01-01') returning id into e1;
  insert into public.employees (entity_id, home_location_id, full_name, employment_status, join_date, auth_user_id)
    values (v_ent, v_loc, 'W7 E2 active staff', 'active', '2026-01-01', u_st) returning id into e2;
  insert into public.employees (entity_id, home_location_id, full_name, employment_status, join_date)
    values (v_ent, v_loc, 'W7 E3 pre', 'pre_boarding', '2026-01-01') returning id into e3;
  insert into public.employees (entity_id, home_location_id, full_name, employment_status, join_date)
    values (v_ent, v_loc, 'W7 E4 inactive', 'inactive', '2026-01-01') returning id into e4;
  insert into public.employees (entity_id, home_location_id, full_name, employment_status, join_date)
    values (v_ent2, v_loc2, 'W7 E5 other entity', 'active', '2026-01-01') returning id into e5;
  insert into public.employees (entity_id, home_location_id, full_name, employment_status, join_date)
    values (v_ent, v_loc, 'W7 E6 joins later', 'active', '2027-06-01') returning id into e6;
  insert into public.employees (entity_id, home_location_id, full_name, employment_status, join_date, auth_user_id)
    values (v_ent, v_loc, 'W7 EA self', 'active', '2026-01-01', u_ea) returning id into e_ea;

  insert into public.payroll_runs (entity_id, period_start, period_end, status)
    values (v_ent, '2026-09-01', '2026-09-30', 'draft') returning id into v_run;
  insert into public.timesheet_entries (payroll_run_id, employee_id, regular_hours) values (v_run, e1, 10);

  -- ---------------------------------------------------------- seed default
  out := out || pg_temp.chk('seed trigger default pay_type monthly',
    (select 'ok:' || pay_type from public.employee_compensation where employee_id = e1), 'ok:monthly');

  -- ---------------------------------------------------------- owner
  out := out || pg_temp.chk('owner set e1 monthly 4500', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'monthly', 4500)::text$q$, e1)), 'ok:');
  out := out || pg_temp.chk('owner get e1', pg_temp.try(u_owner,
    format($q$select (public.get_employee_compensation(%L)->>'pay_rate')$q$, e1)), 'ok:4500');
  out := out || pg_temp.chk('audit row compensation_changed (first set)',
    (select 'ok:' || count(*) || ':' || coalesce(max(new_value->>'pay_rate'), '') || ':' || bool_and(entity_id = v_ent and location_id = v_loc and employee_id = e1 and changed_by = u_owner)
       from public.audit_log where action = 'compensation_changed' and record_id = e1), 'ok:1:4500:true');
  out := out || pg_temp.chk('owner change existing rate w/o reason -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'monthly', 5000)::text$q$, e1)), '22023');
  out := out || pg_temp.chk('owner change with reason', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'hourly', 25.50, 1.25, null, 'Moved to hourly')::text$q$, e1)), 'ok:');
  out := out || pg_temp.chk('audit old/new + reason on change',
    (select 'ok:' || (old_value->>'pay_rate') || '>' || (new_value->>'pay_rate') || ':' || (new_value->>'reason') || ':' || (new_value->>'overtime_multiplier') || ':' || (new_value->>'holiday_multiplier')
       from public.audit_log where action = 'compensation_changed' and record_id = e1 and old_value->>'pay_rate' is not null), 'ok:4500.00>25.50:Moved to hourly:1.25:2.00');
  out := out || pg_temp.chk('owner may set pay for pre_boarding', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'monthly', 3000)::text$q$, e3)), 'ok:');

  -- ---------------------------------------------------------- invalid
  out := out || pg_temp.chk('invalid pay_type -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'weekly', 100)::text$q$, e2)), '22023');
  out := out || pg_temp.chk('rate 0 -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'monthly', 0)::text$q$, e2)), '22023');
  out := out || pg_temp.chk('rate null -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'monthly', null)::text$q$, e2)), '22023');
  out := out || pg_temp.chk('rate 1,000,000 -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'monthly', 1000000)::text$q$, e2)), '22023');
  out := out || pg_temp.chk('rate 3 decimals -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'hourly', 25.125)::text$q$, e2)), '22023');
  out := out || pg_temp.chk('OT 3.5 -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'hourly', 25, 3.5)::text$q$, e2)), '22023');
  out := out || pg_temp.chk('holiday 0.5 -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'hourly', 25, null, 0.5)::text$q$, e2)), '22023');
  out := out || pg_temp.chk('inactive employee -> 22023', pg_temp.try(u_owner,
    format($q$select public.set_employee_compensation(%L, 'monthly', 4000)::text$q$, e4)), '22023');

  -- ---------------------------------------------------------- entity_admin
  out := out || pg_temp.chk('EA set own-entity e2', pg_temp.try(u_ea,
    format($q$select public.set_employee_compensation(%L, 'monthly', 4200)::text$q$, e2)), 'ok:');
  out := out || pg_temp.chk('EA get own-entity e2', pg_temp.try(u_ea,
    format($q$select (public.get_employee_compensation(%L)->>'pay_rate')$q$, e2)), 'ok:4200');
  out := out || pg_temp.chk('EA set other-entity e5 -> 42501', pg_temp.try(u_ea,
    format($q$select public.set_employee_compensation(%L, 'monthly', 4200)::text$q$, e5)), '42501');
  out := out || pg_temp.chk('EA get other-entity e5 -> 42501', pg_temp.try(u_ea,
    format($q$select public.get_employee_compensation(%L)::text$q$, e5)), '42501');
  out := out || pg_temp.chk('EA set own pay -> 42501', pg_temp.try(u_ea,
    format($q$select public.set_employee_compensation(%L, 'monthly', 99999)::text$q$, e_ea)), '42501');
  out := out || pg_temp.chk('EA table SELECT still RLS-scoped (own entity rows, none of e5)', pg_temp.try(u_ea,
    format($q$select count(*) filter (where employee_id = %L) || ':' || count(*) filter (where employee_id = %L) from public.employee_compensation$q$, e2, e5)), 'ok:1:0');
  out := out || pg_temp.chk('EA direct UPDATE table -> 42501 (grant revoked)', pg_temp.try(u_ea,
    format($q$with u as (update public.employee_compensation set pay_rate = 1 where employee_id = %L returning 1) select count(*)::text from u$q$, e2)), '42501');
  out := out || pg_temp.chk('EA direct INSERT table -> 42501', pg_temp.try(u_ea,
    format($q$with u as (insert into public.employee_compensation (employee_id) values (%L) returning 1) select count(*)::text from u$q$, e2)), '42501');

  -- ---------------------------------------------------------- location_manager / staff
  out := out || pg_temp.chk('LM set -> 42501', pg_temp.try(u_lm,
    format($q$select public.set_employee_compensation(%L, 'monthly', 4200)::text$q$, e1)), '42501');
  out := out || pg_temp.chk('LM get -> 42501', pg_temp.try(u_lm,
    format($q$select public.get_employee_compensation(%L)::text$q$, e1)), '42501');
  out := out || pg_temp.chk('LM table SELECT -> 0 rows', pg_temp.try(u_lm,
    $q$select count(*)::text from public.employee_compensation$q$), 'ok:0');
  out := out || pg_temp.chk('LM direct UPDATE -> 42501', pg_temp.try(u_lm,
    format($q$with u as (update public.employee_compensation set pay_rate = 1 where employee_id = %L returning 1) select count(*)::text from u$q$, e1)), '42501');
  out := out || pg_temp.chk('LM add_employees_to_payroll_run -> 42501', pg_temp.try(u_lm,
    format($q$select public.add_employees_to_payroll_run(%L)::text$q$, v_run)), '42501');
  out := out || pg_temp.chk('staff get own pay -> 42501', pg_temp.try(u_st,
    format($q$select public.get_employee_compensation(%L)::text$q$, e2)), '42501');
  out := out || pg_temp.chk('staff table SELECT -> 0 rows', pg_temp.try(u_st,
    $q$select count(*)::text from public.employee_compensation$q$), 'ok:0');

  -- ---------------------------------------------------------- add_employees_to_payroll_run
  out := out || pg_temp.chk('EA2 (other entity) add -> 42501', pg_temp.try(u_ea2,
    format($q$select public.add_employees_to_payroll_run(%L)::text$q$, v_run)), '42501');
  out := out || pg_temp.chk('EA add -> 2 (e2 + EA self; skips e1 existing, pre_boarding, inactive, joins-later, other entity)', pg_temp.try(u_ea,
    format($q$select public.add_employees_to_payroll_run(%L)::text$q$, v_run)), 'ok:2');
  out := out || pg_temp.chk('rows in run = e1(10h), e2(0), EA self(0)',
    (select 'ok:' || string_agg(e.full_name || '=' || t.regular_hours::int || coalesce('/' || t.notes, ''), ',' order by e.full_name)
       from public.timesheet_entries t join public.employees e on e.id = t.employee_id where t.payroll_run_id = v_run),
    'ok:W7 E1 active=10,W7 E2 active staff=0/Added automatically,W7 EA self=0/Added automatically');
  out := out || pg_temp.chk('audit payroll_change_succeeded x2',
    (select 'ok:' || count(*) from public.audit_log where action = 'payroll_change_succeeded' and entity_id = v_ent and new_value->>'payroll_run_id' = v_run::text), 'ok:2');
  out := out || pg_temp.chk('second add -> 0 (idempotent)', pg_temp.try(u_owner,
    format($q$select public.add_employees_to_payroll_run(%L)::text$q$, v_run)), 'ok:0');

  -- run_payroll_calculation still works (owner-run definer) with new monthly default
  out := out || pg_temp.chk('run_payroll_calculation as EA', pg_temp.try(u_ea,
    format($q$select public.run_payroll_calculation(%L)::text$q$, v_run)), 'ok:');
  out := out || pg_temp.chk('payslips: e1 hourly 10h*25.50=255, e2 monthly 4200, EA self no rate=0',
    (select 'ok:' || string_agg(p.base_pay::numeric(12,2)::text, ',' order by e.full_name)
       from public.payslips p join public.employees e on e.id = p.employee_id where p.payroll_run_id = v_run), 'ok:255.00,4200.00,0.00');

  -- locked run
  update public.payroll_runs set status = 'in_review' where id = v_run;
  out := out || pg_temp.chk('non-draft run -> 22023', pg_temp.try(u_owner,
    format($q$select public.add_employees_to_payroll_run(%L)::text$q$, v_run)), '22023');

  raise exception 'W7 TEST RESULTS (rolled back)%', E'\n' || out;
end $$;
