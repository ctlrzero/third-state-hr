-- ============================================================================
-- UAT SYNTHETIC SEED DATA — Third State HR
-- ============================================================================
-- Forward-only migration. NOT part of the 99-migration recovered baseline and
-- NOT related to 20260815210000_storage_bucket_limits.sql. Contains ONLY
-- synthetic, unmistakably-named UAT fixture data ("UAT Entity A", "UAT
-- Branch A1", "UAT Employee A", etc.) so it can never be confused with real
-- tenant data and can be safely identified/purged later with:
--   delete from entities where name like 'UAT Entity %';   -- cascades down
--
-- PREREQUISITE — READ BEFORE APPLYING:
-- This migration does NOT and MUST NOT create any auth.users rows (no
-- password hashing, no `insert into auth.users`, nothing). It assumes the
-- following 8 auth users already exist, created manually beforehand via the
-- Supabase Dashboard (Authentication > Users > Add user), with these exact
-- email addresses (a non-deliverable domain, safe for UAT):
--   1. uat.owner@example.com            -- Owner
--   2. uat.entityadmin.a@example.com    -- Entity Admin, Entity A
--   3. uat.entityadmin.b@example.com    -- Entity Admin, Entity B
--   4. uat.locationmanager.a@example.com-- Location Manager, Branch A1
--                                          (also the assigned interviewer)
--   5. uat.locationmanager.b@example.com-- Location Manager, Branch B1
--   6. uat.employee.a@example.com       -- Employee, Branch A1
--   7. uat.employee.b@example.com       -- Employee, Branch A2 (Entity A)
--   8. uat.employee.c@example.com       -- Employee, Entity B / Branch B1
--
-- This migration resolves each one's id via
--   `select id from auth.users where email = '<address>'`
-- and RAISES AN EXCEPTION naming any missing address, rather than silently
-- doing nothing, if any of the 8 do not exist yet.
--
-- The instant each of those 8 auth.users rows was created, the existing
-- `handle_new_user` trigger (see 20260730192237_employee_onboarding_foundation.sql)
-- already fired and INSERTed a default `profiles` row for it (role='staff',
-- entity_id/location_id both null). This migration therefore only ever
-- UPDATEs those 7 non-default profiles (owner, 2 entity admins, 2 location
-- managers... the 3 employee personas keep role='staff' but still get
-- entity_id/location_id set here for consistency) — it never INSERTs into
-- profiles.
--
-- `employees` rows are a SEPARATE HR record from `profiles`, with their own
-- nullable `auth_user_id` FK to auth.users. Only the 3 actual "Employee"
-- personas (6/7/8) *need* an employees row to exercise self-service RPCs
-- (my_employee_id()). Location Manager A additionally gets an employees row
-- because several recruiting RPCs (get_my_interviews / get_interview_detail
-- / save_interview_feedback_draft) independently require
-- is_active_employee(my_employee_id()) to be true for the calling user, even
-- when that user's role is location_manager, not staff — Location Manager A
-- is the assigned interviewer in the sample application below, so this is
-- required for that scenario to work, not optional embellishment.
--
-- IDENTITY IMPERSONATION IDIOM
-- The recovered 99-migration history was searched (grep -rn "set_config|
-- request.jwt" across every file) for this project's own established
-- pattern for impersonating a specific auth user inside a verification/seed
-- transaction. NONE WAS FOUND — no migration in the recovered baseline ever
-- calls set_config('request.jwt...', ...) or otherwise impersonates a JWT
-- identity. This migration therefore uses the standard Supabase local/CI
-- testing fallback idiom exactly as instructed, wrapping every RPC call that
-- internally derives its actor via auth.uid()/my_role()/my_employee_id():
--
--   set local role authenticated;
--   select set_config('request.jwt.claim.sub', '<uuid>', true);
--   select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','<uuid>')::text, true);
--   <call the RPC>
--   reset role;
--
-- (Translated below to plpgsql PERFORM form inside one DO block, since
-- plpgsql variables carry the actor ids and generated fixture ids across the
-- whole seed rather than re-querying repeatedly.)
--
-- IDEMPOTENCY
-- Every entity/location/position/leave_type/employee row uses a fixed,
-- hardcoded UUID with `on conflict (id) do nothing`, so re-running this file
-- is a safe no-op for those tables. Every RPC-driven side effect (schedule
-- templates, generated/published shifts, attendance clock-in, payroll runs
-- and their child rows, document uploads, recruiting rows, the change
-- request) is wrapped in its own `if not exists (...)` guard keyed on the
-- unmistakable UAT fixture ids/names, so reapplying this migration will
-- never create duplicates.
-- ============================================================================

begin;

do $migration$
declare
  -- ---- resolved auth.users ids (must pre-exist; see header) --------------
  v_owner_id             uuid;
  v_entityadmin_a_id     uuid;
  v_entityadmin_b_id     uuid;
  v_locmgr_a_id          uuid;
  v_locmgr_b_id          uuid;
  v_employee_a_id        uuid;
  v_employee_b_id        uuid;
  v_employee_c_id        uuid;

  -- ---- fixed fixture ids (deterministic, for idempotent on-conflict) -----
  v_entity_a             uuid := 'a0000000-0000-4000-8000-000000000001';
  v_entity_b             uuid := 'a0000000-0000-4000-8000-000000000002';
  v_loc_a1               uuid := 'a0000000-0000-4000-8000-000000000011';
  v_loc_a2               uuid := 'a0000000-0000-4000-8000-000000000012';
  v_loc_b1               uuid := 'a0000000-0000-4000-8000-000000000013';
  v_pos_barista_a        uuid := 'a0000000-0000-4000-8000-000000000021';
  v_pos_shiftlead_a      uuid := 'a0000000-0000-4000-8000-000000000022';
  v_pos_locmgr_a         uuid := 'a0000000-0000-4000-8000-000000000023';
  v_pos_tea_b            uuid := 'a0000000-0000-4000-8000-000000000024';
  v_pos_locmgr_b         uuid := 'a0000000-0000-4000-8000-000000000025';
  v_emp_a                uuid := 'a0000000-0000-4000-8000-000000000031';
  v_emp_b                uuid := 'a0000000-0000-4000-8000-000000000032';
  v_emp_c                uuid := 'a0000000-0000-4000-8000-000000000033';
  v_emp_locmgr_a         uuid := 'a0000000-0000-4000-8000-000000000034';
  v_leave_annual_a       uuid := 'a0000000-0000-4000-8000-000000000041';
  v_leave_sick_a         uuid := 'a0000000-0000-4000-8000-000000000042';
  v_leave_annual_b       uuid := 'a0000000-0000-4000-8000-000000000043';
  v_requisition          uuid := 'a0000000-0000-4000-8000-000000000081';
  v_candidate            uuid := 'a0000000-0000-4000-8000-000000000082';
  v_application           uuid := 'a0000000-0000-4000-8000-000000000083';
  v_stage                uuid := 'a0000000-0000-4000-8000-000000000084';
  v_interview             uuid := 'a0000000-0000-4000-8000-000000000085';
  v_change_request        uuid := 'a0000000-0000-4000-8000-000000000091';

  -- ---- computed at run time ----------------------------------------------
  v_dow                  smallint;
  v_dow2                 smallint;
  v_dow3                 smallint;
  v_week_start           date;
  v_week_end             date;
  v_period_cur_start     date;
  v_period_cur_end       date;
  v_period_prev_start    date;
  v_period_prev_end      date;
  v_payroll_current      uuid;
  v_payroll_prior        uuid;
  v_doc_result           jsonb;
  v_current_labor_doc_id uuid;
begin
  -- ==========================================================================
  -- 0. Resolve and validate the 8 prerequisite auth.users
  -- ==========================================================================
  select id into v_owner_id         from auth.users where email = 'uat.owner@example.com';
  select id into v_entityadmin_a_id from auth.users where email = 'uat.entityadmin.a@example.com';
  select id into v_entityadmin_b_id from auth.users where email = 'uat.entityadmin.b@example.com';
  select id into v_locmgr_a_id      from auth.users where email = 'uat.locationmanager.a@example.com';
  select id into v_locmgr_b_id      from auth.users where email = 'uat.locationmanager.b@example.com';
  select id into v_employee_a_id    from auth.users where email = 'uat.employee.a@example.com';
  select id into v_employee_b_id    from auth.users where email = 'uat.employee.b@example.com';
  select id into v_employee_c_id    from auth.users where email = 'uat.employee.c@example.com';

  if v_owner_id is null then raise exception 'UAT seed: auth.users row for uat.owner@example.com not found -- create it in the Supabase Dashboard first'; end if;
  if v_entityadmin_a_id is null then raise exception 'UAT seed: auth.users row for uat.entityadmin.a@example.com not found'; end if;
  if v_entityadmin_b_id is null then raise exception 'UAT seed: auth.users row for uat.entityadmin.b@example.com not found'; end if;
  if v_locmgr_a_id is null then raise exception 'UAT seed: auth.users row for uat.locationmanager.a@example.com not found'; end if;
  if v_locmgr_b_id is null then raise exception 'UAT seed: auth.users row for uat.locationmanager.b@example.com not found'; end if;
  if v_employee_a_id is null then raise exception 'UAT seed: auth.users row for uat.employee.a@example.com not found'; end if;
  if v_employee_b_id is null then raise exception 'UAT seed: auth.users row for uat.employee.b@example.com not found'; end if;
  if v_employee_c_id is null then raise exception 'UAT seed: auth.users row for uat.employee.c@example.com not found'; end if;

  -- ==========================================================================
  -- 1. Entities, locations, positions (fixed ids -> idempotent via on conflict)
  -- ==========================================================================
  insert into entities (id, name, trade_license_no, emirate, default_currency)
  values (v_entity_a, 'UAT Entity A', 'UAT-TL-0001', 'Dubai', 'AED')
  on conflict (id) do nothing;

  insert into entities (id, name, trade_license_no, emirate, default_currency)
  values (v_entity_b, 'UAT Entity B', 'UAT-TL-0002', 'Sharjah', 'AED')
  on conflict (id) do nothing;

  insert into locations (id, entity_id, name, address) values
    (v_loc_a1, v_entity_a, 'UAT Branch A1', 'UAT fixture address, Branch A1'),
    (v_loc_a2, v_entity_a, 'UAT Branch A2', 'UAT fixture address, Branch A2'),
    (v_loc_b1, v_entity_b, 'UAT Branch B1', 'UAT fixture address, Branch B1')
  on conflict (id) do nothing;

  insert into positions (id, entity_id, title, department) values
    (v_pos_barista_a,   v_entity_a, 'UAT Barista',           'Front of House'),
    (v_pos_shiftlead_a, v_entity_a, 'UAT Shift Lead',        'Front of House'),
    (v_pos_locmgr_a,    v_entity_a, 'UAT Location Manager',  'Management'),
    (v_pos_tea_b,       v_entity_b, 'UAT Tea Specialist',    'Front of House'),
    (v_pos_locmgr_b,    v_entity_b, 'UAT Location Manager',  'Management')
  on conflict (id) do nothing;

  -- ==========================================================================
  -- 2. Profiles — UPDATE ONLY (rows already exist via handle_new_user trigger)
  -- ==========================================================================
  -- Bootstrap problem: trg_enforce_profile_role_change_authority (see
  -- 20260731001428_fix_profiles_privilege_escalation.sql) only allows an
  -- existing 'owner' (or in-entity entity_admin) to change role/entity_id/
  -- location_id on a profile -- but no UAT owner profile exists yet the
  -- first time this migration runs. This mirrors the documented manual
  -- bootstrap ("promote the first account to 'owner' manually") and is
  -- temporarily disabled only for the width of these 8 UPDATEs.
  alter table public.profiles disable trigger trg_enforce_profile_role_change_authority;

  update profiles set full_name = 'UAT Owner', role = 'owner', entity_id = null, location_id = null
    where id = v_owner_id;

  update profiles set full_name = 'UAT Entity Admin A', role = 'entity_admin', entity_id = v_entity_a, location_id = null
    where id = v_entityadmin_a_id;

  update profiles set full_name = 'UAT Entity Admin B', role = 'entity_admin', entity_id = v_entity_b, location_id = null
    where id = v_entityadmin_b_id;

  update profiles set full_name = 'UAT Location Manager A', role = 'location_manager', entity_id = v_entity_a, location_id = v_loc_a1
    where id = v_locmgr_a_id;

  update profiles set full_name = 'UAT Location Manager B', role = 'location_manager', entity_id = v_entity_b, location_id = v_loc_b1
    where id = v_locmgr_b_id;

  -- Employee personas keep the trigger's default role='staff' but still get
  -- entity_id/location_id set for consistency (per task instructions).
  update profiles set full_name = 'UAT Employee A', role = 'staff', entity_id = v_entity_a, location_id = v_loc_a1
    where id = v_employee_a_id;

  update profiles set full_name = 'UAT Employee B', role = 'staff', entity_id = v_entity_a, location_id = v_loc_a2
    where id = v_employee_b_id;

  update profiles set full_name = 'UAT Employee C', role = 'staff', entity_id = v_entity_b, location_id = v_loc_b1
    where id = v_employee_c_id;

  alter table public.profiles enable trigger trg_enforce_profile_role_change_authority;

  -- ==========================================================================
  -- 3. Leave types (per entity) -- leave_balances auto-seed via existing
  --    trg_seed_leave_balances_employee / trg_seed_leave_balances_type
  --    triggers, so long as leave_types exist BEFORE the employees below
  --    are inserted.
  -- ==========================================================================
  insert into leave_types (id, entity_id, name, accrual_days_per_year, requires_approval) values
    (v_leave_annual_a, v_entity_a, 'Annual Leave', 21, true),
    (v_leave_sick_a,   v_entity_a, 'Sick Leave',   10, true),
    (v_leave_annual_b, v_entity_b, 'Annual Leave', 21, true)
  on conflict (id) do nothing;

  -- ==========================================================================
  -- 4. Employees (only the personas that need a self-service HR record;
  --    auth_user_id populated since these are self-service test personas).
  --    Insert triggers fire (onboarding checklist, availability, leave
  --    balances, employee_compensation) exactly as they would for real hires.
  -- ==========================================================================
  insert into employees (
    id, entity_id, home_location_id, position_id, auth_user_id,
    full_name, email, employment_type, employment_status, join_date
  ) values
    (v_emp_a, v_entity_a, v_loc_a1, v_pos_barista_a, v_employee_a_id,
     'UAT Employee A', 'uat.employee.a@example.com', 'full_time', 'active', (current_date - interval '180 days')::date),
    (v_emp_b, v_entity_a, v_loc_a2, v_pos_barista_a, v_employee_b_id,
     'UAT Employee B', 'uat.employee.b@example.com', 'full_time', 'active', (current_date - interval '150 days')::date),
    (v_emp_c, v_entity_b, v_loc_b1, v_pos_tea_b, v_employee_c_id,
     'UAT Employee C', 'uat.employee.c@example.com', 'full_time', 'active', (current_date - interval '120 days')::date),
    (v_emp_locmgr_a, v_entity_a, v_loc_a1, v_pos_locmgr_a, v_locmgr_a_id,
     'UAT Location Manager A', 'uat.locationmanager.a@example.com', 'full_time', 'active', (current_date - interval '365 days')::date)
  on conflict (id) do nothing;

  -- Give Employee A / B an actual hourly pay rate so the payroll section
  -- below produces non-zero figures (trg_seed_employee_compensation seeds a
  -- row with pay_rate = null by default). Not RPC-gated -- employee_compensation
  -- uses plain RLS ("comp_access"), unlike the payroll_runs child tables.
  update employee_compensation set pay_rate = 35.00, pay_type = 'hourly'
    where employee_id in (v_emp_a, v_emp_b) and pay_rate is null;

  -- ==========================================================================
  -- 5. Recurring shift template (Branch A1) + generated/published shifts for
  --    the current week + a sample clock-in/out against the published shift.
  --    Guarded as ONE block: reapplying this migration in a later week will
  --    NOT regenerate/duplicate shifts -- it leaves the first run's week
  --    alone rather than accumulating a new set of shifts every time.
  -- ==========================================================================
  if not exists (
    select 1 from schedule_templates where employee_id = v_emp_a and location_id = v_loc_a1 and is_active
  ) then
    v_dow  := extract(dow from current_date)::smallint;         -- guarantees a same-day match for clock_in() below
    v_dow2 := ((v_dow + 2) % 7)::smallint;
    v_dow3 := ((v_dow + 4) % 7)::smallint;
    v_week_start := date_trunc('week', current_date)::date;
    v_week_end   := v_week_start + 6;

    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_owner_id)::text, true);
    set local role authenticated;

    -- Three recurring weekly slots, each with a 30-minute break.
    perform public.create_schedule_template(v_loc_a1, v_emp_a, v_pos_barista_a, v_dow,  '09:00'::time, '17:00'::time, 30, (current_date - interval '60 days')::date, null);
    perform public.create_schedule_template(v_loc_a1, v_emp_a, v_pos_barista_a, v_dow2, '09:00'::time, '17:00'::time, 30, (current_date - interval '60 days')::date, null);
    perform public.create_schedule_template(v_loc_a1, v_emp_a, v_pos_barista_a, v_dow3, '12:00'::time, '20:00'::time, 30, (current_date - interval '60 days')::date, null);

    perform public.generate_shifts_from_templates(v_loc_a1, v_week_start, v_week_end);
    perform public.publish_schedule_period(v_loc_a1, v_week_start, v_week_end);

    reset role;

    -- Sample attendance: Employee A clocks in and out against today's
    -- published shift (clock_in() best-effort matches today's published,
    -- non-cancelled shift for the caller -- guaranteed to exist because one
    -- of the three templates above was created for today's day-of-week).
    if not exists (
      select 1 from attendance_records where employee_id = v_emp_a and clock_in_at::date = current_date
    ) then
      perform set_config('request.jwt.claim.sub', v_employee_a_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_employee_a_id)::text, true);
      set local role authenticated;

      perform public.clock_in();
      perform public.clock_out();

      reset role;
    end if;
  else
    raise notice 'UAT seed: schedule templates for Employee A / Branch A1 already exist -- skipping shift generation/publish/clock-in to avoid duplicates.';
  end if;

  -- ==========================================================================
  -- 6. Payroll -- current draft run (Entity A) + a prior approved/paid run.
  --    payroll_runs itself is plain-RLS (owner/entity_admin insert), NOT
  --    RPC-gated -- only its children (timesheet_entries, tips_pools,
  --    payslip_deductions) and payslips are RPC-walled per
  --    20260814165449_payroll_rpc_mutation_layer.sql and
  --    20260731001542_gate_payroll_calculation_and_prevent_overwrite.sql.
  --    So the run row itself is a plain insert; every child row goes
  --    through record_timesheet_entry / record_tips_pool /
  --    record_payslip_deduction, and payslips are only ever produced by
  --    run_payroll_calculation().
  -- ==========================================================================
  v_period_cur_start  := date_trunc('month', current_date)::date;
  v_period_cur_end    := (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date;
  v_period_prev_start := (date_trunc('month', current_date) - interval '1 month')::date;
  v_period_prev_end   := (date_trunc('month', current_date) - interval '1 day')::date;

  -- --- 6a. Current period: draft run --------------------------------------
  if not exists (
    select 1 from payroll_runs where entity_id = v_entity_a and period_start = v_period_cur_start and period_end = v_period_cur_end
  ) then
    insert into payroll_runs (entity_id, period_start, period_end, status, tip_distribution_rule, created_by)
    values (v_entity_a, v_period_cur_start, v_period_cur_end, 'draft', 'equal', v_owner_id)
    returning id into v_payroll_current;

    perform set_config('request.jwt.claim.sub', v_entityadmin_a_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_entityadmin_a_id)::text, true);
    set local role authenticated;

    perform public.record_timesheet_entry(v_payroll_current, v_emp_a, 176, 4, 0, 'UAT seed: sample regular + overtime hours');
    perform public.record_timesheet_entry(v_payroll_current, v_emp_b, 160, 0, 0, 'UAT seed: sample regular hours');

    perform public.record_tips_pool(v_payroll_current, v_loc_a1, 1200.00, 'UAT seed: sample tip entry for Branch A1');

    -- A deduction ...
    perform public.record_payslip_deduction(v_payroll_current, v_emp_a, 'uniform', 75.00, 'UAT seed: sample deduction (uniform cost)');
    -- ... and a synthetic "allowance". NOTE: this schema has no distinct
    -- allowance/earning-credit table or deduction_type value -- payslip
    -- math is `net_pay = base + overtime + holiday + tips_share - total_deductions`,
    -- so a UAT allowance is modeled as a NEGATIVE payslip_deductions row
    -- (deduction_type='other'), which nets out as a credit to net_pay. This
    -- is a deliberate workaround, not a schema feature -- flagged here and in
    -- the migration report so it isn't mistaken for a real allowance mechanism.
    perform public.record_payslip_deduction(v_payroll_current, v_emp_a, 'other', -100.00, 'UAT seed: sample allowance (modeled as a negative deduction -- schema has no distinct allowance concept)');

    reset role;

    -- Explicit owner review/approval of overtime + tips distribution before
    -- calculating, matching BR-PAY-006/D05 (see gate migration) -- direct
    -- UPDATE is fine here, these two flags live on payroll_runs itself,
    -- which is not RPC-gated.
    update payroll_runs set overtime_holiday_pay_confirmed = true, tips_distribution_confirmed = true
      where id = v_payroll_current;

    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_owner_id)::text, true);
    set local role authenticated;

    perform public.run_payroll_calculation(v_payroll_current);

    reset role;

    -- Resulting payslip for Employee A is automatically visible to them via
    -- the existing payslips_select_self RLS policy (employee_id =
    -- my_employee_id()) -- no extra step needed for "a synthetic payslip
    -- visible to one employee".
  else
    raise notice 'UAT seed: current-period payroll run for UAT Entity A already exists -- skipping.';
  end if;

  -- --- 6b. Prior period: approved/paid run (for revision-testing) ---------
  if not exists (
    select 1 from payroll_runs where entity_id = v_entity_a and period_start = v_period_prev_start and period_end = v_period_prev_end
  ) then
    insert into payroll_runs (entity_id, period_start, period_end, status, tip_distribution_rule, created_by)
    values (v_entity_a, v_period_prev_start, v_period_prev_end, 'draft', 'equal', v_owner_id)
    returning id into v_payroll_prior;

    perform set_config('request.jwt.claim.sub', v_entityadmin_a_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_entityadmin_a_id)::text, true);
    set local role authenticated;

    perform public.record_timesheet_entry(v_payroll_prior, v_emp_a, 160, 0, 0, 'UAT seed: prior-period hours');

    reset role;

    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_owner_id)::text, true);
    set local role authenticated;

    perform public.run_payroll_calculation(v_payroll_prior);

    reset role;

    -- No RPC exists for the draft -> in_review -> approved -> paid status
    -- walk (only payroll_runs' own plain-RLS UPDATE policy governs it; the
    -- trg_prevent_payroll_run_status_regression trigger only blocks moving
    -- BACKWARD from approved/paid to draft/in_review, so this forward jump
    -- is unrestricted) -- marking it paid, for revision-testing later via
    -- create_payroll_revision().
    update payroll_runs
      set status = 'paid', approved_by = v_owner_id, approved_at = now()
      where id = v_payroll_prior;
  else
    raise notice 'UAT seed: prior-period payroll run for UAT Entity A already exists -- skipping.';
  end if;

  -- ==========================================================================
  -- 7. Documents -- via the actual upload RPC (create_document_upload), not
  --    raw inserts. NOTE ON RPC CHOICE: this project actually has TWO upload
  --    entry points -- the original create_document_upload(employee_id,
  --    doc_type, storage_path, ...) which takes a caller-supplied
  --    storage_path directly, and the newer stage_document_upload() /
  --    confirm_document_upload() pair which derives its own server-side path
  --    and requires confirm_document_upload() to find a REAL row in
  --    storage.objects before the document is treated as uploaded. Since we
  --    cannot and must not upload real file bytes from a SQL migration,
  --    stage_document_upload()'s confirm step would simply fail forever
  --    (UPLOAD_NOT_FOUND). create_document_upload() is therefore the correct
  --    RPC for metadata-only UAT fixtures: it accepts an explicit,
  --    obviously-fake storage_path string and (for owner-submitted or
  --    self-approval-enabled entity_admin uploads) sets upload_confirmed to
  --    its column default of `true` without ever touching storage.objects.
  --    NO REAL FILE EXISTS AT ANY OF THE storage_path VALUES BELOW -- they
  --    are metadata-only placeholders for UAT UI testing (list/detail/expiry
  --    views), not real documents. Any attempt to actually download one
  --    through the UI will correctly fail/404, which is expected.
  -- ==========================================================================

  -- 7a. Visa, expiring within 30 days -- uploaded AND approved by Owner in one
  --     step (create_document_upload immediate-approves for role='owner').
  if not exists (
    select 1 from employee_documents where employee_id = v_emp_a and doc_type = 'visa'::document_type and is_current = true
  ) then
    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_owner_id)::text, true);
    set local role authenticated;

    select public.create_document_upload(
      v_emp_a, 'visa'::document_type, 'uat-fixtures/placeholder-visa-employee-a.pdf',
      current_date + 20, 'UAT seed: metadata-only placeholder, no real file at this path. Expires within 30 days (T-30 alert test).'
    ) into v_doc_result;

    reset role;
  end if;

  -- 7b. Labor card, already expired -- uploaded AND approved by Owner.
  if not exists (
    select 1 from employee_documents where employee_id = v_emp_a and doc_type = 'labor_card'::document_type and is_current = true
  ) then
    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_owner_id)::text, true);
    set local role authenticated;

    select public.create_document_upload(
      v_emp_a, 'labor_card'::document_type, 'uat-fixtures/placeholder-labor-card-v1-employee-a.pdf',
      current_date - 15, 'UAT seed: metadata-only placeholder, no real file at this path. Already expired.'
    ) into v_doc_result;

    reset role;
  end if;

  -- 7c. Labor card RENEWAL, submitted by Entity Admin A (not Owner, so it
  --     does NOT immediate-approve) -- create_document_upload auto-detects
  --     the existing current/approved labor_card above and sets
  --     supersedes_document_id accordingly, landing as review_status =
  --     'pending_review'. This is the "renewal pending review" fixture.
  select id into v_current_labor_doc_id
    from employee_documents
    where employee_id = v_emp_a and doc_type = 'labor_card'::document_type and is_current = true;

  if v_current_labor_doc_id is not null and not exists (
    select 1 from employee_documents
    where employee_id = v_emp_a and doc_type = 'labor_card'::document_type
      and review_status = 'pending_review' and supersedes_document_id = v_current_labor_doc_id
  ) then
    perform set_config('request.jwt.claim.sub', v_entityadmin_a_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_entityadmin_a_id)::text, true);
    set local role authenticated;

    select public.create_document_upload(
      v_emp_a, 'labor_card'::document_type, 'uat-fixtures/placeholder-labor-card-v2-renewal-employee-a.pdf',
      current_date + 300, 'UAT seed: metadata-only placeholder, no real file at this path. Renewal awaiting review.'
    ) into v_doc_result;

    reset role;
  end if;

  -- ==========================================================================
  -- 8. Recruiting: one candidate, one requisition/application, one interview
  --    round scheduled, with DRAFT (unsubmitted) feedback only -- exercises
  --    the reveal-gating logic (is_interview_round_revealed /
  --    is_interview_within_visibility_window) from Phase 3.12, which must
  --    keep this feedback hidden from location_manager reviewers until
  --    either every interviewer in the round submits, or a Recruiting
  --    Admin/Owner explicitly closes the round. Neither happens here on
  --    purpose.
  -- ==========================================================================
  if not exists (select 1 from candidates where entity_id = v_entity_a and full_name = 'UAT Candidate Farah Test') then
    insert into job_requisitions (id, entity_id, location_id, position_id, headcount, status, created_by, opened_by, opened_at)
    values (v_requisition, v_entity_a, v_loc_a1, v_pos_barista_a, 1, 'open', v_entityadmin_a_id, v_entityadmin_a_id, now())
    on conflict (id) do nothing;

    insert into candidates (id, entity_id, location_id, full_name, contact_email, contact_phone, source, status, created_by)
    values (v_candidate, v_entity_a, v_loc_a1, 'UAT Candidate Farah Test', 'uat.candidate.farah@example.com', '+971500000000', 'online', 'interviewing', v_entityadmin_a_id)
    on conflict (id) do nothing;

    insert into job_applications (id, requisition_id, candidate_id, stage)
    values (v_application, v_requisition, v_candidate, 'interviewing')
    on conflict (id) do nothing;

    insert into interview_stages (id, requisition_id, sequence, name, guide)
    values (v_stage, v_requisition, 1, 'UAT Phone Screen', 'UAT seed: sample interview guide text for the phone screen stage.')
    on conflict (id) do nothing;

    insert into interviews (id, application_id, stage_id, scheduled_at, interviewer_id, format, meeting_location, outcome)
    values (v_interview, v_application, v_stage, now() - interval '2 hours', v_locmgr_a_id, 'video', 'UAT seed: Google Meet link placeholder', 'pending')
    on conflict (id) do nothing;

    -- DRAFT feedback only -- save_interview_feedback_draft(), never
    -- submit_interview_feedback(), so reveal stays gated.
    perform set_config('request.jwt.claim.sub', v_locmgr_a_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_locmgr_a_id)::text, true);
    set local role authenticated;

    perform public.save_interview_feedback_draft(
      v_interview, 'yes', jsonb_build_object('communication', 4, 'reliability', 4),
      'UAT seed: sample strengths text', 'UAT seed: sample concerns text',
      'UAT seed: draft-only feedback, intentionally never submitted (reveal-gating test).'
    );

    reset role;
  else
    raise notice 'UAT seed: recruiting fixture (UAT Candidate Farah Test) already exists -- skipping.';
  end if;

  -- ==========================================================================
  -- 9. Workflow/approval mechanism example: employee_change_requests
  --    (BR-ESS-005 self-service contact-detail change, held for manager/
  --    admin approval). Left PENDING on purpose, so UAT can exercise the
  --    approve/reject UI via decide_employee_change_request() live rather
  --    than starting from an already-decided state.
  -- ==========================================================================
  insert into employee_change_requests (id, employee_id, field_name, old_value, new_value, reason, status)
  select v_change_request, v_emp_a, 'phone', null, '+971509999999', 'UAT seed: sample self-service phone number change request', 'pending'
  where not exists (select 1 from employee_change_requests where id = v_change_request);

  raise notice 'UAT synthetic seed data migration complete.';
end;
$migration$;

commit;
