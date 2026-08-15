
alter table public.audit_log add column entity_id uuid references public.entities(id);
alter table public.audit_log add column location_id uuid references public.locations(id);
alter table public.audit_log add column employee_id uuid references public.employees(id);

create index audit_log_entity_id_idx on public.audit_log (entity_id);
create index audit_log_location_id_idx on public.audit_log (location_id);
create index audit_log_employee_id_idx on public.audit_log (employee_id);
