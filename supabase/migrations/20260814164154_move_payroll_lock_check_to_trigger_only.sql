
-- The draft-status exists() clause embedded in RLS was silently filtering out rows before
-- they ever reached the enforce_payroll_child_immutability() trigger, meaning locked-run
-- write attempts were rejected (0 rows affected, no error) WITHOUT ever being logged to
-- audit_log — violating the explicit "Log attempted and successful payroll changes"
-- requirement. Move sole responsibility for the draft/locked check to the trigger (which
-- raises a hard exception and always logs), while RLS keeps only role/entity/location
-- scoping. This still rejects every direct SQL/API write against a locked run -- it now
-- does so with a real, logged exception instead of a silent no-op.

drop policy timesheet_insert on public.timesheet_entries;
create policy timesheet_insert on public.timesheet_entries for insert with check (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or ((my_role() = 'location_manager'::user_role) and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
);

drop policy timesheet_update on public.timesheet_entries;
create policy timesheet_update on public.timesheet_entries for update using (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or ((my_role() = 'location_manager'::user_role) and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
) with check (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or ((my_role() = 'location_manager'::user_role) and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
);

drop policy timesheet_delete on public.timesheet_entries;
create policy timesheet_delete on public.timesheet_entries for delete using (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
  or ((my_role() = 'location_manager'::user_role) and exists (select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
);

drop policy tips_modify on public.tips_pools;
create policy tips_modify on public.tips_pools for all using (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.entity_id = my_entity()))
  or ((my_role() = 'location_manager'::user_role) and location_id = my_location())
) with check (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.entity_id = my_entity()))
  or ((my_role() = 'location_manager'::user_role) and location_id = my_location())
);

drop policy deductions_access on public.payslip_deductions;
create policy deductions_access on public.payslip_deductions for all using (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.entity_id = my_entity()))
) with check (
  (my_role() = 'owner'::user_role)
  or ((my_role() = 'entity_admin'::user_role) and exists (select 1 from payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.entity_id = my_entity()))
);

