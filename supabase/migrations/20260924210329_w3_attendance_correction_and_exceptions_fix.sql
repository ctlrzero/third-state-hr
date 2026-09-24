-- ============================================================
-- W3: attendance correction + exception fixes (smoke-test findings)
-- ------------------------------------------------------------
-- correct_attendance_record: NULL for p_new_clock_in_at /
--   p_new_clock_out_at now means "keep the current value" (was: write
--   NULL -> 23502 on clock-in, and silently erased a clock-out when a
--   manager corrected only the clock-in). Validation runs on the
--   effective values; originals are still preserved on first
--   correction; a no-op correction is rejected. Signature unchanged.
-- get_attendance_exceptions: business dates are Asia/Dubai (was the
--   UTC session date, so a missing clock-out from "yesterday" in Dubai
--   was not reported until 04:00). Adds exception_type 'late_clock_in'
--   (clock-in after planned start; informational only - no automatic
--   deduction). Signature and columns unchanged.
-- ============================================================

create or replace function public.correct_attendance_record(
  p_record_id uuid,
  p_new_clock_in_at timestamptz,
  p_new_clock_out_at timestamptz,
  p_reason text
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_row public.attendance_records;
  v_role public.user_role := public.my_role();
  v_in timestamptz;
  v_out timestamptz;
begin
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'A correction reason is required';
  end if;

  select * into v_row from public.attendance_records where id = p_record_id for update;
  if v_row.id is null then
    raise exception 'Attendance record % not found', p_record_id;
  end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_row.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v_row.location_id = public.my_location())
  ) then
    raise exception 'Not authorized to correct attendance for this branch';
  end if;

  v_in := coalesce(p_new_clock_in_at, v_row.clock_in_at);
  v_out := coalesce(p_new_clock_out_at, v_row.clock_out_at);

  if v_out is not null and v_out <= v_in then
    raise exception 'Corrected clock-out must be after corrected clock-in';
  end if;
  if v_in > now() + interval '5 minutes' or (v_out is not null and v_out > now() + interval '5 minutes') then
    raise exception 'Corrected times cannot be in the future';
  end if;
  if v_in = v_row.clock_in_at and v_out is not distinct from v_row.clock_out_at then
    raise exception 'The correction does not change the record';
  end if;

  update public.attendance_records set
    -- Preserve the very first original values; a second correction must not
    -- overwrite the true original with an already-corrected one.
    original_clock_in_at = coalesce(original_clock_in_at, clock_in_at),
    original_clock_out_at = coalesce(original_clock_out_at, clock_out_at),
    clock_in_at = v_in,
    clock_out_at = v_out,
    corrected = true,
    correction_reason = btrim(p_reason),
    corrected_by = auth.uid(),
    corrected_at = now(),
    updated_at = now()
  where id = p_record_id;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', p_record_id, auth.uid(), 'attendance_corrected',
    jsonb_build_object('clock_in_at', v_row.clock_in_at, 'clock_out_at', v_row.clock_out_at),
    jsonb_build_object('clock_in_at', v_in, 'clock_out_at', v_out, 'reason', btrim(p_reason), 'actor_role', v_role),
    v_row.entity_id, v_row.location_id, v_row.employee_id);
end;
$$;
revoke all on function public.correct_attendance_record(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.correct_attendance_record(uuid, timestamptz, timestamptz, text) to authenticated;

create or replace function public.get_attendance_exceptions(p_location_id uuid, p_period_start date, p_period_end date)
returns table(exception_type text, employee_id uuid, employee_name text, shift_date date, record_id uuid,
              shift_id uuid, clock_in_at timestamptz, clock_out_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_entity_id uuid;
  v_role public.user_role := public.my_role();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  select l.entity_id into v_entity_id from public.locations l where l.id = p_location_id;
  if v_entity_id is null then
    raise exception 'Location % not found', p_location_id;
  end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_entity_id = public.my_entity())
    or (v_role = 'location_manager' and p_location_id = public.my_location())
  ) then
    raise exception 'Not authorized to view attendance for this branch';
  end if;

  return query
  select * from (
    select 'missing_clock_out'::text as exception_type, a.employee_id, e.full_name as employee_name,
           coalesce(s.shift_date, (a.clock_in_at at time zone 'Asia/Dubai')::date) as shift_date,
           a.id as record_id, a.shift_id, a.clock_in_at, a.clock_out_at
    from public.attendance_records a
    join public.employees e on e.id = a.employee_id
    left join public.shifts s on s.id = a.shift_id
    where a.location_id = p_location_id
      and (a.clock_in_at at time zone 'Asia/Dubai')::date between p_period_start and p_period_end
      and a.clock_out_at is null
      and (a.clock_in_at at time zone 'Asia/Dubai')::date < v_today

    union all

    select 'late_clock_in'::text, a.employee_id, e.full_name, s.shift_date, a.id, a.shift_id, a.clock_in_at, a.clock_out_at
    from public.attendance_records a
    join public.employees e on e.id = a.employee_id
    join public.shifts s on s.id = a.shift_id
    cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
    where a.location_id = p_location_id
      and s.shift_date between p_period_start and p_period_end
      and a.clock_in_at > b.planned_start + interval '59 seconds'

    union all

    select 'unmatched_shift'::text, s.employee_id, e.full_name, s.shift_date, null::uuid, s.id, null::timestamptz, null::timestamptz
    from public.shifts s
    join public.employees e on e.id = s.employee_id
    where s.location_id = p_location_id
      and s.is_published = true
      and s.status <> 'cancelled'
      and s.employee_id is not null
      and s.shift_date between p_period_start and p_period_end
      and s.shift_date < v_today
      and not exists (select 1 from public.attendance_records a2 where a2.shift_id = s.id)

    union all

    select 'no_shift_match'::text, a.employee_id, e.full_name, (a.clock_in_at at time zone 'Asia/Dubai')::date,
           a.id, a.shift_id, a.clock_in_at, a.clock_out_at
    from public.attendance_records a
    join public.employees e on e.id = a.employee_id
    where a.location_id = p_location_id
      and (a.clock_in_at at time zone 'Asia/Dubai')::date between p_period_start and p_period_end
      and a.shift_id is null
  ) combined
  order by combined.shift_date desc, combined.employee_name;
end;
$$;
revoke all on function public.get_attendance_exceptions(uuid, date, date) from public, anon;
grant execute on function public.get_attendance_exceptions(uuid, date, date) to authenticated;
