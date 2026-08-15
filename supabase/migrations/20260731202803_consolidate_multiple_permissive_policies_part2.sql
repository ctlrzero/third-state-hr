-- ---------- leave_requests (SELECT: access+select_own; INSERT: access+insert_own) ----------
drop policy if exists leave_requests_access on public.leave_requests;
drop policy if exists leave_requests_insert_own on public.leave_requests;
drop policy if exists leave_requests_select_own on public.leave_requests;

create policy leave_requests_select
on public.leave_requests
for select
using (
  employee_id = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.home_location_id = my_location()))
);
create policy leave_requests_insert
on public.leave_requests
for insert
with check (
  (employee_id = my_employee_id() and status = 'pending' and decided_by is null and decided_at is null)
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.home_location_id = my_location()))
);
create policy leave_requests_update
on public.leave_requests
for update
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.home_location_id = my_location()))
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.home_location_id = my_location()))
);
create policy leave_requests_delete
on public.leave_requests
for delete
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.home_location_id = my_location()))
);

-- ---------- shift_swap_requests (ALL + ALL overlapped on every command) ----------
drop policy if exists swaps_access on public.shift_swap_requests;
drop policy if exists swaps_self_service on public.shift_swap_requests;

create policy swaps_select
on public.shift_swap_requests
for select
using (
  requested_by = my_employee_id()
  or claimed_by = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
);
create policy swaps_insert
on public.shift_swap_requests
for insert
with check (
  (requested_by = my_employee_id() and status = 'open' and resolved_by is null)
  or claimed_by = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
);
create policy swaps_update
on public.shift_swap_requests
for update
using (
  requested_by = my_employee_id()
  or claimed_by = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
)
with check (
  (requested_by = my_employee_id() and status = 'open' and resolved_by is null)
  or claimed_by = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
);
create policy swaps_delete
on public.shift_swap_requests
for delete
using (
  requested_by = my_employee_id()
  or claimed_by = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
);

-- ---------- employee_change_requests (SELECT: select_own+decide; INSERT: insert_own+decide) ----------
drop policy if exists change_requests_decide on public.employee_change_requests;
drop policy if exists change_requests_insert_own on public.employee_change_requests;
drop policy if exists change_requests_select_own on public.employee_change_requests;

create policy change_requests_select
on public.employee_change_requests
for select
using (
  employee_id = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.home_location_id = my_location()))
);
create policy change_requests_insert
on public.employee_change_requests
for insert
with check (
  (employee_id = my_employee_id() and status = 'pending' and decided_by is null and decided_at is null)
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.home_location_id = my_location()))
);
create policy change_requests_update
on public.employee_change_requests
for update
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.home_location_id = my_location()))
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.home_location_id = my_location()))
);
create policy change_requests_delete
on public.employee_change_requests
for delete
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = employee_change_requests.employee_id and e.home_location_id = my_location()))
);

-- ---------- timesheet_entries (SELECT: modify + select[duplicate] + select_own) ----------
drop policy if exists timesheet_modify on public.timesheet_entries;
drop policy if exists timesheet_select on public.timesheet_entries;
drop policy if exists timesheet_select_own on public.timesheet_entries;

create policy timesheet_select
on public.timesheet_entries
for select
using (
  employee_id = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
);
create policy timesheet_insert
on public.timesheet_entries
for insert
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
);
create policy timesheet_update
on public.timesheet_entries
for update
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
);
create policy timesheet_delete
on public.timesheet_entries
for delete
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
);

-- ---------- locations / positions (ALL's implicit SELECT duplicated a broader, already-correct SELECT policy) ----------
drop policy if exists locations_modify on public.locations;
create policy locations_insert on public.locations for insert
with check (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()));
create policy locations_update on public.locations for update
using (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()))
with check (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()));
create policy locations_delete on public.locations for delete
using (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()));

drop policy if exists positions_modify on public.positions;
create policy positions_insert on public.positions for insert
with check (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()));
create policy positions_update on public.positions for update
using (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()))
with check (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()));
create policy positions_delete on public.positions for delete
using (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()));

-- ---------- tips_pools / job_requisitions (SELECT duplicated the ALL policy's identical condition) ----------
drop policy if exists tips_select on public.tips_pools;
drop policy if exists requisitions_select on public.job_requisitions;

