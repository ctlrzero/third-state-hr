-- ============================================================
-- DB-side end-to-end journeys (TS-HR UAT personas).
--
-- Each journey impersonates a persona exactly the way PostgREST does:
--   set local role authenticated;
--   select set_config('request.jwt.claims', {"sub": <uuid>, "role": "authenticated"}, true);
-- and calls the same RPCs / table reads the frontend uses.
--
-- Everything runs in ONE transaction that is ROLLED BACK at the end, so
-- nothing is persisted. Only UAT Entity A/B and uat.*@example.com personas
-- are touched. Run as postgres (SQL editor / Supabase MCP execute_sql).
--
-- Output: one row per journey (journey, pass, detail). Every row must have
-- pass = true. A failing journey reports the first failed assertion.
-- ============================================================
begin;

create temp table e2e_results(journey text, pass boolean, detail text);
grant all on e2e_results to authenticated;

-- Impersonate a persona (PostgREST-equivalent). Persists until the next login() / reset role.
create function pg_temp.login(p_sub uuid) returns void language plpgsql as $f$
begin
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
  set local role authenticated;
end $f$;

create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $f$
begin
  if p_cond is distinct from true then
    raise exception 'ASSERT: %', p_msg;
  end if;
end $f$;

-- Expect an RPC (given as SQL text) to raise; returns the SQLSTATE.
create function pg_temp.expect_error(p_sql text, p_msg text) returns text language plpgsql as $f$
begin
  execute p_sql;
  raise exception 'ASSERT: expected an error: %', p_msg using errcode = 'XX999';
exception
  when sqlstate 'XX999' then raise;
  when others then return sqlstate;
end $f$;

grant execute on function pg_temp.login(uuid), pg_temp.ok(boolean, text), pg_temp.expect_error(text, text) to authenticated;

-- Persona ids (auth.users.id) and fixture ids
--   owner         4162bf0e-c123-4d8f-93c8-219e7e166c5f
--   entityadmin.a 81b68580-a490-4115-be98-70285a51ba99   (UAT Entity A  a0..001)
--   entityadmin.b 054b6210-bf56-492d-9fae-983f2b0228cd   (UAT Entity B  a0..002)
--   locmanager.a  545cf168-7595-4ccb-8c37-c4c434f5f1c0   (Branch A1     a0..011, employee a0..034)
--   locmanager.b  a6ee82c3-d925-44e7-941b-6d7e65b9fccc   (Branch B1     a0..013)
--   employee.a    5f353b67-2e93-4cea-bd44-9ad2d6b4bfd9   (employee a0..031, Branch A1)
--   employee.c    3ad8afc0-0fa2-4abc-8eba-63776f56ca19   (employee a0..033, Entity B)
--   new starter   employee a0..035 (pre_boarding, no login)

-- ------------------------------------------------------------ J1 staff employee.a
do $j$
declare
  v jsonb; v2 jsonb; v_status jsonb; v_n int; v_id uuid; v_code text; r record;
begin
  perform pg_temp.login('5f353b67-2e93-4cea-bd44-9ad2d6b4bfd9');

  -- Clock screen
  v_status := public.get_my_clock_status();
  perform pg_temp.ok(v_status ?& array['state','business_date','server_time','today_shift','attendance'], 'clock status shape');
  perform pg_temp.ok(v_status->>'state' in ('not_started','no_shift','clocked_in','clocked_out'), 'clock state value');

  v := public.clock_in();
  perform pg_temp.ok(v ?& array['id','shift_id','clock_in_at','already_clocked_in'], 'clock_in shape');
  v2 := public.clock_in();  -- idempotent repeat tap
  perform pg_temp.ok((v2->>'already_clocked_in')::boolean and v2->>'id' = v->>'id', 'clock_in idempotent');
  perform pg_temp.ok(public.get_my_clock_status()->>'state' = 'clocked_in', 'state clocked_in after clock_in');

  v2 := public.clock_out();
  perform pg_temp.ok(v2 ?& array['id','clock_out_at','already_clocked_out'] and v2->>'id' = v->>'id', 'clock_out shape');
  v2 := public.clock_out();  -- idempotent repeat tap
  perform pg_temp.ok((v2->>'already_clocked_out')::boolean and v2->>'id' = v->>'id', 'clock_out idempotent');
  perform pg_temp.ok(public.get_my_clock_status()->>'state' = 'clocked_out', 'state clocked_out after clock_out');

  select count(*) into v_n from public.get_my_attendance(
      (v_status->>'business_date')::date, (v_status->>'business_date')::date) a
   where a.attendance_id = (v->>'id')::uuid and a.clock_out_at is not null;
  perform pg_temp.ok(v_n = 1, 'get_my_attendance shows today''s record');

  -- Leave request (same insert the Leave page makes) -> pending, balance reserved
  insert into public.leave_requests (employee_id, leave_type_id, start_date, end_date, days_requested, status, reason)
  values ('a0000000-0000-4000-8000-000000000031', 'a0000000-0000-4000-8000-000000000041',
          '2026-12-14', '2026-12-15', 2, 'pending', 'e2e journey (rolled back)')
  returning id into v_id;
  select * into r from public.leave_requests where id = v_id;
  perform pg_temp.ok(r.status = 'pending' and r.balance_reserved, 'leave pending and reserved');

  -- Payslips: own published only
  select count(*) into v_n from public.get_my_payslips() p where p.run_status not in ('approved','paid');
  perform pg_temp.ok(v_n = 0, 'get_my_payslips has only published runs');
  select count(*) into v_n from public.get_my_payslips();
  perform pg_temp.ok(v_n >= 1, 'get_my_payslips returns own published payslips');
  v := public.get_my_payslip('06d18772-7843-4fab-b305-cc49f9be5116');  -- own, August (approved)
  perform pg_temp.ok(v->'employee'->>'employee_id' = 'a0000000-0000-4000-8000-000000000031'
                        and v ? 'net_pay' and v->'employee' ? 'position_title', 'get_my_payslip own detail');
  v_code := pg_temp.expect_error($$select public.get_my_payslip('f8b66299-9a87-497d-a6e2-0cd1b3647c66')$$, 'payslip of employee B');
  perform pg_temp.ok(v_code = 'P0002', 'other employee payslip -> P0002');
  v_code := pg_temp.expect_error($$select public.get_my_payslip('db483dd6-a0c7-4301-bbf2-3b1505efac5f')$$, 'own draft payslip');
  perform pg_temp.ok(v_code = 'P0002', 'own draft payslip -> P0002');
  select count(*) into v_n from public.payslips where employee_id <> 'a0000000-0000-4000-8000-000000000031';
  perform pg_temp.ok(v_n = 0, 'no other employees'' payslips via table');

  -- Draft shifts never visible
  select count(*) into v_n from public.shifts where is_published = false;
  perform pg_temp.ok(v_n = 0, 'staff sees no draft shifts');

  -- Admin payslip RPC is not for staff
  v_code := pg_temp.expect_error($$select public.get_payroll_payslip('06d18772-7843-4fab-b305-cc49f9be5116')$$, 'staff get_payroll_payslip');
  perform pg_temp.ok(v_code = '42501', 'staff get_payroll_payslip -> 42501');

  reset role;
  insert into e2e_results values ('J1 staff employee.a: clock, attendance, leave, payslips, draft shifts', true, 'ok');
exception when others then
  reset role;
  insert into e2e_results values ('J1 staff employee.a: clock, attendance, leave, payslips, draft shifts', false, sqlstate || ' ' || sqlerrm);
end $j$;

-- ------------------------------------------------------------ J2 locationmanager.a
do $j$
declare
  v_n int; v_rec uuid; v_orig timestamptz; r record; v_code text;
begin
  perform pg_temp.login('545cf168-7595-4ccb-8c37-c4c434f5f1c0');

  -- Exception queue for own branch
  select count(*) into v_n from public.get_attendance_exceptions(
      'a0000000-0000-4000-8000-000000000011', current_date - 14, current_date);
  perform pg_temp.ok(v_n >= 1, 'LM sees exception queue for own branch');

  -- Correct employee A's record (not own) with a reason; original is kept
  select a.id, a.clock_in_at into v_rec, v_orig from public.attendance_records a
   where a.employee_id = 'a0000000-0000-4000-8000-000000000031' and a.clock_out_at is not null
     and a.clock_in_at < now() - interval '1 day'
   order by a.clock_in_at desc limit 1;
  perform pg_temp.ok(v_rec is not null, 'LM can read employee A attendance');
  perform public.correct_attendance_record(v_rec, v_orig - interval '15 minutes', null, 'e2e: forgot to clock in on time');
  select * into r from public.attendance_records where id = v_rec;
  perform pg_temp.ok(r.corrected and r.correction_reason like 'e2e:%'
                        and r.original_clock_in_at = v_orig and r.clock_in_at = v_orig - interval '15 minutes'
                        and r.clock_out_at is not null, 'correction applied, original kept, clock-out kept');
  v_code := pg_temp.expect_error(format($$select public.correct_attendance_record(%L, null, null, '')$$, v_rec), 'correction without reason');
  perform pg_temp.ok(v_code is not null, 'correction without reason rejected');

  -- Approve own staff's pending leave
  perform public.approve_leave_request('a0000000-0000-4000-8000-000000000101', 'approve', false, null);
  select * into r from public.leave_requests where id = 'a0000000-0000-4000-8000-000000000101';
  perform pg_temp.ok(r.status = 'approved', 'LM approved leave for own staff');

  -- Nothing from payroll / compensation
  select count(*) into v_n from public.payroll_runs;              perform pg_temp.ok(v_n = 0, 'LM payroll_runs = 0');
  select count(*) into v_n from public.employee_compensation;     perform pg_temp.ok(v_n = 0, 'LM employee_compensation = 0');
  select count(*) into v_n from public.payslips where employee_id <> 'a0000000-0000-4000-8000-000000000034';
  perform pg_temp.ok(v_n = 0, 'LM sees no other payslips');
  select count(*) into v_n from public.timesheet_entries where employee_id <> 'a0000000-0000-4000-8000-000000000034';
  perform pg_temp.ok(v_n = 0, 'LM sees no other timesheets');
  v_code := pg_temp.expect_error($$select public.run_payroll_calculation('a0000000-0000-4000-8000-000000000202')$$, 'LM payroll calc');
  perform pg_temp.ok(v_code is not null, 'LM run_payroll_calculation denied');
  v_code := pg_temp.expect_error($$select public.get_payroll_payslip('db483dd6-a0c7-4301-bbf2-3b1505efac5f')$$, 'LM admin payslip');
  perform pg_temp.ok(v_code = '42501', 'LM get_payroll_payslip -> 42501');
  select count(*) into v_n from public.data_retention_policies;   perform pg_temp.ok(v_n = 0, 'LM retention policies = 0');

  reset role;
  insert into e2e_results values ('J2 locationmanager.a: exceptions, correction, leave approval, no payroll', true, 'ok');
exception when others then
  reset role;
  insert into e2e_results values ('J2 locationmanager.a: exceptions, correction, leave approval, no payroll', false, sqlstate || ' ' || sqlerrm);
end $j$;

-- ------------------------------------------------------------ J3 entityadmin.a
do $j$
declare
  v_grant uuid; v_loc uuid; v_rule uuid; v_n int; v_txt text; r record; v jsonb; v_code text;
begin
  perform pg_temp.login('81b68580-a490-4115-be98-70285a51ba99');

  -- Grant access to a new email -> pending grant; then revoke with reason
  v_grant := public.admin_grant_access('uat.e2e.newstarter@example.com', 'staff',
      'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000011', 'a0000000-0000-4000-8000-000000000035');
  select * into r from public.access_grants where id = v_grant;
  perform pg_temp.ok(r.status = 'pending' and r.applied_user_id is null, 'grant is pending');
  select count(*) into v_n from public.admin_list_user_access('a0000000-0000-4000-8000-000000000001') u
   where u.grant_id = v_grant and u.is_pending;
  perform pg_temp.ok(v_n = 1, 'pending grant listed in Users & access');
  v_code := pg_temp.expect_error(format($$select public.admin_revoke_access(null, %L, '')$$, v_grant), 'revoke without reason');
  perform pg_temp.ok(v_code = '22023', 'revoke without reason -> 22023');
  perform public.admin_revoke_access(null, v_grant, 'e2e: offer withdrawn');
  select * into r from public.access_grants where id = v_grant;
  perform pg_temp.ok(r.status = 'revoked' and r.revoke_reason = 'e2e: offer withdrawn', 'grant revoked with reason');

  -- Create a branch
  v_loc := public.admin_upsert_location(null, 'a0000000-0000-4000-8000-000000000001', 'UAT E2E Branch', 'E2E', 'Dubai', true);
  select count(*) into v_n from public.locations where id = v_loc and entity_id = 'a0000000-0000-4000-8000-000000000001';
  perform pg_temp.ok(v_n = 1, 'branch created in own entity');

  -- Employee lifecycle pre_boarding -> active: refused until key documents are approved and in date
  v_code := pg_temp.expect_error($$select public.set_employee_status('a0000000-0000-4000-8000-000000000035', 'active', 'e2e: first day')$$,
                                 'activate without key documents');
  perform pg_temp.ok(v_code = '22023', 'activation without key documents -> 22023');
  reset role;
  set local session_replication_role = replica;   -- fixture docs only; skips the upload/review triggers
  insert into public.employee_documents(employee_id, doc_type, expiry_date, review_status, storage_path, reviewed_by, reviewed_at)
  select 'a0000000-0000-4000-8000-000000000035', d::public.document_type, current_date + 365, 'approved', 'e2e/' || d,
         '81b68580-a490-4115-be98-70285a51ba99'::uuid, now()
    from unnest(array['passport', 'visa', 'emirates_id', 'contract']) d;
  set local session_replication_role = origin;
  perform pg_temp.login('81b68580-a490-4115-be98-70285a51ba99');
  perform public.set_employee_status('a0000000-0000-4000-8000-000000000035', 'active', 'e2e: first day');
  select count(*) into v_n from public.employees where id = 'a0000000-0000-4000-8000-000000000035' and employment_status = 'active';
  perform pg_temp.ok(v_n = 1, 'new starter is active');
  v := public.get_employee_completeness('a0000000-0000-4000-8000-000000000035');
  perform pg_temp.ok(v ? 'percent' and v ? 'missing', 'completeness shape');

  -- Workflow rule: create -> test -> activate
  v_rule := public.create_workflow_rule('E2E long leave', 'leave', 'leave_submitted', 'days_requested', 'gte', '3',
                                        'notify_role', 'entity_admin', 'A leave request of 3+ days needs review', null);
  v_txt := public.test_workflow_rule(v_rule, '{"days_requested": 5}'::jsonb);
  perform pg_temp.ok(v_txt = 'matched', 'rule matches 5 days');
  v_txt := public.test_workflow_rule(v_rule, '{"days_requested": 1}'::jsonb);
  perform pg_temp.ok(v_txt = 'skipped', 'rule skips 1 day');
  perform public.activate_workflow_rule(v_rule);
  select count(*) into v_n from public.get_workflow_rules('leave', null) w where w.id = v_rule and w.is_active;
  perform pg_temp.ok(v_n = 1, 'rule active and listed');

  -- Publish a schedule period (draft shift on 2026-10-04 at Branch A1)
  v_n := public.publish_schedule_period('a0000000-0000-4000-8000-000000000011', '2026-10-04', '2026-10-04');
  perform pg_temp.ok(v_n >= 1, 'publish_schedule_period published draft shifts');
  select count(*) into v_n from public.shifts
   where location_id = 'a0000000-0000-4000-8000-000000000011' and shift_date = '2026-10-04' and not is_published;
  perform pg_temp.ok(v_n = 0, 'no draft shifts left in the period');

  -- Payroll calculation on the draft run
  perform public.run_payroll_calculation('a0000000-0000-4000-8000-000000000202');
  select count(*) into v_n from public.payslips where payroll_run_id = 'a0000000-0000-4000-8000-000000000202';
  perform pg_temp.ok(v_n >= 1, 'draft run has payslips after calculation');

  -- Admin payslip PDF data (real version / position / branch)
  -- (calculation may regenerate payslip rows, so look the id up again)
  select id into v_code from public.payslips
   where payroll_run_id = 'a0000000-0000-4000-8000-000000000202' and employee_id = 'a0000000-0000-4000-8000-000000000031';
  v := public.get_payroll_payslip(v_code::uuid);
  perform pg_temp.ok(v->>'run_status' = 'draft' and (v->>'version')::int >= 1
                        and v->'employee' ?& array['position_title','location_name']
                        and v->'employee'->>'location_name' is not null, 'get_payroll_payslip returns real data');

  -- Retention: own entity only
  perform public.propose_data_retention_policy('leave_requests', 5, 'manual_review', 'e2e', null);
  select count(*) into v_n from public.data_retention_policies where entity_id <> 'a0000000-0000-4000-8000-000000000001';
  perform pg_temp.ok(v_n = 0, 'EA reads only own entity retention policies');
  select count(*) into v_n from public.data_retention_policies where entity_id = 'a0000000-0000-4000-8000-000000000001';
  perform pg_temp.ok(v_n >= 1, 'EA reads own entity retention policy');

  reset role;
  insert into e2e_results values ('J3 entityadmin.a: access grant/revoke, branch, lifecycle, workflow, publish, payroll', true, 'ok');
exception when others then
  reset role;
  insert into e2e_results values ('J3 entityadmin.a: access grant/revoke, branch, lifecycle, workflow, publish, payroll', false, sqlstate || ' ' || sqlerrm);
end $j$;

-- ------------------------------------------------------------ J4 owner
do $j$
declare
  v jsonb; v_n int;
begin
  perform pg_temp.login('4162bf0e-c123-4d8f-93c8-219e7e166c5f');

  v := public.get_owner_dashboard_kpis(null);
  perform pg_temp.ok(v->>'scope' = 'all_entities'
                        and v ?& array['headcount','document_expiry','document_review_queue','leave','payroll','recruitment','workflow'],
                        'owner KPIs across all entities');
  perform pg_temp.ok((v->'headcount'->>'total')::int >=
                        (select count(*) from public.employees where entity_id in
                           ('a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002')),
                        'owner headcount covers both UAT entities');
  v := public.get_owner_dashboard_kpis('a0000000-0000-4000-8000-000000000002');
  perform pg_temp.ok(v->>'scope' = 'entity', 'owner KPIs for one entity');

  select count(*) into v_n from public.entities
   where id in ('a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002');
  perform pg_temp.ok(v_n = 2, 'owner sees both UAT entities');
  select count(distinct entity_id) into v_n from public.employees
   where entity_id in ('a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002');
  perform pg_temp.ok(v_n = 2, 'owner sees employees in both UAT entities');
  select count(distinct entity_id) into v_n from public.locations
   where entity_id in ('a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002');
  perform pg_temp.ok(v_n = 2, 'owner sees branches in both UAT entities');

  select count(*) into v_n from public.data_retention_policies;
  perform pg_temp.ok(v_n >= 1, 'owner sees retention policies (entity_id NULL on profile)');

  select count(*) into v_n from public.get_audit_log(20);
  perform pg_temp.ok(v_n >= 1, 'owner reads audit log');
  select count(*) into v_n from public.export_audit_log(now() - interval '30 days', now(), null, null, null, null,
                                                        'a0000000-0000-4000-8000-000000000001', null, null);
  perform pg_temp.ok(v_n >= 0, 'owner can export audit log');

  select count(*) into v_n from public.admin_list_user_access(null);
  perform pg_temp.ok(v_n >= 8, 'owner lists access across entities');
  select count(*) into v_n from public.get_workflow_rules(null, null) w
   where w.entity_id in ('a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002');
  perform pg_temp.ok(v_n >= 1, 'owner lists workflow rules across entities');

  v := public.get_payroll_payslip('06d18772-7843-4fab-b305-cc49f9be5116');
  perform pg_temp.ok(v->>'run_status' in ('approved','paid') and v->'employee'->>'location_name' is not null,
                        'owner get_payroll_payslip');

  reset role;
  insert into e2e_results values ('J4 owner: group KPIs, both entities, retention, audit', true, 'ok');
exception when others then
  reset role;
  insert into e2e_results values ('J4 owner: group KPIs, both entities, retention, audit', false, sqlstate || ' ' || sqlerrm);
end $j$;

-- ------------------------------------------------------------ J5 cross-entity isolation
do $j$
declare
  v_sub uuid; v_n int; t text; v_code text;
  a constant uuid := 'a0000000-0000-4000-8000-000000000001';
begin
  foreach v_sub in array array['054b6210-bf56-492d-9fae-983f2b0228cd', 'a6ee82c3-d925-44e7-941b-6d7e65b9fccc']::uuid[] loop
    perform pg_temp.login(v_sub);
    foreach t in array array['employees','locations','shifts','attendance_records','payroll_runs','notifications','access_grants','data_retention_policies','schedule_templates',
                             'payable_shift_records','job_requisitions','candidates','positions','leave_types'] loop
      execute format('select count(*) from public.%I where entity_id = %L', t, a) into v_n;
      perform pg_temp.ok(v_n = 0, v_sub || ' sees ' || v_n || ' Entity A rows in ' || t);
    end loop;
    foreach t in array array['leave_requests','leave_balances','payslips','employee_documents','timesheet_entries',
                             'employee_compensation','employee_change_requests'] loop
      execute format('select count(*) from public.%I x where x.employee_id in
                        (''a0000000-0000-4000-8000-000000000031'',''a0000000-0000-4000-8000-000000000032'',
                         ''a0000000-0000-4000-8000-000000000034'',''a0000000-0000-4000-8000-000000000035'')', t) into v_n;
      perform pg_temp.ok(v_n = 0, v_sub || ' sees ' || v_n || ' Entity A rows in ' || t);
    end loop;
    -- workflow tables are RPC-only (no table grant); check through the RPCs the UI uses
    select count(*) into v_n from public.get_workflow_rules(null, null) w where w.entity_id = a;
    perform pg_temp.ok(v_n = 0, v_sub || ' sees Entity A workflow rules');
    begin
      select count(*) into v_n from public.get_workflow_runs(null, 500, null) w where w.entity_id = a;
    exception when insufficient_privilege then v_n := 0;
    end;
    perform pg_temp.ok(v_n = 0, v_sub || ' sees Entity A workflow runs');
    begin  -- asking for Entity A explicitly must be denied or empty
      select count(*) into v_n from public.get_workflow_rules(null, a);
    exception when insufficient_privilege then v_n := 0;
    end;
    perform pg_temp.ok(v_n = 0, v_sub || ' get_workflow_rules(Entity A) denied/empty');
    select count(*) into v_n from public.entities where id = a;
    perform pg_temp.ok(v_n = 0, 'Entity A row hidden');
    v_code := pg_temp.expect_error($$select public.get_payroll_payslip('06d18772-7843-4fab-b305-cc49f9be5116')$$, 'B reads A payslip');
    perform pg_temp.ok(v_code in ('P0002','42501'), 'B cannot read Entity A payslip via RPC');
    v_code := pg_temp.expect_error($$select public.get_owner_dashboard_kpis('a0000000-0000-4000-8000-000000000001')$$, 'B KPIs for A');
    perform pg_temp.ok(v_code is not null, 'B cannot read Entity A KPIs');
  end loop;

  reset role;
  insert into e2e_results values ('J5 cross-entity: entityadmin.b / locationmanager.b see zero Entity A rows', true, 'ok');
exception when others then
  reset role;
  insert into e2e_results values ('J5 cross-entity: entityadmin.b / locationmanager.b see zero Entity A rows', false, sqlstate || ' ' || sqlerrm);
end $j$;

reset role;
select journey, pass, detail from e2e_results order by journey;
rollback;
