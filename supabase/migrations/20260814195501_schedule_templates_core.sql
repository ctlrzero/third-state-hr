
-- Phase 2.6: recurring weekly schedule templates that generate Draft shifts
-- for a period, reviewed, then Published. Drafts must be invisible to
-- employees even if a draft shift is already assigned to them — enforced via
-- a new is_published flag on shifts (kept separate from the existing
-- open/assigned/cancelled `status`, which is about staffing, not visibility)
-- plus updated RLS on the two staff-facing shifts SELECT policies.

create table public.schedule_templates (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  employee_id uuid not null references public.employees(id),
  position_id uuid references public.positions(id),
  day_of_week smallint not null check (day_of_week between 0 and 6), -- matches Postgres EXTRACT(dow): 0=Sunday..6=Saturday
  start_time time not null,
  end_time time not null,
  break_minutes int not null default 0 check (break_minutes >= 0),
  effective_start_date date not null,
  effective_end_date date,
  version_number int not null default 1,
  supersedes_template_id uuid references public.schedule_templates(id),
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint schedule_templates_time_check check (end_time > start_time),
  constraint schedule_templates_date_range_check check (effective_end_date is null or effective_end_date >= effective_start_date)
);

create index schedule_templates_location_active_idx on public.schedule_templates(location_id, is_active);
create index schedule_templates_employee_day_idx on public.schedule_templates(employee_id, day_of_week) where is_active;

alter table public.schedule_templates enable row level security;

-- Read-only for authenticated users, scoped the same way as shifts_access.
-- All writes go through the RPCs below (create/replace/deactivate) so that
-- overlap/break/date-range validation is never bypassable via a raw insert.
create policy schedule_templates_select on public.schedule_templates
  for select to authenticated
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and entity_id = my_entity())
    or (my_role() = 'location_manager' and location_id = my_location())
  );

revoke all on public.schedule_templates from authenticated, anon, public;
grant select on public.schedule_templates to authenticated;

-- ---------------------------------------------------------------------------
-- shifts: draft/publish support
-- ---------------------------------------------------------------------------

alter table public.shifts add column is_published boolean not null default true;
alter table public.shifts add column generated_from_template_id uuid references public.schedule_templates(id) on delete set null;

create unique index shifts_template_shift_date_uq on public.shifts(generated_from_template_id, shift_date)
  where generated_from_template_id is not null;

create index shifts_location_published_idx on public.shifts(location_id, is_published, shift_date);

-- Drafts must never appear on an employee's own view, even for a shift
-- already assigned to them, and never appear on the open-shift board.
drop policy shifts_select_open_home_location on public.shifts;
create policy shifts_select_open_home_location on public.shifts
  for select to authenticated
  using (status = 'open' and location_id = my_home_location() and is_published = true);

drop policy shifts_select_self on public.shifts;
create policy shifts_select_self on public.shifts
  for select to authenticated
  using (employee_id = my_employee_id() and is_published = true);

-- owner/entity_admin/location_manager keep full visibility (including drafts)
-- via the existing shifts_access policy — unchanged.
;
