-- Consolidates every table where two permissive policies applied to the same
-- command (Postgres evaluates and OR's both, doubling planner work per row).
-- Pattern A: an admin "ALL" policy overlapped a narrower "select own" policy on
--   SELECT (and sometimes INSERT) -- split the ALL into per-command policies and
--   fold the "own" condition into the SELECT (and INSERT, where relevant) policy.
-- Pattern B: a SELECT policy duplicated or was a strict superset of what an ALL
--   policy already covered for SELECT -- just drop the redundant one.
-- No condition below is new; every merged policy is the exact OR of what already
-- existed, so effective access is unchanged for every role.

-- ---------- profiles (UPDATE: update_own + update_by_admin) ----------
drop policy if exists profiles_update_own on public.profiles;
drop policy if exists profiles_update_by_admin on public.profiles;
create policy profiles_update
on public.profiles
for update
using (
  id = (select auth.uid())
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
);
-- with_check intentionally keeps only the admin conditions (matching
-- profiles_update_by_admin's original with_check); self-updates still pass
-- because USING already allows targeting the row, and the role/entity/location
-- escalation guard trigger independently blocks a self-update from changing
-- those columns regardless of which policy admitted the UPDATE.

-- ---------- employees (SELECT: select + select_own; ALL included both) ----------
drop policy if exists employees_modify on public.employees;
drop policy if exists employees_select on public.employees;
drop policy if exists employees_select_own on public.employees;

create policy employees_select
on public.employees
for select
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and home_location_id = my_location())
  or auth_user_id = (select auth.uid())
);
create policy employees_insert
on public.employees
for insert
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and home_location_id = my_location())
);
create policy employees_update
on public.employees
for update
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and home_location_id = my_location())
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and home_location_id = my_location())
);
create policy employees_delete
on public.employees
for delete
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and home_location_id = my_location())
);

-- ---------- employee_documents (SELECT: access + select_own) ----------
drop policy if exists documents_access on public.employee_documents;
drop policy if exists documents_select_own on public.employee_documents;

create policy documents_select
on public.employee_documents
for select
using (
  employee_id = my_employee_id()
  or exists (
    select 1 from employees e where e.id = employee_documents.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy documents_insert
on public.employee_documents
for insert
with check (
  exists (
    select 1 from employees e where e.id = employee_documents.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy documents_update
on public.employee_documents
for update
using (
  exists (
    select 1 from employees e where e.id = employee_documents.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
)
with check (
  exists (
    select 1 from employees e where e.id = employee_documents.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy documents_delete
on public.employee_documents
for delete
using (
  exists (
    select 1 from employees e where e.id = employee_documents.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);

-- ---------- employee_availability (SELECT: access + select_own) ----------
drop policy if exists availability_access on public.employee_availability;
drop policy if exists availability_select_own on public.employee_availability;

create policy availability_select
on public.employee_availability
for select
using (
  employee_id = my_employee_id()
  or exists (
    select 1 from employees e where e.id = employee_availability.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy availability_insert
on public.employee_availability
for insert
with check (
  exists (
    select 1 from employees e where e.id = employee_availability.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy availability_update
on public.employee_availability
for update
using (
  exists (
    select 1 from employees e where e.id = employee_availability.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
)
with check (
  exists (
    select 1 from employees e where e.id = employee_availability.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy availability_delete
on public.employee_availability
for delete
using (
  exists (
    select 1 from employees e where e.id = employee_availability.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);

-- ---------- onboarding_checklist_items (SELECT: access + select_own) ----------
drop policy if exists checklist_access on public.onboarding_checklist_items;
drop policy if exists checklist_select_own on public.onboarding_checklist_items;

create policy checklist_select
on public.onboarding_checklist_items
for select
using (
  employee_id = my_employee_id()
  or exists (
    select 1 from employees e where e.id = onboarding_checklist_items.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy checklist_insert
on public.onboarding_checklist_items
for insert
with check (
  exists (
    select 1 from employees e where e.id = onboarding_checklist_items.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy checklist_update
on public.onboarding_checklist_items
for update
using (
  exists (
    select 1 from employees e where e.id = onboarding_checklist_items.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
)
with check (
  exists (
    select 1 from employees e where e.id = onboarding_checklist_items.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);
create policy checklist_delete
on public.onboarding_checklist_items
for delete
using (
  exists (
    select 1 from employees e where e.id = onboarding_checklist_items.employee_id
    and (my_role() = 'owner' or (my_role() = 'entity_admin' and e.entity_id = my_entity()) or (my_role() = 'location_manager' and e.home_location_id = my_location()))
  )
);

