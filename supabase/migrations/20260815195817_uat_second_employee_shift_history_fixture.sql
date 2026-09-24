-- UAT fixture addition: the D4 regression pass found the "My Profile
-- schedule history" scoping test inconclusive -- only one employee (UAT
-- Employee A) had past shift history at Branch A1, so an unfiltered query
-- and a properly-filtered one returned the same rows and couldn't prove
-- the explicit employee_id filter in MyProfile.tsx is load-bearing.
--
-- This adds PAST (before today) shifts at Branch A1 for a second employee
-- record already at that branch -- UAT Location Manager A's own employees
-- row (id a0000000-0000-4000-8000-000000000034), which has home_location_id
-- = Branch A1. No new auth user or profile needed; this employee record
-- already exists from the original seed migration.
--
-- Idempotent: guarded by an `if not exists` on the fixture's own shift ids.

do $fixture$
declare
  v_loc_a1        uuid := 'a0000000-0000-4000-8000-000000000011';
  v_pos_locmgr_a  uuid := 'a0000000-0000-4000-8000-000000000023';
  v_emp_locmgr_a  uuid := 'a0000000-0000-4000-8000-000000000034';
  v_entity_a      uuid := 'a0000000-0000-4000-8000-000000000001';
  v_shift_1       uuid := 'a0000000-0000-4000-8000-000000000051';
  v_shift_2       uuid := 'a0000000-0000-4000-8000-000000000052';
begin
  if not exists (select 1 from shifts where id = v_shift_1) then
    insert into shifts (id, entity_id, location_id, position_id, employee_id, shift_date, start_time, end_time, status, is_published)
    values
      (v_shift_1, v_entity_a, v_loc_a1, v_pos_locmgr_a, v_emp_locmgr_a, current_date - 2, '09:00', '17:00', 'completed', true),
      (v_shift_2, v_entity_a, v_loc_a1, v_pos_locmgr_a, v_emp_locmgr_a, current_date - 1, '09:00', '17:00', 'completed', true)
    on conflict (id) do nothing;
  else
    raise notice 'UAT fixture: second-employee shift history at Branch A1 already exists -- skipping.';
  end if;
end;
$fixture$;
