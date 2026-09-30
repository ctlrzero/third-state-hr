-- P1-4: "Can't come in".
-- report_absence: the employee on a published shift (today or later) says they can't come in. Creates a
-- pending one-day leave request for the shift date (normal leave triggers: audit, balance reservation,
-- home-branch manager notice, workflows), records an 'absence_reported' entry in the shift history,
-- and sends a high-priority notice to the managers of the shift's branch (company admins if the branch
-- has no manager). The shift stays assigned until a manager finds cover; cover suggestions stay
-- manager-only (suggest_shift_cover), so the employee is not shown colleagues' availability.
-- get_branch_today now marks those shifts 'absent_reported'.

alter table public.shift_adjustments drop constraint shift_adjustments_change_type_check;
alter table public.shift_adjustments add constraint shift_adjustments_change_type_check check (change_type = any (array[
  'cancelled', 'unpublished', 'reassigned', 'date_changed', 'location_changed', 'time_changed', 'break_changed',
  'deleted', 'absence_reported']));

create or replace function public.report_absence(p_shift_id uuid, p_leave_type_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_emp uuid := public.my_employee_id();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  s record;
  v_lt record;
  v_emp_name text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_request_id uuid;
  v_recipient uuid;
  v_notified int := 0;
  v_when text;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if v_emp is null then
    raise exception using errcode = '42501', message = 'No employee record is linked to your account';
  end if;

  select sh.*, b.planned_end into s
  from public.shifts sh
  cross join lateral public._shift_planned_bounds(sh.shift_date, sh.start_time, sh.end_time) b
  where sh.id = p_shift_id;
  if s.id is null then
    raise exception using errcode = 'P0002', message = 'Shift not found';
  end if;
  if s.employee_id is distinct from v_emp then
    raise exception using errcode = '42501', message = 'You can only report an absence for your own shift';
  end if;
  if not s.is_published or s.status = 'cancelled' then
    raise exception using errcode = '22023', message = 'This shift is not active';
  end if;
  if s.shift_date < v_today or s.planned_end <= now() then
    raise exception using errcode = '22023', message = 'This shift has already ended';
  end if;

  select lt.id, lt.name, lt.entity_id into v_lt from public.leave_types lt where lt.id = p_leave_type_id;
  if v_lt.id is null or v_lt.entity_id is distinct from s.entity_id then
    raise exception using errcode = '22023', message = 'Choose a leave type';
  end if;

  if exists (
    select 1 from public.leave_requests lr
    where lr.employee_id = v_emp and lr.status in ('pending', 'approved')
      and s.shift_date between lr.start_date and lr.end_date
  ) then
    raise exception using errcode = '22023', message = 'You already have a leave request covering this day';
  end if;

  v_when := format('%s %s–%s', to_char(s.shift_date, 'Dy DD Mon'), to_char(s.start_time, 'HH24:MI'), to_char(s.end_time, 'HH24:MI'));

  insert into public.leave_requests (employee_id, leave_type_id, start_date, end_date, days_requested, status, reason)
  values (v_emp, v_lt.id, s.shift_date, s.shift_date, 1, 'pending',
          'Can''t come in for shift ' || v_when || coalesce(' — ' || v_note, ''))
  returning id into v_request_id;

  insert into public.shift_adjustments (shift_id, entity_id, location_id, employee_id, previous_employee_id,
                                        change_type, reason, old_values, new_values, changed_by)
  values (s.id, s.entity_id, s.location_id, v_emp, null, 'absence_reported', coalesce(v_note, v_lt.name),
          jsonb_build_object('shift_date', s.shift_date, 'start_time', s.start_time, 'end_time', s.end_time),
          jsonb_build_object('leave_request_id', v_request_id, 'leave_type', v_lt.name),
          auth.uid());

  select coalesce(e.preferred_name, e.full_name) into v_emp_name from public.employees e where e.id = v_emp;

  for v_recipient in
    select p.id from public.profiles p where p.role = 'location_manager' and p.location_id = s.location_id and p.is_active
  loop
    perform public.create_notification(s.entity_id, v_recipient, null, 'absence_reported',
      'Can''t come in: ' || v_emp_name,
      format('%s can''t make %s (%s). Find cover for the shift and decide the leave request.', v_emp_name, v_when, v_lt.name),
      'shifts', s.id, 'high', 'absence_reported:' || v_request_id || ':' || v_recipient);
    v_notified := v_notified + 1;
  end loop;

  if v_notified = 0 then
    for v_recipient in
      select p.id from public.profiles p where p.role = 'entity_admin' and p.entity_id = s.entity_id and p.is_active
    loop
      perform public.create_notification(s.entity_id, v_recipient, null, 'absence_reported',
        'Can''t come in: ' || v_emp_name,
        format('%s can''t make %s (%s). Find cover for the shift and decide the leave request.', v_emp_name, v_when, v_lt.name),
        'shifts', s.id, 'high', 'absence_reported:' || v_request_id || ':' || v_recipient);
      v_notified := v_notified + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'leave_request_id', v_request_id, 'shift_id', s.id, 'managers_notified', v_notified);
end;
$function$;

revoke all on function public.report_absence(uuid, uuid, text) from public, anon;
grant execute on function public.report_absence(uuid, uuid, text) to authenticated, service_role;
