-- P1-3: Manager "Today" board.
-- One read for a branch's day: who is scheduled and where they are (upcoming, in, late, not in, done),
-- clock-ins with no shift, missing clock-outs from earlier days, open shifts, people on leave and the
-- approvals waiting on this caller. Scoped exactly like get_attendance_exceptions. No pay data.

create or replace function public.get_branch_today(p_location_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  v_entity_id uuid;
  v_location_name text;
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_people jsonb;
  v_unscheduled jsonb;
  v_missing jsonb;
  v_gaps jsonb;
  v_on_leave jsonb;
  v_drafts int;
  v_pending_leave int;
  v_pending_swaps int;
  v_pending_docs int;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;

  select l.entity_id, l.name into v_entity_id, v_location_name from public.locations l where l.id = p_location_id;
  if v_entity_id is null then
    raise exception using errcode = 'P0002', message = 'Branch not found';
  end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_entity_id = public.my_entity())
    or (v_role = 'location_manager' and p_location_id = public.my_location())
  ) then
    raise exception using errcode = '42501', message = 'Not authorized to view this branch';
  end if;

  -- Today's published, assigned shifts with their attendance.
  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.planned_start, x.name), '[]'::jsonb)
    into v_people
  from (
    select s.id as shift_id, s.employee_id, coalesce(e.preferred_name, e.full_name) as name, e.phone,
           p.title as position, s.start_time, s.end_time, b.planned_start, b.planned_end,
           a.id as attendance_id, a.clock_in_at, a.clock_out_at,
           case when a.clock_in_at > b.planned_start + interval '59 seconds'
                then floor(extract(epoch from a.clock_in_at - b.planned_start) / 60)::int
                when a.id is null and v_now > b.planned_start + interval '59 seconds' and v_now < b.planned_end
                then floor(extract(epoch from v_now - b.planned_start) / 60)::int
                else 0 end as late_minutes,
           case when a.id is not null and a.clock_out_at is not null then 'done'
                when a.id is not null and a.clock_in_at > b.planned_start + interval '59 seconds' then 'in_late'
                when a.id is not null then 'in'
                when v_now >= b.planned_end then 'no_show'
                when v_now > b.planned_start + interval '59 seconds' then 'not_in'
                else 'upcoming' end as status
    from public.shifts s
    join public.employees e on e.id = s.employee_id
    left join public.positions p on p.id = s.position_id
    cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
    left join lateral (
      select ar.id, ar.clock_in_at, ar.clock_out_at from public.attendance_records ar
      where ar.shift_id = s.id order by ar.clock_in_at desc limit 1
    ) a on true
    where s.location_id = p_location_id and s.shift_date = v_today
      and s.is_published and s.status <> 'cancelled'
  ) x;

  -- Clocked in today at this branch without a shift.
  select coalesce(jsonb_agg(jsonb_build_object(
           'attendance_id', a.id, 'employee_id', a.employee_id,
           'name', coalesce(e.preferred_name, e.full_name), 'clock_in_at', a.clock_in_at, 'clock_out_at', a.clock_out_at)
         order by a.clock_in_at), '[]'::jsonb)
    into v_unscheduled
  from public.attendance_records a
  join public.employees e on e.id = a.employee_id
  where a.location_id = p_location_id and a.shift_id is null
    and (a.clock_in_at at time zone 'Asia/Dubai')::date = v_today;

  -- Still clocked in from an earlier day (last 14 days).
  select coalesce(jsonb_agg(jsonb_build_object(
           'attendance_id', a.id, 'employee_id', a.employee_id,
           'name', coalesce(e.preferred_name, e.full_name),
           'business_date', (a.clock_in_at at time zone 'Asia/Dubai')::date, 'clock_in_at', a.clock_in_at)
         order by a.clock_in_at), '[]'::jsonb)
    into v_missing
  from public.attendance_records a
  join public.employees e on e.id = a.employee_id
  where a.location_id = p_location_id and a.clock_out_at is null
    and (a.clock_in_at at time zone 'Asia/Dubai')::date between v_today - 14 and v_today - 1;

  -- Open (unassigned) shifts today that haven't ended.
  select coalesce(jsonb_agg(jsonb_build_object(
           'shift_id', s.id, 'position', p.title, 'start_time', s.start_time, 'end_time', s.end_time,
           'is_published', s.is_published)
         order by s.start_time), '[]'::jsonb)
    into v_gaps
  from public.shifts s
  left join public.positions p on p.id = s.position_id
  cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
  where s.location_id = p_location_id and s.shift_date = v_today
    and s.employee_id is null and s.status <> 'cancelled' and b.planned_end > v_now;

  -- Home-branch staff on approved leave today.
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', e.id, 'name', coalesce(e.preferred_name, e.full_name),
           'leave_type', lt.name, 'end_date', lr.end_date)
         order by e.full_name), '[]'::jsonb)
    into v_on_leave
  from public.leave_requests lr
  join public.employees e on e.id = lr.employee_id
  left join public.leave_types lt on lt.id = lr.leave_type_id
  where e.home_location_id = p_location_id and lr.status = 'approved'
    and v_today between lr.start_date and lr.end_date;

  select count(*) into v_drafts
  from public.shifts s
  where s.location_id = p_location_id and s.shift_date = v_today
    and not s.is_published and s.status <> 'cancelled';

  -- Approvals this caller can act on for this branch.
  select count(*) into v_pending_leave
  from public.leave_requests lr
  join public.employees e on e.id = lr.employee_id
  where e.home_location_id = p_location_id and lr.status = 'pending';

  select count(*) into v_pending_swaps
  from public.shift_swap_requests ss
  join public.shifts s on s.id = ss.shift_id
  where s.location_id = p_location_id and ss.status = 'claimed' and ss.claimed_by is not null;

  select count(*) into v_pending_docs
  from public.employee_documents d
  join public.employees e on e.id = d.employee_id
  where e.home_location_id = p_location_id and d.review_status = 'pending_review'
    and public.can_review_document(d.submitted_by, auth.uid(), d.doc_type);

  return jsonb_build_object(
    'location_id', p_location_id,
    'location_name', v_location_name,
    'date', v_today,
    'generated_at', v_now,
    'people', v_people,
    'unscheduled', v_unscheduled,
    'missing_clock_outs', v_missing,
    'open_gaps', v_gaps,
    'on_leave', v_on_leave,
    'draft_shifts', v_drafts,
    'approvals', jsonb_build_object('leave', v_pending_leave, 'swaps', v_pending_swaps, 'documents', v_pending_docs)
  );
end;
$function$;

revoke all on function public.get_branch_today(uuid) from public, anon;
grant execute on function public.get_branch_today(uuid) to authenticated, service_role;
