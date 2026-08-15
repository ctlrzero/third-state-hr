
create or replace function public.clock_in() returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_emp record;
  v_shift_id uuid;
  v_new_id uuid;
begin
  select id, entity_id, home_location_id, employment_status into v_emp from employees where id = my_employee_id();
  if v_emp.id is null then raise exception 'No employee record is linked to your account'; end if;
  if v_emp.employment_status <> 'active' then raise exception 'Inactive employees cannot clock in'; end if;

  if exists (select 1 from attendance_records where employee_id = v_emp.id and clock_out_at is null) then
    raise exception 'You already have an open clock-in — clock out first';
  end if;

  -- Best-effort match to today's own published, non-cancelled shift. Not
  -- finding one is not an error — the record is simply unmatched
  -- (shift_id null), surfaced to managers as a "no shift match" exception.
  select id into v_shift_id from shifts
    where employee_id = v_emp.id and shift_date = current_date and status <> 'cancelled' and is_published = true
    order by start_time limit 1;

  insert into attendance_records (entity_id, location_id, employee_id, shift_id, clock_in_at)
  values (v_emp.entity_id, v_emp.home_location_id, v_emp.id, v_shift_id, now())
  returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', v_new_id, auth.uid(), 'attendance_clock_in',
    jsonb_build_object('shift_id', v_shift_id, 'clock_in_at', now()), v_emp.entity_id, v_emp.home_location_id, v_emp.id);

  return jsonb_build_object('id', v_new_id, 'shift_id', v_shift_id);
end;
$$;

create or replace function public.clock_out() returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_emp_id uuid := my_employee_id();
  v_record record;
begin
  if v_emp_id is null then raise exception 'No employee record is linked to your account'; end if;

  select id, entity_id, location_id, clock_in_at into v_record
    from attendance_records
    where employee_id = v_emp_id and clock_out_at is null
    order by clock_in_at desc limit 1
    for update;

  if v_record.id is null then raise exception 'No open clock-in found to close'; end if;

  update attendance_records set clock_out_at = now(), updated_at = now() where id = v_record.id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', v_record.id, auth.uid(), 'attendance_clock_out',
    jsonb_build_object('clock_in_at', v_record.clock_in_at, 'clock_out_at', now()), v_record.entity_id, v_record.location_id, v_emp_id);

  return jsonb_build_object('id', v_record.id);
end;
$$;

create or replace function public.correct_attendance_record(
  p_record_id uuid, p_new_clock_in_at timestamptz, p_new_clock_out_at timestamptz, p_reason text
) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'A correction reason is required'; end if;
  if p_new_clock_out_at is not null and p_new_clock_out_at <= p_new_clock_in_at then
    raise exception 'Corrected clock-out must be after corrected clock-in';
  end if;

  select * into v_row from attendance_records where id = p_record_id for update;
  if v_row.id is null then raise exception 'Attendance record % not found', p_record_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_row.entity_id = my_entity())
    or (my_role() = 'location_manager' and v_row.location_id = my_location())
  ) then raise exception 'Not authorized to correct attendance for this branch'; end if;

  update attendance_records set
    -- Preserve the very first original values; a second correction must not
    -- overwrite the true original with an already-corrected one.
    original_clock_in_at = coalesce(original_clock_in_at, clock_in_at),
    original_clock_out_at = coalesce(original_clock_out_at, clock_out_at),
    clock_in_at = p_new_clock_in_at,
    clock_out_at = p_new_clock_out_at,
    corrected = true,
    correction_reason = p_reason,
    corrected_by = auth.uid(),
    corrected_at = now(),
    updated_at = now()
  where id = p_record_id;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', p_record_id, auth.uid(), 'attendance_corrected',
    jsonb_build_object('clock_in_at', v_row.clock_in_at, 'clock_out_at', v_row.clock_out_at),
    jsonb_build_object('clock_in_at', p_new_clock_in_at, 'clock_out_at', p_new_clock_out_at, 'reason', p_reason, 'actor_role', my_role()),
    v_row.entity_id, v_row.location_id, v_row.employee_id);
end;
$$;

-- Curated exception feed for managers: shifts that were never clocked
-- against, clock-ins never closed out, and clock-ins with no matching shift
-- at all. Read-only, no side effects — a manager decides what (if anything)
-- to do about each row via correct_attendance_record() or elsewhere.
create or replace function public.get_attendance_exceptions(
  p_location_id uuid, p_period_start date, p_period_end date
) returns table (
  exception_type text,
  employee_id uuid,
  employee_name text,
  shift_date date,
  record_id uuid,
  shift_id uuid,
  clock_in_at timestamptz,
  clock_out_at timestamptz
)
language plpgsql security definer stable set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
begin
  select entity_id into v_entity_id from locations where id = p_location_id;
  if v_entity_id is null then raise exception 'Location % not found', p_location_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and p_location_id = my_location())
  ) then raise exception 'Not authorized to view attendance for this branch'; end if;

  return query
  -- Missing clock-out: a past clock-in that was never closed.
  select 'missing_clock_out'::text, a.employee_id, e.full_name, a.clock_in_at::date, a.id, a.shift_id, a.clock_in_at, a.clock_out_at
  from attendance_records a
  join employees e on e.id = a.employee_id
  where a.location_id = p_location_id
    and a.clock_in_at::date between p_period_start and p_period_end
    and a.clock_out_at is null
    and a.clock_in_at::date < current_date

  union all

  -- Unmatched shift: a published, non-cancelled past shift with nobody ever
  -- clocking in against it.
  select 'unmatched_shift'::text, s.employee_id, e.full_name, s.shift_date, null::uuid, s.id, null::timestamptz, null::timestamptz
  from shifts s
  join employees e on e.id = s.employee_id
  where s.location_id = p_location_id
    and s.is_published = true
    and s.status <> 'cancelled'
    and s.employee_id is not null
    and s.shift_date between p_period_start and p_period_end
    and s.shift_date < current_date
    and not exists (select 1 from attendance_records a2 where a2.shift_id = s.id)

  union all

  -- No shift match: the employee clocked in but there was no published shift
  -- for them that day.
  select 'no_shift_match'::text, a.employee_id, e.full_name, a.clock_in_at::date, a.id, a.shift_id, a.clock_in_at, a.clock_out_at
  from attendance_records a
  join employees e on e.id = a.employee_id
  where a.location_id = p_location_id
    and a.clock_in_at::date between p_period_start and p_period_end
    and a.shift_id is null

  order by shift_date desc;
end;
$$;

revoke all on function public.clock_in() from public, anon;
grant execute on function public.clock_in() to authenticated;

revoke all on function public.clock_out() from public, anon;
grant execute on function public.clock_out() to authenticated;

revoke all on function public.correct_attendance_record(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.correct_attendance_record(uuid, timestamptz, timestamptz, text) to authenticated;

revoke all on function public.get_attendance_exceptions(uuid, date, date) from public, anon;
grant execute on function public.get_attendance_exceptions(uuid, date, date) to authenticated;

