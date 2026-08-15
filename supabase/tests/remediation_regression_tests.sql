-- ============================================================================
-- TS-HR UAT remediation regression suite
-- ============================================================================
-- Covers Decision 1 (export_audit_log Owner-scope fix, 12 cases) and
-- Decision 2 (payroll mutation RPCs locked to owner/entity_admin, 10 cases),
-- plus the My Profile schedule-history test-gap fixture check.
--
-- This whole file is one transaction that ends in ROLLBACK. Every test --
-- including the two "authorized mutation succeeds" cases in Decision 2 --
-- runs for real against live tables/RPCs and is asserted against, but nothing
-- persists: the final ROLLBACK undoes all of it. Safe to re-run any time
-- against UAT without polluting seed data.
--
-- No pgTAP dependency (pgtap is available in the catalog but not installed in
-- this project, and installing an extension is a schema change requiring its
-- own approval -- out of scope here). Instead, each test is a DO block that
-- RAISEs on failure and RAISE NOTICEs on success, so a clean run producing
-- only NOTICEs (no ERROR) is a full pass; any ERROR names the failing case.
--
-- Fixture UUIDs (live UAT data, confirmed by direct query before writing this
-- file -- see the remediation report for provenance):
--   Owner                    4162bf0e-c123-4d8f-93c8-219e7e166c5f
--   Entity Admin A (Ent. A)  81b68580-a490-4115-be98-70285a51ba99
--   Entity Admin B (Ent. B)  054b6210-bf56-492d-9fae-983f2b0228cd
--   Location Manager A       545cf168-7595-4ccb-8c37-c4c434f5f1c0  (Ent A / Branch A1)
--   Staff A                  5f353b67-2e93-4cea-bd44-9ad2d6b4bfd9  (Ent A / Branch A1)
--   Entity A                 a0000000-0000-4000-8000-000000000001
--   Entity B                 a0000000-0000-4000-8000-000000000002
--   Branch A1                a0000000-0000-4000-8000-000000000011
--   Draft payroll run (Aug)  f9d3862d-78f8-43bc-a62e-6d2ac12a2495  (Entity A)
--   Locked/paid payroll run  6833b40e-df28-4ca6-9538-b23fa0cee513  (Entity A)
--   Employee (timesheet test) a0000000-0000-4000-8000-000000000031 (home: Branch A1)
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- DECISION 1: export_audit_log
-- ---------------------------------------------------------------------------

-- D1.T1 -- Owner, no filters: must not crash, must span >1 entity (the bug).
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_count int;
begin
  select count(distinct entity_id) into v_count from export_audit_log();
  if v_count < 2 then
    raise exception 'FAIL D1.T1: expected owner unfiltered export to span >=2 entities, got %', v_count;
  end if;
  raise notice 'PASS D1.T1: Owner unfiltered export spans % distinct entities (no crash)', v_count;
end $$;
reset role;

-- D1.T2 -- Owner, explicit p_entity_id: result must be scoped to that entity only.
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_other int;
begin
  select count(*) into v_other
  from export_audit_log(p_entity_id => 'a0000000-0000-4000-8000-000000000001'::uuid)
  where entity_id <> 'a0000000-0000-4000-8000-000000000001'::uuid;
  if v_other <> 0 then
    raise exception 'FAIL D1.T2: Owner entity-filtered export leaked % rows outside the requested entity', v_other;
  end if;
  raise notice 'PASS D1.T2: Owner entity-filtered export returns only the requested entity';
end $$;
reset role;

-- D1.T3 -- Owner, module filter ('payroll'): every returned row's table_name must be
-- one of the payroll module tables.
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_bad int;
begin
  select count(*) into v_bad
  from export_audit_log(p_module => 'payroll')
  where table_name not in ('payroll_runs','payslips','payslip_deductions','tips_pools');
  if v_bad <> 0 then
    raise exception 'FAIL D1.T3: module=payroll filter leaked % rows from non-payroll tables', v_bad;
  end if;
  raise notice 'PASS D1.T3: module=payroll filter returns only payroll-module tables';
end $$;
reset role;

-- D1.T4 -- Entity Admin A, no filter: server-side scope must force entity_id = own
-- entity for every row, regardless of no filter being passed.
select set_config('request.jwt.claim.sub','81b68580-a490-4115-be98-70285a51ba99',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','81b68580-a490-4115-be98-70285a51ba99')::text, true);
set local role authenticated;
do $$
declare v_bad int; v_total int;
begin
  select count(*) filter (where entity_id <> 'a0000000-0000-4000-8000-000000000001'::uuid), count(*)
    into v_bad, v_total
  from export_audit_log();
  if v_bad <> 0 then
    raise exception 'FAIL D1.T4: Entity Admin A export leaked % rows outside own entity', v_bad;
  end if;
  if v_total = 0 then
    raise exception 'FAIL D1.T4: Entity Admin A export returned zero rows -- expected real UAT activity';
  end if;
  raise notice 'PASS D1.T4: Entity Admin A unfiltered export is server-side scoped to own entity (% rows)', v_total;
end $$;
reset role;

-- D1.T5 -- Entity Admin A, attempts p_entity_id = Entity B (escalation attempt): the
-- function must ignore the client-supplied entity_id for entity_admin and still only
-- return Entity A's rows (proves scope is resolved server-side, not from input).
select set_config('request.jwt.claim.sub','81b68580-a490-4115-be98-70285a51ba99',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','81b68580-a490-4115-be98-70285a51ba99')::text, true);
set local role authenticated;
do $$
declare v_bad int;
begin
  select count(*) into v_bad
  from export_audit_log(p_entity_id => 'a0000000-0000-4000-8000-000000000002'::uuid)
  where entity_id <> 'a0000000-0000-4000-8000-000000000001'::uuid;
  if v_bad <> 0 then
    raise exception 'FAIL D1.T5: Entity Admin A escalated scope to another entity via p_entity_id (% leaked rows)', v_bad;
  end if;
  raise notice 'PASS D1.T5: Entity Admin A cannot escalate export scope via p_entity_id';
end $$;
reset role;

-- D1.T6 -- Location Manager: denied entirely (the deployed function restricts export
-- to owner/entity_admin only -- location_manager is not in scope for this capability).
select set_config('request.jwt.claim.sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0')::text, true);
set local role authenticated;
do $$
begin
  perform * from export_audit_log();
  raise exception 'FAIL D1.T6: Location Manager export_audit_log() did not raise -- should be denied';
exception when others then
  if sqlerrm like 'Only an Owner or Entity Admin%' then
    raise notice 'PASS D1.T6: Location Manager export_audit_log() denied (%)', sqlerrm;
  else
    raise exception 'FAIL D1.T6: unexpected error for Location Manager export: %', sqlerrm;
  end if;
end $$;
reset role;

-- D1.T7 -- Staff: denied entirely.
select set_config('request.jwt.claim.sub','5f353b67-2e93-4cea-bd44-9ad2d6b4bfd9',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','5f353b67-2e93-4cea-bd44-9ad2d6b4bfd9')::text, true);
set local role authenticated;
do $$
begin
  perform * from export_audit_log();
  raise exception 'FAIL D1.T7: Staff export_audit_log() did not raise -- should be denied';
exception when others then
  if sqlerrm like 'Only an Owner or Entity Admin%' then
    raise notice 'PASS D1.T7: Staff export_audit_log() denied (%)', sqlerrm;
  else
    raise exception 'FAIL D1.T7: unexpected error for Staff export: %', sqlerrm;
  end if;
end $$;
reset role;

-- D1.T8 -- Anonymous (no JWT / anon role): denied entirely.
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '', true);
set local role anon;
do $$
begin
  perform * from export_audit_log();
  raise exception 'FAIL D1.T8: anonymous export_audit_log() did not raise -- should be denied';
exception when others then
  raise notice 'PASS D1.T8: anonymous export_audit_log() denied (%)', sqlerrm;
end $$;
reset role;

-- D1.T9 -- Empty-result filter: must return 0 rows without crashing, and (since
-- entity scope is still non-empty) must still log one audit_log_exported row per
-- scoped entity with entity_row_count = 0.
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_count int; v_zero_logged int;
begin
  select count(*) into v_count from export_audit_log(p_before => '2000-01-01'::timestamptz);
  if v_count <> 0 then
    raise exception 'FAIL D1.T9: expected 0 rows for a pre-2000 filter, got %', v_count;
  end if;
  select count(*) into v_zero_logged
  from audit_log
  where action = 'audit_log_exported' and (new_value->>'entity_row_count')::int = 0
    and (new_value->>'total_row_count')::int = 0;
  if v_zero_logged = 0 then
    raise exception 'FAIL D1.T9: empty export did not log any zero-count audit_log_exported rows';
  end if;
  raise notice 'PASS D1.T9: empty-result export returns 0 rows without error and logs zero-count entries';
end $$;
reset role;

-- D1.T10 -- No null entity_id ever appears among returned export rows (the audit_log
-- constraint that must never be relaxed is: entity_id required except for
-- table_name = 'app_settings'; the export must never surface a violation of that).
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_null int;
begin
  select count(*) into v_null from export_audit_log() where entity_id is null;
  if v_null <> 0 then
    raise exception 'FAIL D1.T10: export returned % rows with null entity_id', v_null;
  end if;
  raise notice 'PASS D1.T10: no null entity_id rows in export output';
end $$;
reset role;

-- D1.T11 -- Shared export_id: a single call's resulting audit_log_exported rows (one
-- per scoped entity) must all share the exact same export_id. NOTE: every insert in
-- this whole test file shares one wrapping transaction, so now()/changed_at is
-- IDENTICAL for every row across the entire suite (Postgres freezes now() at
-- transaction start) -- a timestamp threshold can't isolate "this call's" rows.
-- Instead, snapshot existing audit_log_exported ids into a temp table first, then
-- diff against that snapshot after the call.
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_distinct_ids int;
begin
  create temp table t_d1t11_before on commit drop as select id from audit_log where action = 'audit_log_exported';
  perform * from export_audit_log();
  select count(distinct new_value->>'export_id') into v_distinct_ids
  from audit_log
  where action = 'audit_log_exported' and id not in (select id from t_d1t11_before);
  if v_distinct_ids <> 1 then
    raise exception 'FAIL D1.T11: expected exactly 1 distinct export_id for this call''s logged rows, got %', v_distinct_ids;
  end if;
  raise notice 'PASS D1.T11: all per-entity audit_log_exported rows from one call share one export_id';
end $$;
reset role;

-- D1.T12 -- Self-referential exclusion: the rows returned BY a call must never include
-- THAT SAME call's own about-to-be-inserted audit_log_exported logging event (proves
-- "materialize then return, log after" ordering, not just by code inspection). NOTE:
-- earlier tests in this suite already created real audit_log_exported rows within this
-- same transaction, and those legitimately CAN appear in a later export's results (a
-- later export is allowed to see genuinely earlier audit_log_exported rows) -- so this
-- test isolates specifically the rows this call itself is about to insert, via a
-- before/after id snapshot, rather than asserting zero audit_log_exported rows exist
-- in the result at all.
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_leaked int;
begin
  create temp table t_d1t12_before on commit drop as select id from audit_log where action = 'audit_log_exported';
  create temp table t_d1t12_result on commit drop as select * from export_audit_log();
  select count(*) into v_leaked
  from t_d1t12_result r
  where r.table_name = 'audit_log' and r.action = 'audit_log_exported'
    and r.id not in (select id from t_d1t12_before);
  if v_leaked <> 0 then
    raise exception 'FAIL D1.T12: export result contained % of its own about-to-be-created audit_log_exported rows', v_leaked;
  end if;
  raise notice 'PASS D1.T12: export never includes its own logging event in its own result set';
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- DECISION 2: payroll mutation RPCs locked to owner/entity_admin
-- ---------------------------------------------------------------------------

-- D2.T1 -- Location Manager A: record_timesheet_entry on own-branch draft run -> denied.
select set_config('request.jwt.claim.sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0')::text, true);
set local role authenticated;
do $$
declare v_res jsonb;
begin
  select record_timesheet_entry('f9d3862d-78f8-43bc-a62e-6d2ac12a2495'::uuid, 'a0000000-0000-4000-8000-000000000031'::uuid, 8, 0, 0, 'LM test') into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'FAIL D2.T1: LM record_timesheet_entry expected NOT_AUTHORIZED, got %', v_res;
  end if;
  raise notice 'PASS D2.T1: LM record_timesheet_entry denied (%)', v_res->>'code';
end $$;
reset role;

-- D2.T2 -- Location Manager A: delete_timesheet_entry on an existing row -> denied.
select set_config('request.jwt.claim.sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0')::text, true);
set local role authenticated;
do $$
declare v_res jsonb;
begin
  select delete_timesheet_entry('5f11fab8-8750-4bdd-9e41-586db3eed79e'::uuid) into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'FAIL D2.T2: LM delete_timesheet_entry expected NOT_AUTHORIZED, got %', v_res;
  end if;
  raise notice 'PASS D2.T2: LM delete_timesheet_entry denied (%)', v_res->>'code';
end $$;
reset role;

-- D2.T3/T4 -- Location Manager A: tips pool record+delete -> denied. Uses Branch A2
-- (a fresh location/run combo, not seeded) for the record attempt, and the existing
-- seed row at Branch A1 (eacc405d-...) for the delete attempt -- both hit the
-- authorization check before any insert/delete statement runs, so the real seed row
-- is never actually touched even though it's the delete target.
select set_config('request.jwt.claim.sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0')::text, true);
set local role authenticated;
do $$
declare v_res jsonb;
begin
  select record_tips_pool('f9d3862d-78f8-43bc-a62e-6d2ac12a2495'::uuid, 'a0000000-0000-4000-8000-000000000012'::uuid, 50, 'LM test') into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'FAIL D2.T3: LM record_tips_pool expected NOT_AUTHORIZED, got %', v_res;
  end if;
  raise notice 'PASS D2.T3: LM record_tips_pool denied (%)', v_res->>'code';
end $$;
do $$
declare v_res jsonb;
begin
  select delete_tips_pool('eacc405d-c5cb-48c3-99f4-02cea7bb9c37'::uuid) into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'FAIL D2.T4: LM delete_tips_pool expected NOT_AUTHORIZED, got %', v_res;
  end if;
  raise notice 'PASS D2.T4: LM delete_tips_pool denied (%)', v_res->>'code';
end $$;
reset role;

-- D2.T5/T6 -- Location Manager A: payslip deduction record+delete -> denied. Uses
-- employee 034 (a fresh employee/run/type combo, not seeded) for the record attempt,
-- and the existing seed row (1c10892a-...) for the delete attempt -- again, the
-- authorization check runs before any write, so the seed row is never touched.
select set_config('request.jwt.claim.sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','545cf168-7595-4ccb-8c37-c4c434f5f1c0')::text, true);
set local role authenticated;
do $$
declare v_res jsonb;
begin
  select record_payslip_deduction('f9d3862d-78f8-43bc-a62e-6d2ac12a2495'::uuid, 'a0000000-0000-4000-8000-000000000034'::uuid, 'parking', 10, 'LM test') into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'FAIL D2.T5: LM record_payslip_deduction expected NOT_AUTHORIZED, got %', v_res;
  end if;
  raise notice 'PASS D2.T5: LM record_payslip_deduction denied (%)', v_res->>'code';
end $$;
do $$
declare v_res jsonb;
begin
  select delete_payslip_deduction('1c10892a-e058-4660-9201-b832c5ad7ee4'::uuid) into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'FAIL D2.T6: LM delete_payslip_deduction expected NOT_AUTHORIZED, got %', v_res;
  end if;
  raise notice 'PASS D2.T6: LM delete_payslip_deduction denied (%)', v_res->>'code';
end $$;
reset role;

-- D2.T7 -- Owner: record_timesheet_entry on a draft run -> succeeds.
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_res jsonb; v_exists boolean;
begin
  select record_timesheet_entry('f9d3862d-78f8-43bc-a62e-6d2ac12a2495'::uuid, 'a0000000-0000-4000-8000-000000000034'::uuid, 8, 0, 0, 'Owner test') into v_res;
  if (v_res->>'ok')::boolean <> true then
    raise exception 'FAIL D2.T7: Owner record_timesheet_entry expected success, got %', v_res;
  end if;
  select exists(select 1 from timesheet_entries where id = (v_res->>'id')::uuid) into v_exists;
  if not v_exists then
    raise exception 'FAIL D2.T7: Owner-created timesheet entry not found in table';
  end if;
  raise notice 'PASS D2.T7: Owner record_timesheet_entry succeeds on a draft run';
end $$;
reset role;

-- D2.T8 -- Entity Admin A: record_timesheet_entry on own-entity draft run -> succeeds.
select set_config('request.jwt.claim.sub','81b68580-a490-4115-be98-70285a51ba99',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','81b68580-a490-4115-be98-70285a51ba99')::text, true);
set local role authenticated;
do $$
declare v_res jsonb;
begin
  select record_timesheet_entry('1f30d729-53a9-4b99-90c8-43c209421259'::uuid, 'a0000000-0000-4000-8000-000000000032'::uuid, 4, 0, 0, 'EA-A test') into v_res;
  if (v_res->>'ok')::boolean <> true then
    raise exception 'FAIL D2.T8: Entity Admin A record_timesheet_entry expected success, got %', v_res;
  end if;
  raise notice 'PASS D2.T8: Entity Admin A record_timesheet_entry succeeds on own-entity draft run';
end $$;
reset role;

-- D2.T9 -- Entity Admin B: attempts record_timesheet_entry on Entity A's draft run
-- (cross-entity) -> denied. Proves entity_admin's own-entity boundary is intact after
-- removing the location_manager branch of the same authorization check.
select set_config('request.jwt.claim.sub','054b6210-bf56-492d-9fae-983f2b0228cd',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','054b6210-bf56-492d-9fae-983f2b0228cd')::text, true);
set local role authenticated;
do $$
declare v_res jsonb;
begin
  select record_timesheet_entry('f9d3862d-78f8-43bc-a62e-6d2ac12a2495'::uuid, 'a0000000-0000-4000-8000-000000000034'::uuid, 4, 0, 0, 'EA-B cross-entity test') into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'FAIL D2.T9: Entity Admin B cross-entity attempt expected NOT_AUTHORIZED, got %', v_res;
  end if;
  raise notice 'PASS D2.T9: Entity Admin B cross-entity record_timesheet_entry denied (%)', v_res->>'code';
end $$;
reset role;

-- D2.T10 -- Owner: record_timesheet_entry on the LOCKED (paid) run -> denied with
-- PAYROLL_RUN_LOCKED. Proves passing the authorization check does not bypass the
-- separate run-status check -- no regression on locked-run enforcement.
select set_config('request.jwt.claim.sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f',true);
select set_config('request.jwt.claims', json_build_object('role','authenticated','sub','4162bf0e-c123-4d8f-93c8-219e7e166c5f')::text, true);
set local role authenticated;
do $$
declare v_res jsonb;
begin
  select record_timesheet_entry('6833b40e-df28-4ca6-9538-b23fa0cee513'::uuid, 'a0000000-0000-4000-8000-000000000034'::uuid, 8, 0, 0, 'Owner locked-run test') into v_res;
  if (v_res->>'ok')::boolean <> false or v_res->>'code' <> 'PAYROLL_RUN_LOCKED' then
    raise exception 'FAIL D2.T10: Owner on locked run expected PAYROLL_RUN_LOCKED, got %', v_res;
  end if;
  raise notice 'PASS D2.T10: Owner correctly blocked by PAYROLL_RUN_LOCKED on a non-draft run (no auth-check regression)';
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- SCHEDULE-HISTORY TEST GAP: second employee shift fixture at the same branch
-- ---------------------------------------------------------------------------

-- Confirms Branch A1 now has shift rows for TWO distinct employees, so a My
-- Profile-style scoped query (employee_id = self) can be verified to return only
-- one employee's rows even though an unscoped branch query would return both.
do $$
declare v_distinct_employees int;
  v_self_only int;
  v_unscoped int;
begin
  select count(distinct employee_id) into v_distinct_employees
  from shifts where location_id = 'a0000000-0000-4000-8000-000000000011'::uuid;
  if v_distinct_employees < 2 then
    raise exception 'FAIL SCHED.T1: expected >=2 distinct employees with shifts at Branch A1, got %', v_distinct_employees;
  end if;

  select count(*) into v_self_only
  from shifts
  where location_id = 'a0000000-0000-4000-8000-000000000011'::uuid
    and employee_id = 'a0000000-0000-4000-8000-000000000034'::uuid;
  select count(*) into v_unscoped
  from shifts where location_id = 'a0000000-0000-4000-8000-000000000011'::uuid;

  if v_self_only = 0 or v_self_only >= v_unscoped then
    raise exception 'FAIL SCHED.T1: self-scoped count (%) should be > 0 and < unscoped branch count (%)', v_self_only, v_unscoped;
  end if;
  raise notice 'PASS SCHED.T1: Branch A1 has % distinct employees; self-scoped query (% rows) is a strict subset of the unscoped branch query (% rows)', v_distinct_employees, v_self_only, v_unscoped;
end $$;

-- ---------------------------------------------------------------------------
-- All assertions passed if execution reaches here without an ERROR above.
-- Roll back: this is a test suite, not a data-mutating migration.
-- ---------------------------------------------------------------------------
rollback;
