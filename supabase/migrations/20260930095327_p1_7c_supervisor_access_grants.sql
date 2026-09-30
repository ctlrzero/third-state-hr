-- P1-7 (part 3): access grants for a shift supervisor need a company, a branch and an employee record.
alter table public.access_grants drop constraint access_grants_scope_check;
alter table public.access_grants add constraint access_grants_scope_check check (
  ((role = 'owner'::user_role) and (entity_id is null) and (location_id is null) and (employee_id is null))
  or ((role = 'entity_admin'::user_role) and (entity_id is not null) and (location_id is null))
  or ((role = 'location_manager'::user_role) and (entity_id is not null) and (location_id is not null))
  or ((role = 'staff'::user_role) and (entity_id is not null) and (employee_id is not null))
  or ((role = 'shift_supervisor'::user_role) and (entity_id is not null) and (location_id is not null) and (employee_id is not null))
);
