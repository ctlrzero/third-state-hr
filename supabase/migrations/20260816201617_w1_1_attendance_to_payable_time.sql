-- W1-1 (Phase 1): Attendance-evidence-to-payable-time.
--
-- Introduces payable_shift_records (one row per published shift, the
-- canonical link between a scheduled shift and the payable minutes it
-- produces), attendance_adjustments (proposed corrections to a payable
-- shift record's minutes, created only via propose_attendance_adjustment()
-- and requiring owner/entity_admin approval), and timesheet_entry_sources
-- (append-only lineage: which payable_shift_records were materialized into
-- which timesheet_entries row, for which payroll_run, guarded against
-- cross-run mixing by a BEFORE INSERT trigger and against post-lock
-- mutation by the existing enforce_payroll_child_immutability trigger).
--
-- This migration is append-only: it does not modify or drop any existing
-- migration. It extends timesheet_entries with a new nullable-default
-- boolean column (source_locked) and extends record_timesheet_entry with a
-- minimal guard so manual entry cannot silently corrupt a row that is being
-- maintained via shift materialization -- this is a CREATE OR REPLACE of an
-- existing function body (permitted; only migration *files* are immutable,
-- not function definitions), not a duplicate overload.
--
-- Design notes carried over from live schema investigation this session:
--   - shifts has no break_minutes column yet (Phase 2/W2-1 scope) --
--     planned_break_minutes defaults to 0 here, matching the plan's
--     documented fallback.
--   - timesheet_entries has UNIQUE (payroll_run_id, employee_id) --
--     materialize_payroll_from_payable_shifts() must upsert into that one
--     row per employee/run, not blind-INSERT like record_timesheet_entry.
--   - timesheet_entries stores hours (numeric), payable_shift_records
--     stores minutes (integer) -- conversion happens only at the
--     materialization boundary.
--   - attendance_records is the actual clock-in/out evidence table
--     (separate from shifts, the schedule). default_payable_minutes uses
--     attendance_records when a completed (clock_out_at is not null) row
--     exists for the shift, else falls back to the scheduled duration --
--     this is what "attendance-evidence-to-payable-time" means concretely.

-- ============================================================
-- Table: payable_shift_records
-- ============================================================
create table public.payable_shift_records (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null unique references public.shifts(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  entity_id uuid not null references public.entities(id),
  location_id uuid not null references public.locations(id),
  planned_minutes integer not null check (planned_minutes >= 0),
  planned_break_minutes integer not null default 0 check (planned_break_minutes >= 0),
  default_payable_minutes integer not null check (default_payable_minutes >= 0),
  final_payable_minutes integer check (final_payable_minutes is null or final_payable_minutes >= 0),
  status text not null default 'pending' check (status in ('pending', 'adjusted', 'materialized')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.payable_shift_records is
  'Phase 1 (W1-1): one row per published shift. Bridges scheduling (shifts) '
  'and attendance evidence (attendance_records) into the payable-minutes '
  'figure that materialize_payroll_from_payable_shifts() later converts to '
  'timesheet_entries hours. planned_break_minutes is a placeholder (0) '
  'until Phase 2 (W2-1 break policy) lands.';

create index payable_shift_records_location_period_idx
  on public.payable_shift_records (location_id, employee_id, status);

alter table public.payable_shift_records enable row level security;

-- SELECT: owner (all), entity_admin (own entity), location_manager (own
-- location -- this is attendance-domain visibility, distinct from the
-- payroll-domain tables W0 already locked location_manager out of), and the
-- employee's own record (mirrors payslips_select_self / timesheet_select's
-- existing self-visibility pattern).
create policy payable_shift_records_select on public.payable_shift_records
for select
using (
  employee_id = my_employee_id()
  or my_role() = 'owner'::user_role
  or (my_role() = 'entity_admin'::user_role and entity_id = my_entity())
  or (my_role() = 'location_manager'::user_role and location_id = my_location())
);

-- No direct INSERT/UPDATE/DELETE policy for authenticated: all mutation of
-- this table happens through SECURITY DEFINER RPCs below, which perform
-- their own authorization and write audit_log rows. No policy is created
-- for insert/update/delete, and no such grant is issued below -- matching
-- attendance_adjustments' "creation restricted to the RPC only" design.

grant select on table public.payable_shift_records to authenticated;

-- ============================================================
-- Table: attendance_adjustments
-- ============================================================
create table public.attendance_adjustments (
  id uuid primary key default gen_random_uuid(),
  payable_shift_record_id uuid not null references public.payable_shift_records(id) on delete cascade,
  proposed_minutes integer not null check (proposed_minutes >= 0),
  reason text not null check (length(btrim(reason)) > 0),
  actor_id uuid not null references public.profiles(id),
  actor_role user_role not null,
  status text not null default 'pending' check (status in ('pending', 'applied', 'rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id),
  decision_reason text
);

comment on table public.attendance_adjustments is
  'Phase 1 (W1-1): proposed corrections to a payable_shift_records row''s '
  'minutes. Rows may only be created by propose_attendance_adjustment() -- '
  'there is no direct authenticated INSERT grant on this table -- and '
  'decided by apply_attendance_adjustment()/reject_attendance_adjustment().';

create index attendance_adjustments_shift_record_idx
  on public.attendance_adjustments (payable_shift_record_id, status);

alter table public.attendance_adjustments enable row level security;

create policy attendance_adjustments_select on public.attendance_adjustments
for select
using (
  my_role() = 'owner'::user_role
  or (my_role() = 'entity_admin'::user_role and exists (
    select 1 from public.payable_shift_records psr
    where psr.id = attendance_adjustments.payable_shift_record_id
      and psr.entity_id = my_entity()
  ))
  or (my_role() = 'location_manager'::user_role and exists (
    select 1 from public.payable_shift_records psr
    where psr.id = attendance_adjustments.payable_shift_record_id
      and psr.location_id = my_location()
  ))
  or actor_id = auth.uid()
);

-- Explicit minimum grant: SELECT only. INSERT/UPDATE happen exclusively
-- through the RPCs (SECURITY DEFINER, owned by postgres), so authenticated
-- needs no direct write grant here at all.
grant select on table public.attendance_adjustments to authenticated;

-- ============================================================
-- Table: timesheet_entry_sources
-- ============================================================
create table public.timesheet_entry_sources (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid not null references public.payroll_runs(id) on delete cascade,
  timesheet_entry_id uuid not null references public.timesheet_entries(id) on delete cascade,
  payable_shift_record_id uuid not null references public.payable_shift_records(id),
  contributed_minutes integer not null check (contributed_minutes >= 0),
  created_at timestamptz not null default now(),
  unique (payroll_run_id, payable_shift_record_id)
);

comment on table public.timesheet_entry_sources is
  'Phase 1 (W1-1): append-only lineage between payable_shift_records and '
  'the timesheet_entries row each was materialized into, scoped per '
  'payroll_run_id. Guarded by enforce_timesheet_entry_source_run_match '
  '(the referenced timesheet_entry must belong to the same payroll_run_id) '
  'and by the existing enforce_payroll_child_immutability trigger (no '
  'writes once the run leaves draft).';

create index timesheet_entry_sources_entry_idx
  on public.timesheet_entry_sources (timesheet_entry_id);

alter table public.timesheet_entry_sources enable row level security;

create policy timesheet_entry_sources_select on public.timesheet_entry_sources
for select
using (
  my_role() = 'owner'::user_role
  or (my_role() = 'entity_admin'::user_role and exists (
    select 1 from public.payroll_runs pr
    where pr.id = timesheet_entry_sources.payroll_run_id
      and pr.entity_id = my_entity()
  ))
);

-- SELECT only for authenticated; all writes happen through
-- materialize_payroll_from_payable_shifts()/override_materialized_payable_shift().
grant select on table public.timesheet_entry_sources to authenticated;

create function public.enforce_timesheet_entry_source_run_match()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_run_id uuid;
begin
  select payroll_run_id into v_entry_run_id
  from public.timesheet_entries
  where id = new.timesheet_entry_id;

  if v_entry_run_id is null then
    raise exception 'timesheet_entry % not found', new.timesheet_entry_id;
  end if;

  if v_entry_run_id <> new.payroll_run_id then
    raise exception
      'timesheet_entry % belongs to payroll_run %, not %',
      new.timesheet_entry_id, v_entry_run_id, new.payroll_run_id;
  end if;

  return new;
end;
$$;

create trigger enforce_timesheet_entry_source_run_match
before insert on public.timesheet_entry_sources
for each row execute function public.enforce_timesheet_entry_source_run_match();

-- Reuse the existing generic immutability trigger: it keys off
-- coalesce(new.payroll_run_id, old.payroll_run_id) and tg_table_name, so it
-- applies unchanged to this table -- no duplicate trigger function needed.
create trigger enforce_payroll_child_immutability
before update or delete on public.timesheet_entry_sources
for each row execute function public.enforce_payroll_child_immutability();

-- ============================================================
-- timesheet_entries: add source_locked (nullable-default boolean).
-- true once a row is being maintained via shift materialization, so
-- record_timesheet_entry's manual-entry path (below) can refuse to write
-- over shift-sourced hours instead of silently double-counting.
-- ============================================================
alter table public.timesheet_entries
  add column source_locked boolean not null default false;

comment on column public.timesheet_entries.source_locked is
  'Phase 1 (W1-1): true once materialize_payroll_from_payable_shifts() has '
  'contributed to this row. Manual record_timesheet_entry updates are then '
  'refused -- corrections must go through override_materialized_payable_shift().';

-- ============================================================
-- record_timesheet_entry: minimal guard addition (CREATE OR REPLACE of the
-- existing function body; not a duplicate overload, not a new migration
-- file editing an old one). Adds one check: refuse to touch a row that is
-- already source_locked. All other behavior is byte-for-byte identical to
-- the pre-Phase-1 version.
-- ============================================================
create or replace function public.record_timesheet_entry(
  p_payroll_run_id uuid,
  p_employee_id uuid,
  p_regular_hours numeric default 0,
  p_overtime_hours numeric default 0,
  p_holiday_hours numeric default 0,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_run record; v_authorized boolean := false; v_request_id uuid := gen_random_uuid(); v_new_id uuid;
  v_emp_location uuid;
  v_existing_locked boolean;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;
  select home_location_id into v_emp_location from employees where id = p_employee_id;
  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  end if;
  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'timesheet_entries', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;
  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'timesheet_entries', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  select source_locked into v_existing_locked
  from timesheet_entries
  where payroll_run_id = p_payroll_run_id and employee_id = p_employee_id;

  if v_existing_locked then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('timesheet_entries', p_employee_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'source_locked', 'child_table', 'timesheet_entries', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'SOURCE_LOCKED', 'message', 'This timesheet entry is maintained from materialized attendance records. Use the payable-shift override instead of a manual edit.', 'request_id', v_request_id);
  end if;

  insert into timesheet_entries (payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes)
  values (p_payroll_run_id, p_employee_id, coalesce(p_regular_hours, 0), coalesce(p_overtime_hours, 0), coalesce(p_holiday_hours, 0), p_notes)
  returning id into v_new_id;
  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('timesheet_entries', v_new_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'employee_id', p_employee_id, 'request_id', v_request_id),
    v_run.entity_id, v_emp_location, p_employee_id);
  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'id', v_new_id);
end;
$$;

-- ============================================================
-- RPC: seed_payable_shift_records
-- Creates payable_shift_records for published shifts in a location/period
-- that don't already have one. Idempotent (ON CONFLICT (shift_id) DO
-- NOTHING against the existing unique constraint).
-- ============================================================
create function public.seed_payable_shift_records(
  p_location_id uuid,
  p_period_start date,
  p_period_end date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
  v_loc record;
  v_seeded_count integer;
begin
  select * into v_loc from locations where id = p_location_id;
  if v_loc.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Location not found.', 'request_id', v_request_id);
  end if;

  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_loc.entity_id = my_entity() then v_authorized := true;
  elsif my_role() = 'location_manager' and p_location_id = my_location() then v_authorized := true;
  end if;

  if not v_authorized then
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to seed attendance records for this location.', 'request_id', v_request_id);
  end if;

  if p_period_end < p_period_start then
    return jsonb_build_object('ok', false, 'code', 'INVALID_PERIOD', 'message', 'Period end must not be before period start.', 'request_id', v_request_id);
  end if;

  with inserted as (
    insert into payable_shift_records (
      shift_id, employee_id, entity_id, location_id,
      planned_minutes, planned_break_minutes, default_payable_minutes, status
    )
    select
      s.id,
      s.employee_id,
      s.entity_id,
      s.location_id,
      case
        when s.end_time >= s.start_time
          then extract(epoch from (s.end_time - s.start_time))::integer / 60
        else extract(epoch from (s.end_time - s.start_time + interval '24 hours'))::integer / 60
      end as planned_minutes,
      0,
      coalesce(
        (
          select round(extract(epoch from (ar.clock_out_at - ar.clock_in_at)) / 60)::integer
          from attendance_records ar
          where ar.shift_id = s.id and ar.clock_out_at is not null
          order by ar.clock_out_at desc
          limit 1
        ),
        case
          when s.end_time >= s.start_time
            then extract(epoch from (s.end_time - s.start_time))::integer / 60
          else extract(epoch from (s.end_time - s.start_time + interval '24 hours'))::integer / 60
        end
      ),
      'pending'
    from shifts s
    where s.location_id = p_location_id
      and s.shift_date between p_period_start and p_period_end
      and s.is_published = true
      and s.employee_id is not null
    on conflict (shift_id) do nothing
    returning 1
  )
  select count(*) into v_seeded_count from inserted;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('payable_shift_records', p_location_id, auth.uid(), 'attendance_seed_succeeded',
    jsonb_build_object('location_id', p_location_id, 'period_start', p_period_start, 'period_end', p_period_end, 'seeded_count', v_seeded_count, 'request_id', v_request_id),
    v_loc.entity_id, p_location_id);

  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'seeded_count', v_seeded_count);
end;
$$;

-- ============================================================
-- RPC: propose_attendance_adjustment
-- The only permitted way to create an attendance_adjustments row.
-- ============================================================
create function public.propose_attendance_adjustment(
  p_payable_shift_record_id uuid,
  p_proposed_minutes integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rec record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
  v_adjustment_id uuid;
begin
  select * into v_rec from payable_shift_records where id = p_payable_shift_record_id for update;
  if v_rec.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payable shift record not found.', 'request_id', v_request_id);
  end if;

  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_rec.entity_id = my_entity() then v_authorized := true;
  elsif my_role() = 'location_manager' and v_rec.location_id = my_location() then v_authorized := true;
  end if;

  if not v_authorized then
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to propose an adjustment for this shift.', 'request_id', v_request_id);
  end if;

  if p_reason is null or length(btrim(p_reason)) = 0 then
    return jsonb_build_object('ok', false, 'code', 'REASON_REQUIRED', 'message', 'A reason is required to propose an attendance adjustment.', 'request_id', v_request_id);
  end if;

  if p_proposed_minutes is null or p_proposed_minutes < 0 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_MINUTES', 'message', 'Proposed minutes must be zero or greater.', 'request_id', v_request_id);
  end if;

  if v_rec.status = 'materialized' then
    return jsonb_build_object('ok', false, 'code', 'ALREADY_MATERIALIZED', 'message', 'This shift has already been materialized into payroll. Use the materialized-record override instead.', 'request_id', v_request_id);
  end if;

  insert into attendance_adjustments (payable_shift_record_id, proposed_minutes, reason, actor_id, actor_role, status)
  values (p_payable_shift_record_id, p_proposed_minutes, p_reason, auth.uid(), my_role(), 'pending')
  returning id into v_adjustment_id;

  update payable_shift_records
  set status = 'adjusted', updated_at = now()
  where id = p_payable_shift_record_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_adjustments', v_adjustment_id, auth.uid(), 'attendance_adjustment_proposed',
    jsonb_build_object('payable_shift_record_id', p_payable_shift_record_id, 'proposed_minutes', p_proposed_minutes, 'reason', p_reason, 'request_id', v_request_id),
    v_rec.entity_id, v_rec.location_id, v_rec.employee_id);

  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'adjustment_id', v_adjustment_id);
end;
$$;

-- ============================================================
-- RPC: apply_attendance_adjustment
-- Approval authority: owner (any), entity_admin (own entity only) --
-- mirrors the existing payroll-approval tier, kept one level above the
-- location_manager who may have proposed the adjustment.
-- ============================================================
create function public.apply_attendance_adjustment(
  p_adjustment_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_adj record;
  v_rec record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
begin
  select * into v_adj from attendance_adjustments where id = p_adjustment_id for update;
  if v_adj.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Adjustment not found.', 'request_id', v_request_id);
  end if;

  select * into v_rec from payable_shift_records where id = v_adj.payable_shift_record_id for update;

  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_rec.entity_id = my_entity() then v_authorized := true;
  end if;

  if not v_authorized then
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to approve this adjustment.', 'request_id', v_request_id);
  end if;

  if v_adj.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'ALREADY_DECIDED', 'message', 'This adjustment has already been decided.', 'request_id', v_request_id);
  end if;

  update payable_shift_records
  set final_payable_minutes = v_adj.proposed_minutes, status = 'adjusted', updated_at = now()
  where id = v_rec.id;

  update attendance_adjustments
  set status = 'applied', decided_at = now(), decided_by = auth.uid()
  where id = p_adjustment_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_adjustments', p_adjustment_id, auth.uid(), 'attendance_adjustment_applied',
    jsonb_build_object('payable_shift_record_id', v_rec.id, 'final_payable_minutes', v_adj.proposed_minutes, 'request_id', v_request_id),
    v_rec.entity_id, v_rec.location_id, v_rec.employee_id);

  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

-- ============================================================
-- RPC: reject_attendance_adjustment
-- ============================================================
create function public.reject_attendance_adjustment(
  p_adjustment_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_adj record;
  v_rec record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
begin
  select * into v_adj from attendance_adjustments where id = p_adjustment_id for update;
  if v_adj.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Adjustment not found.', 'request_id', v_request_id);
  end if;

  select * into v_rec from payable_shift_records where id = v_adj.payable_shift_record_id for update;

  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_rec.entity_id = my_entity() then v_authorized := true;
  end if;

  if not v_authorized then
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to reject this adjustment.', 'request_id', v_request_id);
  end if;

  if v_adj.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'ALREADY_DECIDED', 'message', 'This adjustment has already been decided.', 'request_id', v_request_id);
  end if;

  if p_reason is null or length(btrim(p_reason)) = 0 then
    return jsonb_build_object('ok', false, 'code', 'REASON_REQUIRED', 'message', 'A reason is required to reject an attendance adjustment.', 'request_id', v_request_id);
  end if;

  update payable_shift_records
  set status = 'pending', updated_at = now()
  where id = v_rec.id;

  update attendance_adjustments
  set status = 'rejected', decided_at = now(), decided_by = auth.uid(), decision_reason = p_reason
  where id = p_adjustment_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_adjustments', p_adjustment_id, auth.uid(), 'attendance_adjustment_rejected',
    jsonb_build_object('payable_shift_record_id', v_rec.id, 'reason', p_reason, 'request_id', v_request_id),
    v_rec.entity_id, v_rec.location_id, v_rec.employee_id);

  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

-- ============================================================
-- RPC: materialize_payroll_from_payable_shifts
-- Converts a set of payable_shift_records for one employee into (or onto)
-- the single timesheet_entries row for (payroll_run_id, employee_id),
-- honoring the pre-existing unique constraint via upsert, recording
-- per-shift lineage in timesheet_entry_sources, and locking rows in
-- id-ascending order to avoid deadlocks under concurrent materialization.
-- ============================================================
create function public.materialize_payroll_from_payable_shifts(
  p_payroll_run_id uuid,
  p_employee_id uuid,
  p_payable_shift_record_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
  v_emp_location uuid;
  v_total_minutes integer;
  v_hours numeric;
  v_timesheet_entry_id uuid;
  v_existing_locked boolean;
  v_bad_count integer;
  v_already_used_count integer;
  v_records_count integer;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;

  select home_location_id into v_emp_location from employees where id = p_employee_id;

  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  end if;

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'timesheet_entry_sources', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'timesheet_entry_sources', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  if p_payable_shift_record_ids is null or array_length(p_payable_shift_record_ids, 1) is null then
    return jsonb_build_object('ok', false, 'code', 'NO_RECORDS', 'message', 'No payable shift records supplied.', 'request_id', v_request_id);
  end if;

  -- Lock the candidate rows in fixed id-ascending order to avoid deadlocks
  -- against concurrent materialization calls touching overlapping sets.
  create temporary table if not exists tmp_psr_lock (id uuid) on commit drop;
  delete from tmp_psr_lock;
  insert into tmp_psr_lock
  select id from payable_shift_records
  where id = any(p_payable_shift_record_ids)
  order by id
  for update;

  select count(*) into v_records_count from tmp_psr_lock;
  if v_records_count <> array_length(p_payable_shift_record_ids, 1) then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'One or more payable shift records were not found.', 'request_id', v_request_id);
  end if;

  select count(*) into v_bad_count
  from payable_shift_records psr
  where psr.id in (select id from tmp_psr_lock)
    and (psr.employee_id <> p_employee_id or psr.status = 'materialized');
  if v_bad_count > 0 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_SELECTION', 'message', 'One or more selected shift records do not belong to this employee or are already materialized.', 'request_id', v_request_id);
  end if;

  select count(*) into v_already_used_count
  from timesheet_entry_sources tes
  where tes.payable_shift_record_id in (select id from tmp_psr_lock);
  if v_already_used_count > 0 then
    return jsonb_build_object('ok', false, 'code', 'ALREADY_MATERIALIZED', 'message', 'One or more selected shift records have already been materialized into a payroll run.', 'request_id', v_request_id);
  end if;

  select sum(coalesce(psr.final_payable_minutes, psr.default_payable_minutes))
  into v_total_minutes
  from payable_shift_records psr
  where psr.id in (select id from tmp_psr_lock);

  v_hours := round(v_total_minutes / 60.0, 2);

  select id, source_locked into v_timesheet_entry_id, v_existing_locked
  from timesheet_entries
  where payroll_run_id = p_payroll_run_id and employee_id = p_employee_id;

  if v_timesheet_entry_id is not null and not v_existing_locked then
    return jsonb_build_object('ok', false, 'code', 'MANUAL_ENTRY_EXISTS', 'message', 'A manually-entered timesheet row already exists for this employee and run. Resolve it before materializing shift-sourced hours.', 'request_id', v_request_id);
  end if;

  if v_timesheet_entry_id is null then
    insert into timesheet_entries (payroll_run_id, employee_id, regular_hours, source_locked)
    values (p_payroll_run_id, p_employee_id, v_hours, true)
    returning id into v_timesheet_entry_id;
  else
    update timesheet_entries
    set regular_hours = regular_hours + v_hours, source_locked = true
    where id = v_timesheet_entry_id;
  end if;

  insert into timesheet_entry_sources (payroll_run_id, timesheet_entry_id, payable_shift_record_id, contributed_minutes)
  select p_payroll_run_id, v_timesheet_entry_id, psr.id, coalesce(psr.final_payable_minutes, psr.default_payable_minutes)
  from payable_shift_records psr
  where psr.id in (select id from tmp_psr_lock)
  on conflict (payroll_run_id, payable_shift_record_id) do nothing;

  update payable_shift_records
  set status = 'materialized', updated_at = now()
  where id in (select id from tmp_psr_lock);

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('timesheet_entries', v_timesheet_entry_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'employee_id', p_employee_id, 'materialized_minutes', v_total_minutes, 'hours_added', v_hours, 'records_materialized', v_records_count, 'request_id', v_request_id),
    v_run.entity_id, v_emp_location, p_employee_id);

  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'timesheet_entry_id', v_timesheet_entry_id, 'hours_added', v_hours, 'records_materialized', v_records_count);
end;
$$;

-- ============================================================
-- RPC: override_materialized_payable_shift
-- Mandatory-reason correction to an already-materialized shift record,
-- while its payroll run is still draft. Adjusts timesheet_entries.regular_hours
-- by the delta and updates the lineage row's contributed_minutes.
-- ============================================================
create function public.override_materialized_payable_shift(
  p_payable_shift_record_id uuid,
  p_new_minutes integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rec record;
  v_source record;
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
  v_old_minutes integer;
  v_delta_hours numeric;
begin
  select * into v_rec from payable_shift_records where id = p_payable_shift_record_id for update;
  if v_rec.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payable shift record not found.', 'request_id', v_request_id);
  end if;

  if v_rec.status <> 'materialized' then
    return jsonb_build_object('ok', false, 'code', 'NOT_MATERIALIZED', 'message', 'This shift record has not been materialized into payroll yet. Use propose_attendance_adjustment instead.', 'request_id', v_request_id);
  end if;

  if p_reason is null or length(btrim(p_reason)) = 0 then
    return jsonb_build_object('ok', false, 'code', 'REASON_REQUIRED', 'message', 'A reason is required to override a materialized shift record.', 'request_id', v_request_id);
  end if;

  if p_new_minutes is null or p_new_minutes < 0 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_MINUTES', 'message', 'New minutes must be zero or greater.', 'request_id', v_request_id);
  end if;

  select * into v_source from timesheet_entry_sources where payable_shift_record_id = p_payable_shift_record_id;
  if v_source.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'No materialization lineage found for this shift record.', 'request_id', v_request_id);
  end if;

  select * into v_run from payroll_runs where id = v_source.payroll_run_id for update;

  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  end if;

  if not v_authorized then
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to override this shift record.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked; corrections require a revision run.', 'request_id', v_request_id);
  end if;

  v_old_minutes := coalesce(v_rec.final_payable_minutes, v_rec.default_payable_minutes);
  v_delta_hours := round((p_new_minutes - v_old_minutes) / 60.0, 2);

  update payable_shift_records
  set final_payable_minutes = p_new_minutes, updated_at = now()
  where id = p_payable_shift_record_id;

  update timesheet_entry_sources
  set contributed_minutes = p_new_minutes
  where id = v_source.id;

  update timesheet_entries
  set regular_hours = regular_hours + v_delta_hours
  where id = v_source.timesheet_entry_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('payable_shift_records', p_payable_shift_record_id, auth.uid(), 'attendance_override_applied',
    jsonb_build_object('old_minutes', v_old_minutes, 'new_minutes', p_new_minutes, 'delta_hours', v_delta_hours, 'reason', p_reason, 'request_id', v_request_id),
    v_rec.entity_id, v_rec.location_id, v_rec.employee_id);

  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'delta_hours', v_delta_hours);
end;
$$;

-- ============================================================
-- RPC: get_location_attendance_overview
-- Location-manager-facing, non-payroll attendance view. Deliberately does
-- not reference timesheet_entries, payroll_runs, payslips,
-- payslip_deductions, or timesheet_entry_sources in its query body, so it
-- cannot leak payroll figures to a role that W0 correctly excluded from
-- the payroll tables.
-- ============================================================
create function public.get_location_attendance_overview(
  p_location_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  shift_id uuid,
  employee_id uuid,
  shift_date date,
  planned_minutes integer,
  default_payable_minutes integer,
  final_payable_minutes integer,
  payable_status text,
  pending_adjustment boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_loc record;
  v_authorized boolean := false;
begin
  select * into v_loc from locations where id = p_location_id;
  if v_loc.id is null then
    raise exception 'Location not found';
  end if;

  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_loc.entity_id = my_entity() then v_authorized := true;
  elsif my_role() = 'location_manager' and p_location_id = my_location() then v_authorized := true;
  end if;

  if not v_authorized then
    raise exception 'Not authorized to view attendance for this location';
  end if;

  return query
  select
    psr.shift_id,
    psr.employee_id,
    s.shift_date,
    psr.planned_minutes,
    psr.default_payable_minutes,
    psr.final_payable_minutes,
    psr.status,
    exists (
      select 1 from attendance_adjustments aa
      where aa.payable_shift_record_id = psr.id and aa.status = 'pending'
    ) as pending_adjustment
  from payable_shift_records psr
  join shifts s on s.id = psr.shift_id
  where psr.location_id = p_location_id
    and s.shift_date between p_period_start and p_period_end
  order by s.shift_date, psr.employee_id;
end;
$$;

-- ============================================================
-- Explicit minimum execute grants (zero default privileges means every new
-- function must self-grant explicitly, per W0-2's standing rule).
-- ============================================================
grant execute on function public.seed_payable_shift_records(uuid, date, date) to authenticated;
grant execute on function public.propose_attendance_adjustment(uuid, integer, text) to authenticated;
grant execute on function public.apply_attendance_adjustment(uuid) to authenticated;
grant execute on function public.reject_attendance_adjustment(uuid, text) to authenticated;
grant execute on function public.materialize_payroll_from_payable_shifts(uuid, uuid, uuid[]) to authenticated;
grant execute on function public.override_materialized_payable_shift(uuid, integer, text) to authenticated;
grant execute on function public.get_location_attendance_overview(uuid, date, date) to authenticated;
