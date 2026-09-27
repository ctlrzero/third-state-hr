-- ============================================================
-- Smart Employee Onboarding — business workflow tests.
-- Creates a throw-away company, branch, managers and logins, runs the
-- whole lifecycle as each persona (PostgREST-style impersonation) and
-- ROLLS BACK. Nothing persists. Run as postgres AFTER migrations
-- 001–010 are applied (SQL editor / psql). The final statement raises
-- an exception whose message lists every result.
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
-- Read-anything helpers for assertions (run as definer = postgres).
create function pg_temp.q_int(p_sql text) returns bigint language plpgsql security definer as $f$
declare r bigint; begin execute p_sql into r; return r; end $f$;
create function pg_temp.q_text(p_sql text) returns text language plpgsql security definer as $f$
declare r text; begin execute p_sql into r; return r; end $f$;

-- ---------------------------------------------------------------- fixtures
set local session_replication_role = replica;
insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'onb.owner@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000002', 'onb.admin@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000003', 'onb.admin3@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000004', 'onb.lm@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000005', 'onb.payroll@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000006', 'onb.other@example.test', 'authenticated', 'authenticated');
insert into public.entities (id, name, default_currency) values
  ('c2000000-0000-4000-8000-000000000001', 'ONB Test Cafe', 'AED'),
  ('c2000000-0000-4000-8000-000000000002', 'ONB Other Co', 'AED');
insert into public.locations (id, entity_id, name) values
  ('c3000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', 'ONB Branch 1'),
  ('c3000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000001', 'ONB Branch 2'),
  ('c3000000-0000-4000-8000-000000000003', 'c2000000-0000-4000-8000-000000000002', 'ONB Other Branch');
insert into public.profiles (id, full_name, role, entity_id, location_id, is_active) values
  ('c1000000-0000-4000-8000-000000000001', 'ONB Owner', 'owner', null, null, true),
  ('c1000000-0000-4000-8000-000000000002', 'ONB Admin', 'entity_admin', 'c2000000-0000-4000-8000-000000000001', null, true),
  ('c1000000-0000-4000-8000-000000000003', 'ONB Admin 3', 'entity_admin', 'c2000000-0000-4000-8000-000000000001', null, true),
  ('c1000000-0000-4000-8000-000000000004', 'ONB Branch Mgr', 'location_manager', 'c2000000-0000-4000-8000-000000000001',
   'c3000000-0000-4000-8000-000000000001', true),
  ('c1000000-0000-4000-8000-000000000005', 'ONB Payroll', 'staff', 'c2000000-0000-4000-8000-000000000001', null, true),
  ('c1000000-0000-4000-8000-000000000006', 'ONB Other Admin', 'entity_admin', 'c2000000-0000-4000-8000-000000000002', null, true);
insert into public.payroll_permissions (user_id, entity_id, preset) values
  ('c1000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000001', 'payroll_admin');
insert into public.positions (id, entity_id, title, department) values
  ('c4000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', 'ONB Barista', 'Floor');
-- The reporting manager is an active employee linked to the LM login.
insert into public.employees (id, entity_id, home_location_id, position_id, auth_user_id, full_name, employment_status, join_date) values
  ('c5000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', 'c3000000-0000-4000-8000-000000000001',
   'c4000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000004', 'ONB Manager', 'active', '2024-01-01');
set local session_replication_role = origin;

-- ================================================================= tests
do $t$
declare
  v_owner uuid := 'c1000000-0000-4000-8000-000000000001';
  v_admin uuid := 'c1000000-0000-4000-8000-000000000002';
  v_admin3 uuid := 'c1000000-0000-4000-8000-000000000003';
  v_lm uuid := 'c1000000-0000-4000-8000-000000000004';
  v_pay uuid := 'c1000000-0000-4000-8000-000000000005';
  v_other uuid := 'c1000000-0000-4000-8000-000000000006';
  v_ent uuid := 'c2000000-0000-4000-8000-000000000001';
  v_l1 uuid := 'c3000000-0000-4000-8000-000000000001';
  v_pos uuid := 'c4000000-0000-4000-8000-000000000001';
  v_mgr uuid := 'c5000000-0000-4000-8000-000000000001';
  v_start date := (now() at time zone 'Asia/Dubai')::date + 10;
  j jsonb;
  v_inst uuid;
  v_emp uuid;
  v_task uuid;
  v_pd uuid;
  v_ver integer;
  v_pol record;
  v_period uuid;
begin
  -- ------------------------------------------------ A. setup and start
  perform pg_temp.login(v_admin);
  perform public.seed_default_onboarding_template(v_ent);
  perform pg_temp.ok('A1 default template seeded with 19 tasks',
    pg_temp.q_int(format('select count(*) from public.onboarding_template_tasks tt join public.onboarding_templates t on t.id = tt.template_id where t.entity_id = %L', v_ent)) = 19);

  j := public.start_onboarding_direct_hire(v_ent, 'ONB New Hire', 'onb.new@example.test', '+971 50 123 4567', 'female',
         v_l1, v_pos, 'full_time', v_start, v_mgr, 'Walk-in hire after trial shift');
  v_inst := (j ->> 'onboarding_instance_id')::uuid;
  v_emp := (j ->> 'employee_id')::uuid;
  perform pg_temp.put('inst', v_inst::text);
  perform pg_temp.put('emp', v_emp::text);
  perform pg_temp.ok('A2 direct hire creates pre-boarding employee + onboarding',
    pg_temp.q_text(format('select employment_status::text from public.employees where id = %L', v_emp)) = 'pre_boarding'
    and (j ->> 'task_count')::int = 13, j::text);
  perform pg_temp.ok('A3 employee number assigned',
    pg_temp.q_text(format('select employee_number from public.employees where id = %L', v_emp)) = 'EMP-0001');

  begin
    perform public.start_onboarding_direct_hire(v_ent, 'ONB Dup', 'ONB.NEW@example.test ', null, null, v_l1, v_pos, 'full_time',
      v_start, v_mgr, 'dup');
    perform pg_temp.ok('A4 duplicate email in same company refused', false);
  exception when others then
    perform pg_temp.ok('A4 duplicate email in same company refused', sqlstate = '23505', sqlerrm);
  end;

  begin
    perform public.update_onboarding_setup(v_inst, '{"proposed_start_date":"2030-01-01"}', 'x', -1);
    perform pg_temp.ok('A5 stale row_version refused', false);
  exception when others then
    perform pg_temp.ok('A5 stale row_version refused', sqlstate = '40001', sqlerrm);
  end;

  perform pg_temp.login(v_other);
  begin
    perform public.get_onboarding_workspace(v_inst);
    perform pg_temp.ok('A6 other company admin cannot open workspace', false);
  exception when others then
    perform pg_temp.ok('A6 other company admin cannot open workspace', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.ok('A7 other company admin sees no instance rows', (select count(*) from public.onboarding_instances) = 0);

  -- ------------------------------------------------ B. invitation and portal
  perform pg_temp.login(v_admin);
  j := public.issue_onboarding_invitation(v_inst);
  perform pg_temp.ok('B1 invitation issued, email to send', (j ->> 'send_email')::boolean, j::text);
  j := public.issue_onboarding_invitation(v_inst);
  perform pg_temp.ok('B2 issuing again is idempotent', (j ->> 'already_issued')::boolean, j::text);

  -- The new hire signs up (handle_new_user applies the pending grant).
  reset role;
  insert into auth.users (id, email, aud, role) values ('c1000000-0000-4000-8000-000000000009', 'onb.new@example.test', 'authenticated', 'authenticated');
  perform pg_temp.ok('B3 sign-up links login to the employee',
    pg_temp.q_text(format('select auth_user_id::text from public.employees where id = %L', v_emp)) = 'c1000000-0000-4000-8000-000000000009');

  perform pg_temp.login('c1000000-0000-4000-8000-000000000009');
  j := public.get_my_onboarding();
  perform pg_temp.ok('B4 employee portal loads', (j -> 'onboarding' ->> 'id')::uuid = v_inst, left(j::text, 300));
  perform pg_temp.ok('B5 portal has no pay data', j::text !~* 'basic_monthly|hourly_rate|proposed_salary');
  begin
    perform public.save_my_onboarding_profile('{"email":"x@y.z"}');
    perform pg_temp.ok('B6 employee cannot edit non-whitelisted fields', false);
  exception when others then
    perform pg_temp.ok('B6 employee cannot edit non-whitelisted fields', sqlstate = '22023', sqlerrm);
  end;
  perform public.save_my_onboarding_profile('{"phone":"+971501234567","dob":"1998-04-02","gender":"female","nationality":"Philippines",
    "residential_address":"Al Barsha, Dubai","emergency_contact_name":"Maria","emergency_contact_phone":"+639170000000"}');
  j := public.stage_my_onboarding_document('passport', 'pdf', (now() + interval '3 years')::date, null);
  perform pg_temp.ok('B7 pre-boarding employee can stage own document upload',
    j ->> 'storage_path' like v_ent::text || '/' || v_emp::text || '/%', j::text);
  begin
    perform public.stage_my_onboarding_document('contract', 'pdf', null, null);
    perform pg_temp.ok('B8 employee cannot upload the contract', false);
  exception when others then
    perform pg_temp.ok('B8 employee cannot upload the contract', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.ok('B9 pre-boarding employee reads own staged document row', (select count(*) from public.employee_documents) >= 1);

  select id into v_task from public.onboarding_tasks where instance_id = v_inst and item_key = 'operations_setup';
  begin
    perform public.complete_onboarding_task(v_task, null);
    perform pg_temp.ok('B10 employee cannot complete a branch-manager task', false);
  exception when others then
    perform pg_temp.ok('B10 employee cannot complete a branch-manager task', sqlstate = '42501', sqlerrm);
  end;
  begin
    perform public.save_my_payment_details('bank_transfer', 'ENBD', 'ONB New Hire', 'AE12 3456', null);
    perform pg_temp.ok('B11 malformed IBAN refused', false);
  exception when others then
    perform pg_temp.ok('B11 malformed IBAN refused', sqlstate = '22023', sqlerrm);
  end;
  perform public.save_my_payment_details('bank_transfer', 'ENBD', 'ONB New Hire', 'AE07 0331 2345 6789 0123 456', null);
  for v_pol in select p.id from public.onboarding_policies p where p.entity_id = v_ent and p.is_active loop
    perform public.acknowledge_onboarding_policy(v_pol.id);
  end loop;
  begin
    perform public.accept_employment_contract(v_inst);
    perform pg_temp.ok('B12 contract acceptance needs an approved contract', false);
  exception when others then
    perform pg_temp.ok('B12 contract acceptance needs an approved contract', sqlstate = '22023', sqlerrm);
  end;
  j := public.submit_onboarding_section(v_inst, 'profile');
  perform pg_temp.ok('B13 profile section submitted',
    pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and section = ''profile'' and status = ''submitted''', v_inst)) = 2);
  begin
    perform public.save_my_onboarding_profile('{"phone":"+971500000000"}');
    perform pg_temp.ok('B14 profile locked while under review', false);
  exception when others then
    perform pg_temp.ok('B14 profile locked while under review', sqlstate = '22023', sqlerrm);
  end;

  -- Key documents: approved passport/visa/Emirates ID and HR contract (fixture, as if reviewed).
  reset role;
  set local session_replication_role = replica;
  insert into public.employee_documents (employee_id, doc_type, storage_path, expiry_date, review_status, is_current, submitted_by, submitted_at,
    reviewed_by, reviewed_at, upload_confirmed, version_number)
  select v_emp, d::public.document_type, format('%s/%s/fixture-%s.pdf', v_ent, v_emp, d), (now() + interval '2 years')::date, 'approved', true,
         v_admin, now(), v_owner, now(), true, 1
    from unnest(array['passport', 'visa', 'emirates_id', 'contract']) d;
  set local session_replication_role = origin;

  perform pg_temp.login('c1000000-0000-4000-8000-000000000009');
  j := public.accept_employment_contract(v_inst);
  perform pg_temp.ok('B15 employee accepts the approved contract', (j ->> 'ok')::boolean and not (j ->> 'already_accepted')::boolean, j::text);
  j := public.accept_employment_contract(v_inst);
  perform pg_temp.ok('B16 contract acceptance is idempotent', (j ->> 'already_accepted')::boolean, j::text);
  perform pg_temp.ok('B17 employee sees own bank details only', (select count(*) from public.employee_payment_details) = 1);
  perform pg_temp.ok('B18 employee cannot read pending pay', (select count(*) from public.onboarding_pending_compensation) = 0);

  -- ------------------------------------------------ C. reviews, pay, bank
  perform pg_temp.login(v_admin);
  j := public.review_onboarding_section(v_inst, 'profile', 'changes_required', 'Emergency contact phone looks incomplete');
  perform pg_temp.ok('C1 HR requests changes with a reason',
    pg_temp.q_text(format('select status from public.onboarding_instances where id = %L', v_inst)) = 'changes_required');
  perform pg_temp.login('c1000000-0000-4000-8000-000000000009');
  perform public.save_my_onboarding_profile('{"emergency_contact_phone":"+639171234567"}');
  perform public.submit_onboarding_section(v_inst, 'profile');
  perform pg_temp.login(v_admin);
  perform public.review_onboarding_section(v_inst, 'profile', 'approved', null);
  perform pg_temp.ok('C2 resubmitted profile approved',
    pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and section = ''profile'' and status = ''approved''', v_inst)) = 2);

  j := public.set_onboarding_pending_compensation(v_inst, null, 'monthly', 4000, null, true, 'Starting pay', null);
  perform pg_temp.ok('C3 HR enters pay (pending review)', j ->> 'status' = 'pending_review', j::text);
  begin
    perform public.review_onboarding_compensation(v_inst, 'approved', null);
    perform pg_temp.ok('C4 pay maker cannot approve own entry', false);
  exception when others then
    perform pg_temp.ok('C4 pay maker cannot approve own entry', sqlstate = '42501', sqlerrm);
  end;

  perform pg_temp.login(v_lm);
  perform pg_temp.ok('C5 branch manager sees the onboarding', (select count(*) from public.onboarding_instances where id = v_inst) = 1);
  perform pg_temp.ok('C6 branch manager cannot read pay', (select count(*) from public.onboarding_pending_compensation) = 0);
  perform pg_temp.ok('C7 branch manager cannot read bank details', (select count(*) from public.employee_payment_details) = 0);
  j := public.get_onboarding_workspace(v_inst);
  perform pg_temp.ok('C8 branch manager workspace has no pay/bank', j -> 'compensation' = 'null'::jsonb or j -> 'compensation' is null,
    left((j -> 'compensation')::text, 100));
  select id into v_task from public.onboarding_tasks where instance_id = v_inst and item_key = 'operations_setup';
  j := public.complete_onboarding_task(v_task, '{"note":"Uniform size M ordered"}');
  perform pg_temp.ok('C9 branch manager completes operations task', j ->> 'status' = 'approved', j::text);

  perform pg_temp.login(v_pay);
  perform public.review_onboarding_compensation(v_inst, 'approved', null);
  select id into v_pd from public.employee_payment_details where employee_id = v_emp and status = 'submitted';
  perform public.verify_payment_details(v_pd, 'verified', null);
  perform pg_temp.ok('C10 payroll approves pay and verifies bank',
    pg_temp.q_text(format('select status from public.onboarding_pending_compensation where instance_id = %L', v_inst)) = 'approved'
    and pg_temp.q_text(format('select status from public.employee_payment_details where id = %L', v_pd)) = 'verified');

  perform pg_temp.login(v_admin);
  select id into v_task from public.onboarding_tasks where instance_id = v_inst and item_key = 'passport';
  begin
    perform public.waive_onboarding_task(v_task, 'n/a');
    perform pg_temp.ok('C11 statutory document cannot be waived', false);
  exception when others then
    perform pg_temp.ok('C11 statutory document cannot be waived', sqlstate = '22023', sqlerrm);
  end;
  j := public.calculate_onboarding_readiness(v_inst);
  perform pg_temp.ok('C12 readiness: ready for activation', (j ->> 'ready')::boolean
    and pg_temp.q_text(format('select status from public.onboarding_instances where id = %L', v_inst)) = 'ready_for_activation', j::text);
  j := public.onboarding_dashboard_summary(v_ent);
  perform pg_temp.ok('C13 dashboard summary counts ready', (j ->> 'ready_for_activation')::int = 1, j::text);

  -- ------------------------------------------------ D. activation
  begin
    perform public.set_employee_status(v_emp, 'active', 'raw');
    perform pg_temp.ok('D1 raw activation blocked (010 guard)', false);
  exception when others then
    perform pg_temp.ok('D1 raw activation blocked (010 guard)', sqlstate = '42501', sqlerrm);
  end;
  v_ver := pg_temp.q_int(format('select row_version from public.onboarding_instances where id = %L', v_inst));
  begin
    perform public.approve_and_activate_employee(v_inst, v_ver, 'Go');
    perform pg_temp.ok('D2 pay maker cannot also activate', false);
  exception when others then
    perform pg_temp.ok('D2 pay maker cannot also activate', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.login(v_admin3);
  begin
    perform public.approve_and_activate_employee(v_inst, v_ver - 1, 'Go');
    perform pg_temp.ok('D3 stale version refused at activation', false);
  exception when others then
    perform pg_temp.ok('D3 stale version refused at activation', sqlstate = '40001', sqlerrm);
  end;
  j := public.approve_and_activate_employee(v_inst, v_ver, 'All checks complete');
  perform pg_temp.ok('D4 second admin activates', (j ->> 'ok')::boolean and not (j ->> 'already_activated')::boolean, j::text);
  j := public.approve_and_activate_employee(v_inst, v_ver, 'retry');
  perform pg_temp.ok('D5 activation retry is idempotent', (j ->> 'already_activated')::boolean, j::text);
  perform pg_temp.ok('D6 employee active with join date',
    pg_temp.q_text(format('select employment_status::text || join_date::text from public.employees where id = %L', v_emp)) = 'active' || v_start::text);
  perform pg_temp.ok('D7 first compensation version created',
    pg_temp.q_int(format('select count(*) from public.compensation_versions where employee_id = %L and basic_monthly = 4000 and effective_from = %L', v_emp, v_start)) = 1);
  perform pg_temp.ok('D8 probation ≤ 6 months created',
    pg_temp.q_text(format('select end_date::text from public.employee_probation_periods where employee_id = %L and status = ''active''', v_emp))
      = ((v_start + interval '6 months')::date - 1)::text);
  perform pg_temp.ok('D9 day-one and first-month tasks generated',
    pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and phase <> ''pre_activation''', v_inst)) = 6);
  perform pg_temp.ok('D10 activation audited with operation id',
    pg_temp.q_int(format('select count(*) from public.audit_log where action = ''employee_activated'' and record_id = %L and new_value ? ''operation_id''', v_emp)) = 1);
  perform pg_temp.ok('D11 employee notified once',
    pg_temp.q_int(format('select count(*) from public.notifications where employee_id = %L and notification_type = ''onboarding_activated''', v_emp)) = 1);

  -- ------------------------------------------------ E. day one and probation
  perform pg_temp.login(v_lm);
  perform public.record_day_one_outcome(v_inst, 'started', null, null);
  for v_task in select id from public.onboarding_tasks where instance_id = v_inst and phase = 'day_one' and owner_role = 'location_manager' loop
    perform public.complete_onboarding_task(v_task, null);
  end loop;
  perform pg_temp.ok('E1 food safety SOP task completed from the earlier acknowledgement',
    pg_temp.q_text(format('select status from public.onboarding_tasks where instance_id = %L and item_key = ''food_safety_ack''', v_inst)) = 'approved');
  perform pg_temp.ok('E2 day one done → in progress',
    pg_temp.q_text(format('select status from public.onboarding_instances where id = %L', v_inst)) = 'in_progress',
    pg_temp.q_text(format('select string_agg(item_key || '':'' || status, '','') from public.onboarding_tasks where instance_id = %L and phase = ''day_one''', v_inst)));

  perform pg_temp.login(v_admin);
  begin
    perform public.close_onboarding(v_inst, null);
    perform pg_temp.ok('E3 cannot close with open follow-ups', false);
  exception when others then
    perform pg_temp.ok('E3 cannot close with open follow-ups', sqlstate = '22023', sqlerrm);
  end;

  select id into v_period from public.employee_probation_periods where employee_id = v_emp and status = 'active';
  perform pg_temp.login(v_lm);
  perform public.record_probation_review(v_period, 'confirm', 'Reliable, learns fast', '{"punctuality":5}');
  begin
    perform public.decide_probation_outcome(v_period, 'confirmed', null, null, null);
    perform pg_temp.ok('E4 branch manager cannot decide probation', false);
  exception when others then
    perform pg_temp.ok('E4 branch manager cannot decide probation', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.login(v_admin);
  begin
    perform public.decide_probation_outcome(v_period, 'extended', null, (v_start + interval '7 months')::date, 'More time');
    perform pg_temp.ok('E5 extension beyond six months refused', false);
  exception when others then
    perform pg_temp.ok('E5 extension beyond six months refused', sqlstate = '22023', sqlerrm);
  end;
  j := public.onboarding_report(v_ent, 'time_to_activate');
  perform pg_temp.ok('E6 time-to-activate report', (j -> 'data' ->> 'activated')::int = 1, j::text);

  perform pg_temp.ok('E7 workflow catalog lists onboarding events', public.workflow_trigger_catalog() -> 'onboarding' ? 'employee_activated');
  begin
    perform public.onboarding_send_reminders();
    perform pg_temp.ok('E8 reminder job refuses API callers', false);
  exception when others then
    perform pg_temp.ok('E8 reminder job refuses API callers', sqlstate = '42501', sqlerrm);
  end;

  -- ------------------------------------------------ F. withdrawal path
  j := public.start_onboarding_direct_hire(v_ent, 'ONB Second Hire', 'onb.second@example.test', null, null, v_l1, v_pos, 'part_time',
         v_start, v_mgr, 'Referral');
  v_inst := (j ->> 'onboarding_instance_id')::uuid;
  perform public.withdraw_onboarding(v_inst, 'Accepted another job');
  perform pg_temp.ok('F1 withdrawal keeps record, inactivates, cancels tasks',
    pg_temp.q_text(format('select employment_status::text from public.employees where id = %L', (j ->> 'employee_id'))) = 'inactive'
    and pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and status <> ''cancelled''', v_inst)) = 0);
end $t$;

reset role;
do $$ begin
  raise exception 'ONBOARDING_TESTS % passed / % total || FAILED: % || ALL: %',
    (select count(*) from t_results where pass), (select count(*) from t_results),
    coalesce((select string_agg(name || ' [' || coalesce(detail, '') || ']', ' ;; ' order by n) from t_results where not pass), 'none'),
    (select string_agg(n || '.' || name, ' | ' order by n) from t_results);
end $$;
rollback;
