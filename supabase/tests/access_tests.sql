-- ============================================================
-- SQL mirror of scripts/access-tests.mjs (negative-access tests).
-- Runs every check with the same Postgres role + JWT claims PostgREST
-- would use (role authenticated/anon, request.jwt.claims.sub = persona),
-- inside ONE transaction that is rolled back (including the temporary
-- revoke of uat.employee.b). Run as postgres in the SQL editor / MCP.
-- Result: one row per check; every row must have pass = true.
-- ============================================================
begin;

create function pg_temp.chk(p_name text, p_sub text, p_mode text, p_sql text)
returns table(test text, pass boolean, detail text)
language plpgsql as $f$
declare
  v_n bigint;
  v_txt text;
begin
  test := p_name;
  begin
    if p_sub = 'anon' then
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      set local role anon;
    else
      perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
      set local role authenticated;
    end if;
    if p_mode = 'zero' then
      execute 'select count(*) from (' || p_sql || ') q' into v_n;
      pass := v_n = 0; detail := v_n || ' row(s)';
    else  -- 'deny': must raise, or return null / empty
      execute 'select left((' || p_sql || ')::text, 120)' into v_txt;
      pass := v_txt is null or v_txt in ('', '[]', '{}'); detail := coalesce('returned: ' || v_txt, 'null');
    end if;
    reset role;
  exception when others then
    reset role;
    pass := true; detail := 'denied: ' || sqlstate || ' ' || sqlerrm;
  end;
  return next;
end $f$;

create temp table personas(k text primary key, sub uuid);
insert into personas values
  ('owner', '4162bf0e-c123-4d8f-93c8-219e7e166c5f'), ('ea_a', '81b68580-a490-4115-be98-70285a51ba99'),
  ('ea_b', '054b6210-bf56-492d-9fae-983f2b0228cd'), ('lm_a', '545cf168-7595-4ccb-8c37-c4c434f5f1c0'),
  ('lm_b', 'a6ee82c3-d925-44e7-941b-6d7e65b9fccc'), ('st_a', '5f353b67-2e93-4cea-bd44-9ad2d6b4bfd9'),
  ('st_b', '99a456ae-bdf5-40ca-b0fb-fc741a525cd5'), ('st_c', '3ad8afc0-0fa2-4abc-8eba-63776f56ca19');
grant select on personas to authenticated, anon;

create temp table results(test text, pass boolean, detail text);
grant insert on results to authenticated, anon;

-- ---------------------------------------------------------------- LM
insert into results select * from pg_temp.chk('LM: employee_compensation', (select sub::text from personas where k='lm_a'), 'zero', 'select * from public.employee_compensation');
insert into results select * from pg_temp.chk('LM: payslips of others', (select sub::text from personas where k='lm_a'), 'zero', $$select * from public.payslips where employee_id <> 'a0000000-0000-4000-8000-000000000034'$$);
insert into results select * from pg_temp.chk('LM: payroll_runs', (select sub::text from personas where k='lm_a'), 'zero', 'select * from public.payroll_runs');
insert into results select * from pg_temp.chk('LM: employee_identity_documents', (select sub::text from personas where k='lm_a'), 'zero', 'select * from public.employee_identity_documents');
insert into results select * from pg_temp.chk('LM: offers', (select sub::text from personas where k='lm_a'), 'zero', 'select * from public.offers');
insert into results select * from pg_temp.chk('LM: payslip_deductions of others', (select sub::text from personas where k='lm_a'), 'zero', $$select * from public.payslip_deductions where employee_id <> 'a0000000-0000-4000-8000-000000000034'$$);
insert into results select * from pg_temp.chk('LM: timesheet_entries of others', (select sub::text from personas where k='lm_a'), 'zero', $$select * from public.timesheet_entries where employee_id <> 'a0000000-0000-4000-8000-000000000034'$$);
insert into results select * from pg_temp.chk('LM: run_payroll_calculation', (select sub::text from personas where k='lm_a'), 'deny', $$public.run_payroll_calculation('a0000000-0000-4000-8000-000000000202')$$);
insert into results select * from pg_temp.chk('LM: get_wps_export_readiness', (select sub::text from personas where k='lm_a'), 'deny', $$(select json_agg(x) from public.get_wps_export_readiness('a0000000-0000-4000-8000-000000000202') x)$$);
insert into results select * from pg_temp.chk('LM: record_timesheet_entry', (select sub::text from personas where k='lm_a'), 'deny', $$nullif(public.record_timesheet_entry('a0000000-0000-4000-8000-000000000202','a0000000-0000-4000-8000-000000000031',1,0,0,'x')->>'ok', 'false')$$);
insert into results select * from pg_temp.chk('LM: record_payslip_deduction', (select sub::text from personas where k='lm_a'), 'deny', $$nullif(public.record_payslip_deduction('a0000000-0000-4000-8000-000000000202','a0000000-0000-4000-8000-000000000031','other',1,'x')->>'ok', 'false')$$);
insert into results select * from pg_temp.chk('LM: create_payroll_revision', (select sub::text from personas where k='lm_a'), 'deny', $$public.create_payroll_revision('f9d3862d-78f8-43bc-a62e-6d2ac12a2495')$$);
insert into results select * from pg_temp.chk('LM: get_owner_dashboard_kpis', (select sub::text from personas where k='lm_a'), 'deny', $$public.get_owner_dashboard_kpis(null)$$);
insert into results select * from pg_temp.chk('LM: get_payroll_payslip', (select sub::text from personas where k='lm_a'), 'deny', $$public.get_payroll_payslip('db483dd6-a0c7-4301-bbf2-3b1505efac5f')$$);
insert into results select * from pg_temp.chk('LM: data_retention_policies', (select sub::text from personas where k='lm_a'), 'zero', 'select * from public.data_retention_policies');
insert into results select * from pg_temp.chk('staff A: get_payroll_payslip', (select sub::text from personas where k='st_a'), 'deny', $$public.get_payroll_payslip('06d18772-7843-4fab-b305-cc49f9be5116')$$);
insert into results select * from pg_temp.chk('staff A: data_retention_policies', (select sub::text from personas where k='st_a'), 'zero', 'select * from public.data_retention_policies');
insert into results select * from pg_temp.chk('ea_b: get_payroll_payslip(A)', (select sub::text from personas where k='ea_b'), 'deny', $$public.get_payroll_payslip('06d18772-7843-4fab-b305-cc49f9be5116')$$);

-- ---------------------------------------------------------------- staff
insert into results select * from pg_temp.chk('staff A: other employees', (select sub::text from personas where k='st_a'), 'zero', $$select * from public.employees where id <> 'a0000000-0000-4000-8000-000000000031'$$);
insert into results select * from pg_temp.chk('staff A: others leave_requests', (select sub::text from personas where k='st_a'), 'zero', $$select * from public.leave_requests where employee_id <> 'a0000000-0000-4000-8000-000000000031'$$);
insert into results select * from pg_temp.chk('staff A: others attendance_records', (select sub::text from personas where k='st_a'), 'zero', $$select * from public.attendance_records where employee_id <> 'a0000000-0000-4000-8000-000000000031'$$);
insert into results select * from pg_temp.chk('staff A: others payslips', (select sub::text from personas where k='st_a'), 'zero', $$select * from public.payslips where employee_id <> 'a0000000-0000-4000-8000-000000000031'$$);
insert into results select * from pg_temp.chk('staff A: others employee_documents', (select sub::text from personas where k='st_a'), 'zero', $$select * from public.employee_documents where employee_id <> 'a0000000-0000-4000-8000-000000000031'$$);
insert into results select * from pg_temp.chk('staff A: others leave_balances', (select sub::text from personas where k='st_a'), 'zero', $$select * from public.leave_balances where employee_id <> 'a0000000-0000-4000-8000-000000000031'$$);
insert into results select * from pg_temp.chk('staff A: draft payslips', (select sub::text from personas where k='st_a'), 'zero', $$select p.* from public.payslips p where p.payroll_run_id = 'a0000000-0000-4000-8000-000000000202'$$);
insert into results select * from pg_temp.chk('staff A: unpublished shifts', (select sub::text from personas where k='st_a'), 'zero', $$select * from public.shifts where is_published = false$$);
insert into results select * from pg_temp.chk('staff A: employee_compensation', (select sub::text from personas where k='st_a'), 'zero', 'select * from public.employee_compensation');
insert into results select * from pg_temp.chk('staff A: employee_identity_documents', (select sub::text from personas where k='st_a'), 'zero', 'select * from public.employee_identity_documents');
insert into results select * from pg_temp.chk('staff A: approve own leave', (select sub::text from personas where k='st_a'), 'deny', $$public.approve_leave_request('a0000000-0000-4000-8000-000000000101','approve',false,null)$$);
insert into results select * from pg_temp.chk('staff A: approve own document', (select sub::text from personas where k='st_a'), 'deny', $$public.approve_document('a0000000-0000-4000-8000-000000000112')$$);
insert into results select * from pg_temp.chk('staff A: get_my_payslip of B', (select sub::text from personas where k='st_a'), 'deny', $$public.get_my_payslip('f8b66299-9a87-497d-a6e2-0cd1b3647c66')$$);  -- employee B, published August run
insert into results select * from pg_temp.chk('staff A: completeness of B', (select sub::text from personas where k='st_a'), 'deny', $$public.get_employee_completeness('a0000000-0000-4000-8000-000000000032')$$);
insert into results select * from pg_temp.chk('staff A: admin_list_user_access', (select sub::text from personas where k='st_a'), 'deny', $$(select json_agg(x) from public.admin_list_user_access(null) x)$$);

-- ---------------------------------------------------------------- entity isolation
insert into results
select r.* from (values ('ea_a','a0000000-0000-4000-8000-000000000002'), ('ea_b','a0000000-0000-4000-8000-000000000001'),
                        ('lm_a','a0000000-0000-4000-8000-000000000002'), ('lm_b','a0000000-0000-4000-8000-000000000001'),
                        ('st_c','a0000000-0000-4000-8000-000000000001'), ('st_a','a0000000-0000-4000-8000-000000000002')) v(k, other),
     lateral (values ('employees'), ('shifts'), ('payroll_runs'), ('attendance_records'), ('locations'), ('workflow_rules'), ('notifications')) t(tbl),
     lateral pg_temp.chk(v.k || ' -> other entity: ' || t.tbl, (select sub::text from personas p where p.k = v.k), 'zero',
                         format('select * from public.%I where entity_id = %L', t.tbl, v.other)) r;
insert into results
select r.* from (values ('ea_a','a0000000-0000-4000-8000-000000000002'), ('ea_b','a0000000-0000-4000-8000-000000000001'),
                        ('lm_a','a0000000-0000-4000-8000-000000000002'), ('lm_b','a0000000-0000-4000-8000-000000000001'),
                        ('st_c','a0000000-0000-4000-8000-000000000001'), ('st_a','a0000000-0000-4000-8000-000000000002')) v(k, other),
     lateral (values ('leave_requests'), ('payslips'), ('employee_documents'), ('leave_balances')) t(tbl),
     lateral pg_temp.chk(v.k || ' -> other entity: ' || t.tbl, (select sub::text from personas p where p.k = v.k), 'zero',
                         format('select x.* from public.%I x where x.employee_id in (select e.id from public.employees e where e.entity_id = %L)
                                 or x.employee_id in (%L, %L, %L, %L)', t.tbl, v.other,
                                case when v.other like '%1' then 'a0000000-0000-4000-8000-000000000031' else 'a0000000-0000-4000-8000-000000000033' end,
                                case when v.other like '%1' then 'a0000000-0000-4000-8000-000000000032' else 'a0000000-0000-4000-8000-000000000033' end,
                                case when v.other like '%1' then 'a0000000-0000-4000-8000-000000000034' else 'a0000000-0000-4000-8000-000000000033' end,
                                case when v.other like '%1' then 'a0000000-0000-4000-8000-000000000035' else 'a0000000-0000-4000-8000-000000000033' end)) r;
insert into results select * from pg_temp.chk('ea_a: get_workflow_rules(B)', (select sub::text from personas where k='ea_a'), 'deny', $$(select json_agg(x) from public.get_workflow_rules(null,'a0000000-0000-4000-8000-000000000002') x)$$);
insert into results select * from pg_temp.chk('ea_a: admin_list_user_access(B)', (select sub::text from personas where k='ea_a'), 'deny', $$(select json_agg(x) from public.admin_list_user_access('a0000000-0000-4000-8000-000000000002') x)$$);
insert into results select * from pg_temp.chk('ea_a: get_owner_dashboard_kpis(B)', (select sub::text from personas where k='ea_a'), 'deny', $$public.get_owner_dashboard_kpis('a0000000-0000-4000-8000-000000000002')$$);
insert into results select * from pg_temp.chk('ea_a: get_entity_dependency_summary(B)', (select sub::text from personas where k='ea_a'), 'deny', $$public.get_entity_dependency_summary('a0000000-0000-4000-8000-000000000002',null)$$);
insert into results select * from pg_temp.chk('ea_a: get_documents_for_review(B)', (select sub::text from personas where k='ea_a'), 'deny', $$(select json_agg(x) from public.get_documents_for_review('a0000000-0000-4000-8000-000000000002') x)$$);
insert into results select * from pg_temp.chk('ea_a: get_attendance_exceptions(B1)', (select sub::text from personas where k='ea_a'), 'deny', $$(select json_agg(x) from public.get_attendance_exceptions('a0000000-0000-4000-8000-000000000013', current_date-30, current_date) x)$$);
insert into results select * from pg_temp.chk('ea_a: admin_upsert_entity', (select sub::text from personas where k='ea_a'), 'deny', $$public.admin_upsert_entity('a0000000-0000-4000-8000-000000000002','x',null,null,null,null,null,true)$$);
insert into results select * from pg_temp.chk('ea_b: run_payroll_calculation(A)', (select sub::text from personas where k='ea_b'), 'deny', $$public.run_payroll_calculation('a0000000-0000-4000-8000-000000000202')$$);

-- ---------------------------------------------------------------- P0-1 leave vs schedule
insert into results select * from pg_temp.chk('staff A: publish_schedule_period', (select sub::text from personas where k='st_a'), 'deny', $$public.publish_schedule_period('a0000000-0000-4000-8000-000000000011', current_date, current_date + 7)$$);
insert into results select * from pg_temp.chk('lm_b: approve Entity A leave', (select sub::text from personas where k='lm_b'), 'deny', $$public.approve_leave_request('a0000000-0000-4000-8000-000000000101','approve',false,null)$$);
insert into results select * from pg_temp.chk('ea_b: publish Branch A1', (select sub::text from personas where k='ea_b'), 'deny', $$public.publish_schedule_period('a0000000-0000-4000-8000-000000000011', current_date, current_date + 7)$$);

-- ---------------------------------------------------------------- revoked profile (rolled back)
insert into results select * from pg_temp.chk('setup: revoke employee B', (select sub::text from personas where k='ea_a'), 'deny', $$public.admin_revoke_access('99a456ae-bdf5-40ca-b0fb-fc741a525cd5', null, 'access test (rolled back)')$$);
insert into results
select r.* from (values ('employees'), ('shifts'), ('leave_requests'), ('attendance_records'), ('payslips'),
                        ('employee_documents'), ('leave_balances'), ('notifications'), ('payroll_runs')) t(tbl),
     lateral pg_temp.chk('revoked B: ' || t.tbl, (select sub::text from personas where k='st_b'), 'zero', format('select * from public.%I', t.tbl)) r;
insert into results select * from pg_temp.chk('revoked B: get_my_payslips', (select sub::text from personas where k='st_b'), 'deny', $$(select json_agg(x) from public.get_my_payslips() x)$$);
insert into results select * from pg_temp.chk('revoked B: clock_in', (select sub::text from personas where k='st_b'), 'deny', $$public.clock_in()$$);
insert into results select * from pg_temp.chk('revoked B: get_my_attendance', (select sub::text from personas where k='st_b'), 'deny', $$(select json_agg(x) from public.get_my_attendance('2020-01-01','2030-12-31') x)$$);
insert into results select * from pg_temp.chk('revoked B: get_my_notifications', (select sub::text from personas where k='st_b'), 'deny', $$(select json_agg(x) from public.get_my_notifications(50,null,false) x)$$);
-- no-role guard hotfix: a revoked user must be refused by role-checked RPCs
insert into results select * from pg_temp.chk('revoked B: approve_document', (select sub::text from personas where k='st_b'), 'deny', $$public.approve_document('a0000000-0000-4000-8000-000000000112')$$);
insert into results select * from pg_temp.chk('revoked B: approve_leave_request', (select sub::text from personas where k='st_b'), 'deny', $$public.approve_leave_request('a0000000-0000-4000-8000-000000000101','approve',false,null)$$);
insert into results select * from pg_temp.chk('revoked B: grant_leave_balance', (select sub::text from personas where k='st_b'), 'deny', $$public.grant_leave_balance('a0000000-0000-4000-8000-000000000031', gen_random_uuid(), 5, 'x')$$);
insert into results select * from pg_temp.chk('revoked B: publish_schedule_period', (select sub::text from personas where k='st_b'), 'deny', $$public.publish_schedule_period('a0000000-0000-4000-8000-000000000011', current_date, current_date + 7)$$);

-- ---------------------------------------------------------------- anon
insert into results
select r.* from (values ('employees'), ('profiles'), ('shifts'), ('leave_requests'), ('attendance_records'), ('payslips'),
                        ('payroll_runs'), ('employee_compensation'), ('employee_identity_documents'), ('employee_documents'),
                        ('entities'), ('locations'), ('audit_log'), ('notifications'), ('workflow_rules'), ('access_grants'),
                        ('offers'), ('candidates'), ('leave_balances'), ('data_retention_policies')) t(tbl),
     lateral pg_temp.chk('anon: ' || t.tbl, 'anon', 'zero', format('select * from public.%I', t.tbl)) r;
insert into results select * from pg_temp.chk('anon: get_my_clock_status', 'anon', 'deny', $$public.get_my_clock_status()$$);
insert into results select * from pg_temp.chk('anon: clock_in', 'anon', 'deny', $$public.clock_in()$$);
insert into results select * from pg_temp.chk('anon: get_my_payslips', 'anon', 'deny', $$(select json_agg(x) from public.get_my_payslips() x)$$);
insert into results select * from pg_temp.chk('anon: get_owner_dashboard_kpis', 'anon', 'deny', $$public.get_owner_dashboard_kpis(null)$$);
insert into results select * from pg_temp.chk('anon: workflow_trigger_catalog', 'anon', 'deny', $$public.workflow_trigger_catalog()$$);
insert into results select * from pg_temp.chk('anon: get_payroll_payslip', 'anon', 'deny', $$public.get_payroll_payslip('06d18772-7843-4fab-b305-cc49f9be5116')$$);

select count(*) filter (where pass) as passed, count(*) as total,
       coalesce(json_agg(json_build_object('test', test, 'detail', detail)) filter (where not pass), '[]') as failures
  from results where test not like 'setup:%';
rollback;
