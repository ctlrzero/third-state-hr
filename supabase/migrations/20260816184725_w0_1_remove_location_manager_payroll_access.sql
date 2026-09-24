drop policy if exists timesheet_select on public.timesheet_entries;
create policy timesheet_select on public.timesheet_entries
for select
using (
  employee_id = my_employee_id()
  or my_role() = 'owner'::user_role
  or (
    my_role() = 'entity_admin'::user_role
    and exists (
      select 1 from payroll_runs pr
      where pr.id = timesheet_entries.payroll_run_id
        and pr.entity_id = my_entity()
    )
  )
);

drop policy if exists timesheet_insert on public.timesheet_entries;
create policy timesheet_insert on public.timesheet_entries
for insert
with check (
  my_role() = 'owner'::user_role
  or (
    my_role() = 'entity_admin'::user_role
    and exists (
      select 1 from payroll_runs pr
      where pr.id = timesheet_entries.payroll_run_id
        and pr.entity_id = my_entity()
    )
  )
);

drop policy if exists timesheet_update on public.timesheet_entries;
create policy timesheet_update on public.timesheet_entries
for update
using (
  my_role() = 'owner'::user_role
  or (
    my_role() = 'entity_admin'::user_role
    and exists (
      select 1 from payroll_runs pr
      where pr.id = timesheet_entries.payroll_run_id
        and pr.entity_id = my_entity()
    )
  )
)
with check (
  my_role() = 'owner'::user_role
  or (
    my_role() = 'entity_admin'::user_role
    and exists (
      select 1 from payroll_runs pr
      where pr.id = timesheet_entries.payroll_run_id
        and pr.entity_id = my_entity()
    )
  )
);

drop policy if exists timesheet_delete on public.timesheet_entries;
create policy timesheet_delete on public.timesheet_entries
for delete
using (
  my_role() = 'owner'::user_role
  or (
    my_role() = 'entity_admin'::user_role
    and exists (
      select 1 from payroll_runs pr
      where pr.id = timesheet_entries.payroll_run_id
        and pr.entity_id = my_entity()
    )
  )
);

drop policy if exists tips_modify on public.tips_pools;
create policy tips_modify on public.tips_pools
for all
using (
  my_role() = 'owner'::user_role
  or (
    my_role() = 'entity_admin'::user_role
    and exists (
      select 1 from payroll_runs pr
      where pr.id = tips_pools.payroll_run_id
        and pr.entity_id = my_entity()
    )
  )
)
with check (
  my_role() = 'owner'::user_role
  or (
    my_role() = 'entity_admin'::user_role
    and exists (
      select 1 from payroll_runs pr
      where pr.id = tips_pools.payroll_run_id
        and pr.entity_id = my_entity()
    )
  )
);
