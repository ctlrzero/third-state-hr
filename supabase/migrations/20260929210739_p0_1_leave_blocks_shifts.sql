-- P0-1 (docs/HR_IMPLEMENTATION_PLAN.md): approved leave affects the schedule.
--
-- 1. validate_shift(): a non-cancelled shift cannot be given to someone on
--    approved leave that day (22023).
-- 2. approve_leave_request(): now returns jsonb; on approve it lists the
--    employee's non-cancelled shifts inside the leave as affected_shifts and
--    notifies the branch managers. Shifts are flagged, never auto-cancelled
--    (owner decision #1 default).
-- 3. publish_schedule_period(): now returns jsonb; draft shifts that clash
--    with approved leave are left unpublished and listed in skipped_leave.
-- 4. generate_shifts_from_templates(): skips days the person is on approved
--    leave instead of failing the whole run on the new check.
--
-- The three existing functions keep their search_path (public, pg_temp) and
-- authorisation rules. They also now refuse a caller with no active role
-- (my_role() is null: revoked or no profile) with 42501 — the old
-- `if not (my_role() = ... or ...)` check evaluated to null and let them through.

-- ------------------------------------------------------------ 1. validate_shift
create or replace function public.validate_shift()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  b_start timestamptz;
  b_end timestamptz;
  v_minutes integer;
begin
  if new.status = 'cancelled' then
    return new;
  end if;

  -- Skip unrelated updates (e.g. publishing) when nothing about the plan changed.
  if tg_op = 'UPDATE' and old.status <> 'cancelled'
     and new.shift_date = old.shift_date
     and new.start_time = old.start_time
     and new.end_time = old.end_time
     and new.break_minutes = old.break_minutes
     and new.employee_id is not distinct from old.employee_id then
    return new;
  end if;

  if new.start_time = new.end_time then
    raise exception using errcode = '22023', message = 'Shift start and end time cannot be the same';
  end if;

  select planned_start, planned_end into b_start, b_end
  from public._shift_planned_bounds(new.shift_date, new.start_time, new.end_time);

  v_minutes := (extract(epoch from (b_end - b_start)) / 60)::integer;
  if new.break_minutes >= v_minutes then
    raise exception using errcode = '22023', message = 'Break must be shorter than the shift';
  end if;

  if new.employee_id is not null then
    if exists (
      select 1 from public.leave_requests lr
      where lr.employee_id = new.employee_id
        and lr.status = 'approved'
        and new.shift_date between lr.start_date and lr.end_date
    ) then
      raise exception using errcode = '22023', message = 'This person is on approved leave that day';
    end if;

    perform pg_advisory_xact_lock(hashtext('shift_overlap:' || new.employee_id::text));
    if exists (
      select 1
      from public.shifts s
      cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) sb
      where s.employee_id = new.employee_id
        and s.id <> new.id
        and s.status <> 'cancelled'
        and s.shift_date between new.shift_date - 1 and new.shift_date + 1
        and tstzrange(sb.planned_start, sb.planned_end) && tstzrange(b_start, b_end)
    ) then
      raise exception using errcode = '22023', message = 'This shift overlaps another shift for the same employee';
    end if;
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------ 2. approve_leave_request
drop function public.approve_leave_request(uuid, text, boolean, text);

create function public.approve_leave_request(
  p_request_id uuid, p_action text, p_override boolean default false, p_override_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_employee_id uuid;
  v_employee_name text;
  v_entity_id uuid;
  v_home_location uuid;
  v_leave_type_id uuid;
  v_days numeric;
  v_status text;
  v_balance_reserved boolean;
  v_start date;
  v_end date;
  v_current_balance numeric;
  v_new_balance numeric;
  v_affected jsonb := '[]'::jsonb;
  v_mgr record;
begin
  select lr.employee_id, e.full_name, e.entity_id, e.home_location_id, lr.leave_type_id, lr.days_requested, lr.status,
         lr.balance_reserved, lr.start_date, lr.end_date
    into v_employee_id, v_employee_name, v_entity_id, v_home_location, v_leave_type_id, v_days, v_status,
         v_balance_reserved, v_start, v_end
  from leave_requests lr
  join employees e on e.id = lr.employee_id
  where lr.id = p_request_id;

  if v_employee_id is null then
    raise exception 'Leave request % not found', p_request_id;
  end if;

  if my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized to decide this leave request';
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_home_location = my_location())
  ) then
    raise exception 'Not authorized to decide this leave request';
  end if;

  if v_status <> 'pending' then
    raise exception 'Leave request % is not pending (status: %)', p_request_id, v_status;
  end if;

  if p_action = 'approve' then
    -- Shifts this person still holds inside the leave. Flagged, not cancelled.
    select coalesce(jsonb_agg(jsonb_build_object(
             'shift_id', s.id, 'shift_date', s.shift_date, 'start_time', s.start_time, 'end_time', s.end_time,
             'location_id', s.location_id, 'location', l.name, 'is_published', s.is_published)
             order by s.shift_date, s.start_time), '[]'::jsonb)
      into v_affected
      from shifts s left join locations l on l.id = s.location_id
     where s.employee_id = v_employee_id and s.status <> 'cancelled'
       and s.shift_date between v_start and v_end;

    if v_balance_reserved then
      -- Balance was already held at submission time — approval just
      -- finalizes it. No further balance movement, and no second
      -- leave_balance_used entry (leave_balance_reserved already covers it).
      update leave_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where id = p_request_id;

      insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_approved',
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('status', 'approved', 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'actor_role', my_role(),
                           'balance_was_reserved', true,
                           'affected_shift_ids', (select coalesce(jsonb_agg(a -> 'shift_id'), '[]'::jsonb) from jsonb_array_elements(v_affected) a)),
        v_entity_id, v_home_location, v_employee_id);
    else
      select balance_days into v_current_balance from leave_balances where employee_id = v_employee_id and leave_type_id = v_leave_type_id;

      if coalesce(v_current_balance, 0) < v_days then
        if not p_override then
          raise exception 'Insufficient balance: employee has % day(s) but the request is for % day(s). Reject the request or use an authorised override.',
            coalesce(v_current_balance, 0), v_days;
        end if;
        if not (my_role() = 'owner' or my_role() = 'entity_admin') then
          raise exception 'Only an Owner or Entity Admin may override an insufficient-balance approval';
        end if;
        if p_override_reason is null or length(trim(p_override_reason)) = 0 then
          raise exception 'An override reason is required to approve against an insufficient balance';
        end if;
      end if;

      update leave_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where id = p_request_id;
      update leave_balances set balance_days = balance_days - v_days, updated_at = now()
        where employee_id = v_employee_id and leave_type_id = v_leave_type_id
        returning balance_days into v_new_balance;

      insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_approved',
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('status', 'approved', 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'actor_role', my_role(),
                           'affected_shift_ids', (select coalesce(jsonb_agg(a -> 'shift_id'), '[]'::jsonb) from jsonb_array_elements(v_affected) a)),
        v_entity_id, v_home_location, v_employee_id);

      insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_balance_used',
        jsonb_build_object('balance_days', coalesce(v_current_balance, 0)),
        jsonb_build_object('balance_days', v_new_balance, 'leave_type_id', v_leave_type_id, 'days_used', v_days, 'actor_role', my_role()),
        v_entity_id, v_home_location, v_employee_id);

      if p_override then
        insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
        values ('leave_requests', p_request_id, auth.uid(), 'leave_balance_override_approved',
          jsonb_build_object('balance_days', coalesce(v_current_balance, 0)),
          jsonb_build_object('balance_days', v_new_balance, 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'reason', p_override_reason, 'actor_role', my_role()),
          v_entity_id, v_home_location, v_employee_id);
      end if;
    end if;

    perform public.create_notification(
      v_entity_id, null, v_employee_id, 'leave_approved', 'Leave request approved',
      format('Your leave request for %s day(s) has been approved.', v_days),
      'leave_requests', p_request_id, 'normal', 'leave_decided:' || p_request_id::text
    );

    -- Tell the managers of each affected branch (other than the approver) which shifts need cover.
    for v_mgr in
      select p.id as user_id, count(*) as n
        from jsonb_array_elements(v_affected) a
        join profiles p on p.location_id = (a ->> 'location_id')::uuid
       where p.is_active and p.role = 'location_manager' and p.entity_id = v_entity_id and p.id <> auth.uid()
       group by p.id
    loop
      perform public.create_notification(
        v_entity_id, v_mgr.user_id, null, 'leave_shift_conflict', 'Shift needs cover',
        format('%s has approved leave %s–%s and still holds %s shift(s) at your branch. Reassign or cancel them.',
               v_employee_name, to_char(v_start, 'DD Mon'), to_char(v_end, 'DD Mon'), v_mgr.n),
        'leave_requests', p_request_id, 'high', format('leave_conflict:%s:%s', p_request_id, v_mgr.user_id)
      );
    end loop;

    return jsonb_build_object('ok', true, 'status', 'approved', 'affected_shifts', v_affected);

  elsif p_action = 'reject' then
    update leave_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = p_request_id;

    insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
    values ('leave_requests', p_request_id, auth.uid(), 'leave_rejected',
      jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'rejected', 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'actor_role', my_role()),
      v_entity_id, v_home_location, v_employee_id);

    if v_balance_reserved then
      update leave_balances set balance_days = balance_days + v_days, updated_at = now()
        where employee_id = v_employee_id and leave_type_id = v_leave_type_id
        returning balance_days into v_new_balance;
      update leave_requests set balance_reserved = false where id = p_request_id;

      insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_balance_released',
        jsonb_build_object('leave_type_id', v_leave_type_id, 'days_released', v_days, 'balance_after', v_new_balance, 'reason', 'rejected'),
        v_entity_id, v_home_location, v_employee_id);
    end if;

    perform public.create_notification(
      v_entity_id, null, v_employee_id, 'leave_rejected', 'Leave request rejected',
      format('Your leave request for %s day(s) was rejected.', v_days),
      'leave_requests', p_request_id, 'normal', 'leave_decided:' || p_request_id::text
    );

    return jsonb_build_object('ok', true, 'status', 'rejected', 'affected_shifts', '[]'::jsonb);
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$$;

revoke all on function public.approve_leave_request(uuid, text, boolean, text) from public, anon;
grant execute on function public.approve_leave_request(uuid, text, boolean, text) to authenticated, service_role;

-- ------------------------------------------------------------ 3. publish_schedule_period
drop function public.publish_schedule_period(uuid, date, date);

create function public.publish_schedule_period(p_location_id uuid, p_period_start date, p_period_end date)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_entity_id uuid;
  v_published int;
  v_skipped jsonb;
begin
  select entity_id into v_entity_id from locations where id = p_location_id;
  if v_entity_id is null then raise exception 'Location % not found', p_location_id; end if;

  if my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized to publish schedules for this branch';
  end if;
  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and p_location_id = my_location())
  ) then raise exception 'Not authorized to publish schedules for this branch'; end if;

  if p_period_end < p_period_start then raise exception 'Period end cannot be before period start'; end if;

  -- Drafts that clash with approved leave stay unpublished and are reported.
  select coalesce(jsonb_agg(jsonb_build_object(
           'shift_id', s.id, 'shift_date', s.shift_date, 'start_time', s.start_time, 'end_time', s.end_time,
           'employee_id', s.employee_id, 'employee', e.full_name)
           order by s.shift_date, s.start_time), '[]'::jsonb)
    into v_skipped
    from shifts s join employees e on e.id = s.employee_id
   where s.location_id = p_location_id
     and s.shift_date between p_period_start and p_period_end
     and s.is_published = false and s.status <> 'cancelled'
     and exists (select 1 from leave_requests lr
                  where lr.employee_id = s.employee_id and lr.status = 'approved'
                    and s.shift_date between lr.start_date and lr.end_date);

  update shifts s set is_published = true
    where s.location_id = p_location_id
      and s.shift_date between p_period_start and p_period_end
      and s.is_published = false
      and s.status <> 'cancelled'
      and not exists (select 1 from leave_requests lr
                       where lr.employee_id = s.employee_id and lr.status = 'approved'
                         and s.shift_date between lr.start_date and lr.end_date);

  get diagnostics v_published = row_count;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('shifts', p_location_id, auth.uid(), 'schedule_shifts_published',
    jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end, 'published_count', v_published,
                       'skipped_leave_shift_ids', (select coalesce(jsonb_agg(x -> 'shift_id'), '[]'::jsonb) from jsonb_array_elements(v_skipped) x)),
    v_entity_id, p_location_id);

  return jsonb_build_object('published', v_published, 'skipped_leave', v_skipped);
end;
$$;

revoke all on function public.publish_schedule_period(uuid, date, date) from public, anon;
grant execute on function public.publish_schedule_period(uuid, date, date) to authenticated, service_role;

-- ------------------------------------------------------------ 4. generate_shifts_from_templates
create or replace function public.generate_shifts_from_templates(p_location_id uuid, p_period_start date, p_period_end date)
returns integer
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_entity_id uuid;
  v_generated int;
begin
  select entity_id into v_entity_id from locations where id = p_location_id;
  if v_entity_id is null then raise exception 'Location % not found', p_location_id; end if;

  if my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized to generate shifts for this branch';
  end if;
  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and p_location_id = my_location())
  ) then raise exception 'Not authorized to generate shifts for this branch'; end if;

  if p_period_end < p_period_start then raise exception 'Period end cannot be before period start'; end if;
  if p_period_end - p_period_start > 62 then raise exception 'Period cannot exceed 62 days per generation run'; end if;

  insert into shifts (entity_id, location_id, position_id, employee_id, shift_date, start_time, end_time, break_minutes, status, created_by, is_published, generated_from_template_id)
  select v_entity_id, t.location_id, t.position_id, t.employee_id, gs2.shift_date, t.start_time, t.end_time,
    coalesce(t.break_minutes, 0), 'assigned', auth.uid(), false, t.id
  from schedule_templates t
  cross join lateral generate_series(p_period_start::timestamp, p_period_end::timestamp, interval '1 day') as gs(dt)
  cross join lateral (select gs.dt::date as shift_date) gs2
  where t.location_id = p_location_id
    and t.is_active = true
    and extract(dow from gs.dt) = t.day_of_week
    and gs2.shift_date >= t.effective_start_date
    and (t.effective_end_date is null or gs2.shift_date <= t.effective_end_date)
    and exists (select 1 from employees e where e.id = t.employee_id and e.employment_status = 'active')
    and not exists (
      select 1 from shifts s2 where s2.employee_id = t.employee_id and s2.shift_date = gs2.shift_date and s2.status <> 'cancelled'
    )
    and not exists (
      select 1 from leave_requests lr
       where lr.employee_id = t.employee_id and lr.status = 'approved'
         and gs2.shift_date between lr.start_date and lr.end_date
    )
  on conflict (generated_from_template_id, shift_date) where generated_from_template_id is not null do nothing;

  get diagnostics v_generated = row_count;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('shifts', p_location_id, auth.uid(), 'schedule_shifts_generated',
    jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end, 'generated_count', v_generated),
    v_entity_id, p_location_id);

  return v_generated;
end;
$$;
