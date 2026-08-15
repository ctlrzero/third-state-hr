
-- Phase 2.7: clock-in/attendance. Deliberately a standalone record of actual
-- time worked, matched to (but never merging into) the planned shift — it
-- never touches timesheet_entries, payslip_deductions or any payroll table.
-- Payroll continues to be entered manually via record_timesheet_entry per
-- Phase 1.1; a manager reviewing attendance exceptions decides what (if
-- anything) to key into payroll, same as before this phase existed.

create table public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  employee_id uuid not null references public.employees(id),
  shift_id uuid references public.shifts(id),
  clock_in_at timestamptz not null,
  clock_out_at timestamptz,
  original_clock_in_at timestamptz,
  original_clock_out_at timestamptz,
  corrected boolean not null default false,
  correction_reason text,
  corrected_by uuid references auth.users(id),
  corrected_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint attendance_clock_out_after_in check (clock_out_at is null or clock_out_at > clock_in_at)
);

-- At most one open (still clocked-in) record per employee at a time — a
-- database backstop, not just an RPC-level check.
create unique index attendance_one_open_per_employee_uq on public.attendance_records(employee_id) where clock_out_at is null;
create index attendance_employee_time_idx on public.attendance_records(employee_id, clock_in_at);
create index attendance_location_time_idx on public.attendance_records(location_id, clock_in_at);
create index attendance_shift_idx on public.attendance_records(shift_id) where shift_id is not null;

alter table public.attendance_records enable row level security;

create policy attendance_select_self on public.attendance_records
  for select to authenticated
  using (employee_id = my_employee_id());

create policy attendance_select_admin on public.attendance_records
  for select to authenticated
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and entity_id = my_entity())
    or (my_role() = 'location_manager' and location_id = my_location())
  );

-- No INSERT/UPDATE/DELETE policy for authenticated at all — every write goes
-- through clock_in() / clock_out() / correct_attendance_record() below, so
-- an employee can never backdate their own clock-in/out and a manager
-- correction always carries a reason and a preserved original value.
revoke all on public.attendance_records from authenticated, anon, public;
grant select on public.attendance_records to authenticated;

