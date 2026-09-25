-- ============================================================
-- W2 Employee clock screen.
--  * clock_in / clock_out: idempotent against double-taps, business
--    date computed in Asia/Dubai (was UTC current_date), shift
--    location used when a shift is matched.
--  * get_my_clock_status(), get_my_attendance(start, end): own
--    records only, employee resolved from auth.uid().
-- Lateness is reported as information only; nothing here (or
-- anywhere) deducts pay automatically.
-- ============================================================

-- Planned start/end of a shift as timestamptz (shift times are Dubai local).
create or replace function public._shift_planned_bounds(p_shift_date date, p_start time, p_end time,
                                                         out planned_start timestamptz, out planned_end timestamptz)
language sql stable
set search_path = ''
as $$
  select (p_shift_date + p_start) at time zone 'Asia/Dubai',
         (p_shift_date + p_end + case when p_end <= p_start then interval '1 day' else interval '0' end) at time zone 'Asia/Dubai';
$$;

revoke all on function public._shift_planned_bounds(date, time, time) from public, anon, authenticated;

create or replace function public.clock_in()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_emp record;
  v_open record;
  v_shift record;
  v_new_id uuid;
  v_now timestamptz := clock_timestamp();
  v_today date := (clock_timestamp() at time zone 'Asia/Dubai')::date;
  v_location uuid;
begin
  select e.id, e.entity_id, e.home_location_id, e.employment_status into v_emp
    from public.employees e where e.id = public.my_employee_id();
  if v_emp.id is null then raise exception 'No employee record is linked to your account'; end if;
  if v_emp.employment_status <> 'active' then raise exception 'Inactive employees cannot clock in'; end if;

  -- Serialise concurrent taps for the same employee.
  perform pg_advisory_xact_lock(hashtextextended('clock:' || v_emp.id::text, 0));

  select a.id, a.shift_id, a.clock_in_at into v_open
    from public.attendance_records a
   where a.employee_id = v_emp.id and a.clock_out_at is null
   order by a.clock_in_at desc limit 1;
  if v_open.id is not null then
    -- Idempotent: a repeat tap returns the already-open record.
    return jsonb_build_object('id', v_open.id, 'shift_id', v_open.shift_id,
                              'clock_in_at', v_open.clock_in_at, 'already_clocked_in', true);
  end if;

  select s.id, s.location_id into v_shift
    from public.shifts s
   where s.employee_id = v_emp.id and s.shift_date = v_today
     and s.status <> 'cancelled' and s.is_published = true
     and not exists (select 1 from public.attendance_records a where a.shift_id = s.id)
   order by s.start_time limit 1;

  v_location := coalesce(v_shift.location_id, v_emp.home_location_id);
  if v_location is null then
    raise exception 'No home location or shift location to clock in at';
  end if;

  insert into public.attendance_records (entity_id, location_id, employee_id, shift_id, clock_in_at)
  values (v_emp.entity_id, v_location, v_emp.id, v_shift.id, v_now)
  returning id into v_new_id;

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', v_new_id, auth.uid(), 'attendance_clock_in',
    jsonb_build_object('shift_id', v_shift.id, 'clock_in_at', v_now), v_emp.entity_id, v_location, v_emp.id);

  return jsonb_build_object('id', v_new_id, 'shift_id', v_shift.id, 'clock_in_at', v_now, 'already_clocked_in', false);
end;
$$;

create or replace function public.clock_out()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_emp_id uuid := public.my_employee_id();
  v_record record;
  v_last record;
  v_now timestamptz := clock_timestamp();
begin
  if v_emp_id is null then raise exception 'No employee record is linked to your account'; end if;

  perform pg_advisory_xact_lock(hashtextextended('clock:' || v_emp_id::text, 0));

  select a.id, a.entity_id, a.location_id, a.clock_in_at into v_record
    from public.attendance_records a
   where a.employee_id = v_emp_id and a.clock_out_at is null
   order by a.clock_in_at desc limit 1
   for update;

  if v_record.id is null then
    -- Idempotent: a repeat tap shortly after clocking out returns that record.
    select a.id, a.clock_out_at into v_last
      from public.attendance_records a
     where a.employee_id = v_emp_id and a.clock_out_at is not null
       and a.clock_out_at > v_now - interval '5 minutes'
     order by a.clock_out_at desc limit 1;
    if v_last.id is not null then
      return jsonb_build_object('id', v_last.id, 'clock_out_at', v_last.clock_out_at, 'already_clocked_out', true);
    end if;
    raise exception 'No open clock-in found to close';
  end if;

  if v_now <= v_record.clock_in_at then v_now := v_record.clock_in_at + interval '1 second'; end if;

  update public.attendance_records set clock_out_at = v_now, updated_at = v_now where id = v_record.id;

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', v_record.id, auth.uid(), 'attendance_clock_out',
    jsonb_build_object('clock_in_at', v_record.clock_in_at, 'clock_out_at', v_now), v_record.entity_id, v_record.location_id, v_emp_id);

  return jsonb_build_object('id', v_record.id, 'clock_out_at', v_now, 'already_clocked_out', false);
end;
$$;

revoke all on function public.clock_in() from public, anon;
revoke all on function public.clock_out() from public, anon;
grant execute on function public.clock_in() to authenticated;
grant execute on function public.clock_out() to authenticated;

-- ------------------------------------------------------------
-- get_my_clock_status
-- ------------------------------------------------------------
create or replace function public.get_my_clock_status()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_emp_id uuid := public.my_employee_id();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_open public.attendance_records;
  v_last public.attendance_records;
  v_shift_id uuid;
  v_state text;
  v_att public.attendance_records;
  v_shift jsonb;
  v_att_json jsonb;
begin
  if v_emp_id is null then
    raise exception 'No employee record is linked to your account' using errcode = '42501';
  end if;

  select * into v_open from public.attendance_records a
   where a.employee_id = v_emp_id and a.clock_out_at is null
   order by a.clock_in_at desc limit 1;

  if v_open.id is not null then
    v_state := 'clocked_in';
    v_att := v_open;
    v_shift_id := v_open.shift_id;
  else
    select s.id into v_shift_id from public.shifts s
     where s.employee_id = v_emp_id and s.shift_date = v_today
       and s.is_published and s.status <> 'cancelled'
       and not exists (select 1 from public.attendance_records a where a.shift_id = s.id)
     order by s.start_time limit 1;

    if v_shift_id is not null then
      v_state := 'not_started';
    else
      select * into v_last from public.attendance_records a
       where a.employee_id = v_emp_id and a.clock_out_at is not null
         and (a.clock_in_at at time zone 'Asia/Dubai')::date = v_today
       order by a.clock_out_at desc limit 1;
      if v_last.id is not null then
        v_state := 'clocked_out';
        v_att := v_last;
        v_shift_id := v_last.shift_id;
      else
        v_state := 'no_shift';
      end if;
    end if;
  end if;

  if v_shift_id is not null then
    select jsonb_build_object(
      'id', s.id,
      'shift_date', s.shift_date,
      'start_time', s.start_time,
      'end_time', s.end_time,
      'planned_start', b.planned_start,
      'planned_end', b.planned_end,
      'location_id', s.location_id,
      'location_name', l.name,
      'position_title', po.title,
      'status', s.status
    ) into v_shift
    from public.shifts s
    cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
    left join public.locations l on l.id = s.location_id
    left join public.positions po on po.id = s.position_id
    where s.id = v_shift_id;
  end if;

  if v_att.id is not null then
    v_att_json := jsonb_build_object(
      'id', v_att.id,
      'shift_id', v_att.shift_id,
      'clock_in_at', v_att.clock_in_at,
      'clock_out_at', v_att.clock_out_at,
      'worked_minutes', case when v_att.clock_out_at is not null
                             then floor(extract(epoch from (v_att.clock_out_at - v_att.clock_in_at)) / 60)::integer end,
      'late_minutes', case when v_shift is not null
                           then greatest(0, floor(extract(epoch from (v_att.clock_in_at - (v_shift->>'planned_start')::timestamptz)) / 60))::integer end,
      'corrected', v_att.corrected
    );
  end if;

  return jsonb_build_object(
    'state', v_state,
    'business_date', v_today,
    'server_time', now(),
    'today_shift', v_shift,
    'attendance', v_att_json
  );
end;
$$;

revoke all on function public.get_my_clock_status() from public, anon;
grant execute on function public.get_my_clock_status() to authenticated;

-- ------------------------------------------------------------
-- get_my_attendance: own attendance + own published shifts in range
-- (business dates, Asia/Dubai). Max 93 days; null bounds default to
-- the last 30 days.
-- status: scheduled | in_progress | completed | missed | unscheduled
-- ------------------------------------------------------------
create or replace function public.get_my_attendance(p_period_start date, p_period_end date)
returns table (
  attendance_id uuid,
  shift_id uuid,
  business_date date,
  location_id uuid,
  location_name text,
  planned_start timestamptz,
  planned_end timestamptz,
  clock_in_at timestamptz,
  clock_out_at timestamptz,
  worked_minutes integer,
  late_minutes integer,
  status text,
  corrected boolean,
  correction_reason text
)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_emp_id uuid := public.my_employee_id();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_start date := coalesce(p_period_start, v_today - 30);
  v_end date := coalesce(p_period_end, v_today);
begin
  if v_emp_id is null then
    raise exception 'No employee record is linked to your account' using errcode = '42501';
  end if;
  if v_end < v_start then
    raise exception 'Period end must not be before period start' using errcode = '22023';
  end if;
  if v_end - v_start > 93 then
    raise exception 'Period cannot exceed 93 days' using errcode = '22023';
  end if;

  return query
  with sh as (
    select s.id, s.shift_date, s.location_id, b.planned_start, b.planned_end
      from public.shifts s
      cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
     where s.employee_id = v_emp_id and s.is_published and s.status <> 'cancelled'
       and s.shift_date between v_start and v_end
  ),
  att as (
    select a.* from public.attendance_records a
     where a.employee_id = v_emp_id
       and ((a.clock_in_at at time zone 'Asia/Dubai')::date between v_start and v_end
            or a.shift_id in (select sh.id from sh))
  )
  select a.id, a.shift_id,
         coalesce(sh.shift_date, (a.clock_in_at at time zone 'Asia/Dubai')::date),
         a.location_id, l.name,
         sh.planned_start, sh.planned_end,
         a.clock_in_at, a.clock_out_at,
         case when a.clock_out_at is not null then floor(extract(epoch from (a.clock_out_at - a.clock_in_at)) / 60)::integer end,
         case when sh.id is not null then greatest(0, floor(extract(epoch from (a.clock_in_at - sh.planned_start)) / 60))::integer end,
         case when a.clock_out_at is null then 'in_progress'
              when sh.id is null then 'unscheduled'
              else 'completed' end,
         a.corrected, a.correction_reason
    from att a
    left join sh on sh.id = a.shift_id
    left join public.locations l on l.id = a.location_id
  union all
  select null::uuid, sh.id, sh.shift_date, sh.location_id, l.name,
         sh.planned_start, sh.planned_end,
         null::timestamptz, null::timestamptz, null::integer, null::integer,
         case when sh.planned_end < now() then 'missed' else 'scheduled' end,
         false, null::text
    from sh
    left join public.locations l on l.id = sh.location_id
   where not exists (select 1 from att a where a.shift_id = sh.id)
  order by 3 desc, 6 nulls last, 8 nulls last;
end;
$$;

revoke all on function public.get_my_attendance(date, date) from public, anon;
grant execute on function public.get_my_attendance(date, date) to authenticated;
