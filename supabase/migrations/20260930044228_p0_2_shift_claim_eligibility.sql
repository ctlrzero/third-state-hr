-- P0-2 (docs/HR_IMPLEMENTATION_PLAN.md): swaps and open-shift claims respect eligibility.
--
-- 1. _shift_eligibility(employee, shift) -> null when eligible, else a plain reason.
--    Same rules the auto-scheduler uses: same company, active and employed on the
--    day, role matches, not on approved leave, not a fixed day off, available,
--    no overlap, <= 48 working hours and <= their weekly days (work pattern,
--    default 6) in the Mon-Sun week.
-- 2. Cross-outlet claims: off by default; the owner switches it on per company
--    (app_settings key 'cross_outlet_claims:<entity_id>'). When on, staff can see
--    and claim open shifts / open swaps at any branch of their own company.
--    Approval stays with the shift's branch manager or an admin.
-- 3. claim_open_shift, claim_shift_swap, approve_shift_swap use the eligibility
--    check (22023 with the reason). claim_open_shift also requires the shift to
--    be published (staff could previously claim an unpublished open shift by id).
-- 4. suggest_shift_cover(shift) -> ranked eligible people for managers/admins.

-- ------------------------------------------------------------ settings
create or replace function public._cross_outlet_claims_enabled(p_entity_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((select s.value from public.app_settings s where s.key = 'cross_outlet_claims:' || p_entity_id::text), false);
$$;
revoke all on function public._cross_outlet_claims_enabled(uuid) from public, anon;
grant execute on function public._cross_outlet_claims_enabled(uuid) to authenticated;

create or replace function public.set_cross_outlet_claims(p_entity_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_old boolean;
begin
  if public.my_role() is distinct from 'owner' then
    raise exception using errcode = '42501', message = 'Only the owner can change cross-branch shift claims';
  end if;
  if not exists (select 1 from public.entities where id = p_entity_id) then
    raise exception using errcode = 'P0002', message = 'Company not found';
  end if;
  v_old := public._cross_outlet_claims_enabled(p_entity_id);
  insert into public.app_settings (key, value, updated_by, updated_at)
  values ('cross_outlet_claims:' || p_entity_id::text, coalesce(p_enabled, false), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id)
  values ('app_settings', p_entity_id, auth.uid(), 'cross_outlet_claims_set',
    jsonb_build_object('enabled', v_old), jsonb_build_object('enabled', coalesce(p_enabled, false)), p_entity_id);
end;
$$;
revoke all on function public.set_cross_outlet_claims(uuid, boolean) from public, anon;
grant execute on function public.set_cross_outlet_claims(uuid, boolean) to authenticated;

-- ------------------------------------------------------------ eligibility
create or replace function public._shift_eligibility(p_employee_id uuid, p_shift_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  s record;
  e record;
  wp public.employee_work_patterns;
  v_dow int;
  b_start timestamptz;
  b_end timestamptz;
  v_minutes int;
  v_week_minutes int;
  v_week_days int;
  v_names text[] := array['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  v_title text;
begin
  select * into s from public.shifts where id = p_shift_id;
  if s.id is null then return 'Shift not found'; end if;
  if s.status = 'cancelled' then return 'This shift is cancelled'; end if;

  select * into e from public.employees where id = p_employee_id;
  if e.id is null then return 'Employee not found'; end if;
  if e.entity_id <> s.entity_id then return 'Works for a different company'; end if;
  if e.employment_status <> 'active' then return 'Not an active employee'; end if;
  if e.join_date is not null and e.join_date > s.shift_date then return 'Has not started yet on that day'; end if;
  if e.last_working_date is not null and e.last_working_date < s.shift_date then return 'Has left before that day'; end if;

  if s.position_id is not null and e.position_id is distinct from s.position_id then
    select title into v_title from public.positions where id = s.position_id;
    return format('Role does not match: this shift needs %s', coalesce(v_title, 'a different role'));
  end if;

  if exists (select 1 from public.leave_requests lr
              where lr.employee_id = e.id and lr.status = 'approved' and s.shift_date between lr.start_date and lr.end_date) then
    return 'On approved leave that day';
  end if;

  v_dow := extract(dow from s.shift_date)::int;
  select * into wp from public.employee_work_patterns where employee_id = e.id;
  if wp.employee_id is not null and wp.days_off_mode = 'fixed' and v_dow = any(wp.fixed_days_off) then
    return format('%s is a fixed day off', v_names[v_dow + 1]);
  end if;

  if exists (select 1 from public.employee_availability a where a.employee_id = e.id)
     and not exists (select 1 from public.employee_availability a
                      where a.employee_id = e.id and a.day_of_week = v_dow and a.is_available
                        and (a.start_time is null or a.start_time <= s.start_time)
                        and (a.end_time is null or (s.end_time > s.start_time and s.end_time <= a.end_time))) then
    return format('Not available at that time on %s', v_names[v_dow + 1]);
  end if;

  select planned_start, planned_end into b_start, b_end
    from public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time);
  v_minutes := (extract(epoch from (b_end - b_start)) / 60)::int - coalesce(s.break_minutes, 0);

  if exists (select 1 from public.shifts o
              cross join lateral public._shift_planned_bounds(o.shift_date, o.start_time, o.end_time) ob
              where o.employee_id = e.id and o.id <> s.id and o.status <> 'cancelled'
                and o.shift_date between s.shift_date - 1 and s.shift_date + 1
                and tstzrange(ob.planned_start, ob.planned_end) && tstzrange(b_start, b_end)) then
    return 'Already working another shift at that time';
  end if;

  select coalesce(sum((extract(epoch from (ob.planned_end - ob.planned_start)) / 60)::int - coalesce(o.break_minutes, 0)), 0),
         count(distinct o.shift_date)
    into v_week_minutes, v_week_days
    from public.shifts o
    cross join lateral public._shift_planned_bounds(o.shift_date, o.start_time, o.end_time) ob
   where o.employee_id = e.id and o.id <> s.id and o.status <> 'cancelled'
     and date_trunc('week', o.shift_date) = date_trunc('week', s.shift_date);

  if v_week_minutes + v_minutes > 2880 then
    return format('Would go over 48 working hours that week (already %s h)', round(v_week_minutes / 60.0, 1));
  end if;

  if not exists (select 1 from public.shifts o
                  where o.employee_id = e.id and o.id <> s.id and o.status <> 'cancelled' and o.shift_date = s.shift_date) then
    v_week_days := v_week_days + 1;
  end if;
  if v_week_days > coalesce(wp.days_per_week, 6) then
    return format('Would go over %s working days that week', coalesce(wp.days_per_week, 6));
  end if;

  return null;
end;
$$;
revoke all on function public._shift_eligibility(uuid, uuid) from public, anon, authenticated;
grant execute on function public._shift_eligibility(uuid, uuid) to service_role;

-- ------------------------------------------------------------ claims
create or replace function public.claim_open_shift(p_shift_id uuid)
returns void
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_shift record;
  v_reason text;
begin
  select id, employee_id, status, location_id, entity_id, is_published into v_shift from public.shifts where id = p_shift_id;

  if v_shift.id is null then raise exception 'Shift % not found', p_shift_id; end if;
  if v_shift.status <> 'open' or v_shift.employee_id is not null then raise exception 'This shift is no longer open'; end if;
  if not v_shift.is_published then raise exception using errcode = '22023', message = 'This shift is not open for pick-up yet'; end if;
  if not is_active_employee(my_employee_id()) then raise exception 'Inactive employees cannot pick up shifts'; end if;
  if v_shift.location_id <> my_home_location() and not public._cross_outlet_claims_enabled(v_shift.entity_id) then
    raise exception using errcode = '22023', message = 'You can only pick up open shifts at your own branch';
  end if;

  v_reason := public._shift_eligibility(my_employee_id(), p_shift_id);
  if v_reason is not null then
    raise exception using errcode = '22023', message = 'You can''t take this shift: ' || v_reason;
  end if;

  update public.shifts set employee_id = my_employee_id(), status = 'assigned' where id = p_shift_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shifts', p_shift_id, auth.uid(), 'shift_claimed',
    jsonb_build_object('employee_id', my_employee_id(), 'cross_branch', v_shift.location_id <> my_home_location()),
    v_shift.entity_id, v_shift.location_id, my_employee_id());
end;
$$;

create or replace function public.claim_shift_swap(p_swap_id uuid)
returns void
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_swap record;
  v_shift record;
  v_reason text;
begin
  select id, shift_id, requested_by, claimed_by, status into v_swap from public.shift_swap_requests where id = p_swap_id;

  if v_swap.id is null then raise exception 'Swap request % not found', p_swap_id; end if;
  if v_swap.status <> 'open' or v_swap.claimed_by is not null then raise exception 'This swap request is no longer open'; end if;
  if v_swap.requested_by = my_employee_id() then raise exception 'You cannot claim your own swap request'; end if;
  if not is_active_employee(my_employee_id()) then raise exception 'Inactive employees cannot claim shift swaps'; end if;

  select id, location_id, status, entity_id into v_shift from public.shifts where id = v_swap.shift_id;

  if v_shift.status = 'cancelled' then raise exception 'Cannot claim a swap for a cancelled shift'; end if;
  if v_shift.location_id <> my_home_location() and not public._cross_outlet_claims_enabled(v_shift.entity_id) then
    raise exception using errcode = '22023', message = 'You can only claim shift swaps at your own branch';
  end if;

  v_reason := public._shift_eligibility(my_employee_id(), v_swap.shift_id);
  if v_reason is not null then
    raise exception using errcode = '22023', message = 'You can''t take this shift: ' || v_reason;
  end if;

  update public.shift_swap_requests set claimed_by = my_employee_id(), status = 'claimed' where id = p_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_claimed',
    jsonb_build_object('shift_id', v_swap.shift_id, 'cross_branch', v_shift.location_id <> my_home_location()),
    v_shift.entity_id, v_shift.location_id, my_employee_id());

  perform public.create_notification(
    v_shift.entity_id, null, v_swap.requested_by, 'swap_claimed', 'Your shift swap was claimed',
    'Someone has claimed your open shift swap request.', 'shift_swap_requests', p_swap_id, 'normal',
    'swap_claimed:' || p_swap_id::text
  );
end;
$$;

create or replace function public.approve_shift_swap(p_swap_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_shift_id uuid;
  v_requested_by uuid;
  v_claimed_by uuid;
  v_entity_id uuid;
  v_location_id uuid;
  v_reason text;
  v_name text;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select ss.shift_id, ss.requested_by, ss.claimed_by, s.entity_id, s.location_id
    into v_shift_id, v_requested_by, v_claimed_by, v_entity_id, v_location_id
  from shift_swap_requests ss
  join shifts s on s.id = ss.shift_id
  where ss.id = p_swap_id;

  if v_shift_id is null then
    raise exception 'Swap request % not found', p_swap_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then
    raise exception 'Not authorized to decide this swap request';
  end if;

  if p_action = 'approve' then
    if v_claimed_by is null then
      raise exception 'This swap has not been claimed by anyone yet';
    end if;
    -- Re-check at approval: leave, hours or availability may have changed since the claim.
    v_reason := public._shift_eligibility(v_claimed_by, v_shift_id);
    if v_reason is not null then
      select full_name into v_name from employees where id = v_claimed_by;
      raise exception using errcode = '22023', message = format('Cannot approve: %s — %s', coalesce(v_name, 'the claimant'), v_reason);
    end if;
    update shifts set employee_id = v_claimed_by where id = v_shift_id;
    update shift_swap_requests set status = 'approved', resolved_by = auth.uid(), resolved_at = now() where id = p_swap_id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_approved',
      jsonb_build_object('shift_id', v_shift_id, 'from_employee_id', v_requested_by, 'to_employee_id', v_claimed_by),
      v_entity_id, v_location_id, v_claimed_by);

    perform public.create_notification(v_entity_id, null, v_requested_by, 'swap_approved', 'Shift swap approved',
      'Your shift swap request has been approved.', 'shift_swap_requests', p_swap_id, 'normal', 'swap_decided:' || p_swap_id::text || ':requester');
    perform public.create_notification(v_entity_id, null, v_claimed_by, 'swap_approved', 'Shift swap approved',
      'The shift swap you claimed has been approved.', 'shift_swap_requests', p_swap_id, 'normal', 'swap_decided:' || p_swap_id::text || ':claimant');
  elsif p_action = 'reject' then
    update shift_swap_requests set status = 'rejected', resolved_by = auth.uid(), resolved_at = now() where id = p_swap_id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_rejected',
      jsonb_build_object('shift_id', v_shift_id), v_entity_id, v_location_id, v_requested_by);

    perform public.create_notification(v_entity_id, null, v_requested_by, 'swap_rejected', 'Shift swap rejected',
      'Your shift swap request was rejected.', 'shift_swap_requests', p_swap_id, 'normal', 'swap_decided:' || p_swap_id::text || ':requester');
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$$;

-- ------------------------------------------------------------ find cover
create or replace function public.suggest_shift_cover(p_shift_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  s record;
  v_candidates jsonb;
  v_not jsonb;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select sh.*, l.name as location_name, p.title as position_title
    into s
    from public.shifts sh
    left join public.locations l on l.id = sh.location_id
    left join public.positions p on p.id = sh.position_id
   where sh.id = p_shift_id;
  if s.id is null then raise exception using errcode = 'P0002', message = 'Shift not found'; end if;
  if not (public.my_role() = 'owner'
          or (public.my_role() = 'entity_admin' and s.entity_id = public.my_entity())
          or (public.my_role() = 'location_manager' and s.location_id = public.my_location())) then
    raise exception using errcode = '42501', message = 'Not authorized to find cover for this shift';
  end if;

  with people as (
    select e.id, e.full_name, e.home_location_id, hl.name as home_location, ps.title as position,
           public._shift_eligibility(e.id, s.id) as reason,
           coalesce((select sum((extract(epoch from (ob.planned_end - ob.planned_start)) / 60)::int - coalesce(o.break_minutes, 0))
                       from public.shifts o
                       cross join lateral public._shift_planned_bounds(o.shift_date, o.start_time, o.end_time) ob
                      where o.employee_id = e.id and o.status <> 'cancelled' and o.id <> s.id
                        and date_trunc('week', o.shift_date) = date_trunc('week', s.shift_date)), 0) as week_minutes,
           (select count(distinct o.shift_date) from public.shifts o
             where o.employee_id = e.id and o.status <> 'cancelled' and o.id <> s.id
               and date_trunc('week', o.shift_date) = date_trunc('week', s.shift_date)) as week_days
      from public.employees e
      left join public.locations hl on hl.id = e.home_location_id
      left join public.positions ps on ps.id = e.position_id
     where e.entity_id = s.entity_id and e.employment_status = 'active'
       and e.id is distinct from s.employee_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', id, 'name', full_name, 'home_location', home_location, 'position', position,
           'home_branch', home_location_id = s.location_id,
           'hours_this_week', round(week_minutes / 60.0, 1), 'days_this_week', week_days)
           order by (home_location_id = s.location_id) desc, week_minutes, full_name)
           filter (where reason is null), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('employee_id', id, 'name', full_name, 'reason', reason)
           order by full_name) filter (where reason is not null), '[]'::jsonb)
    into v_candidates, v_not
    from people;

  return jsonb_build_object(
    'shift', jsonb_build_object('id', s.id, 'shift_date', s.shift_date, 'start_time', s.start_time, 'end_time', s.end_time,
                                'location_id', s.location_id, 'location', s.location_name, 'position', s.position_title,
                                'employee_id', s.employee_id, 'is_published', s.is_published, 'status', s.status),
    'candidates', v_candidates,
    'not_eligible', v_not);
end;
$$;
revoke all on function public.suggest_shift_cover(uuid) from public, anon;
grant execute on function public.suggest_shift_cover(uuid) to authenticated;

-- ------------------------------------------------------------ staff visibility of open shifts and swaps
-- Helpers are SECURITY DEFINER so the policies below never read the other
-- table through its own RLS (which would recurse between shifts and
-- shift_swap_requests).
create or replace function public._staff_can_claim_at(p_entity_id uuid, p_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select p_location_id = public.my_home_location()
      or (p_entity_id = (select e.entity_id from public.employees e where e.id = public.my_employee_id())
          and public._cross_outlet_claims_enabled(p_entity_id));
$$;
revoke all on function public._staff_can_claim_at(uuid, uuid) from public, anon;
grant execute on function public._staff_can_claim_at(uuid, uuid) to authenticated;

create or replace function public._open_swap_in_staff_scope(p_shift_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.shifts s
     where s.id = p_shift_id and s.status <> 'cancelled' and s.is_published
       and exists (select 1 from public.shift_swap_requests r where r.shift_id = s.id and r.status = 'open')
       and public._staff_can_claim_at(s.entity_id, s.location_id));
$$;
revoke all on function public._open_swap_in_staff_scope(uuid) from public, anon;
grant execute on function public._open_swap_in_staff_scope(uuid) to authenticated;

alter policy shifts_select on public.shifts using (
  (( select public.my_role() ) = 'owner'::public.user_role)
  or ((( select public.my_role() ) = 'entity_admin'::public.user_role) and (entity_id = ( select public.my_entity() )))
  or ((( select public.my_role() ) = 'location_manager'::public.user_role) and (location_id = ( select public.my_location() )))
  or ((employee_id = ( select public.my_employee_id() )) and (is_published = true))
  or ((status = 'open'::text) and (is_published = true) and public._staff_can_claim_at(entity_id, location_id))
  or ((is_published = true) and public._open_swap_in_staff_scope(id))
);

alter policy swaps_select on public.shift_swap_requests using (
  (requested_by = public.my_employee_id())
  or (claimed_by = public.my_employee_id())
  or ((status = 'open'::text) and public._open_swap_in_staff_scope(shift_id))
  or (public.my_role() = 'owner'::public.user_role)
  or ((public.my_role() = 'entity_admin'::public.user_role) and (exists (select 1 from public.shifts s
        where s.id = shift_swap_requests.shift_id and s.entity_id = public.my_entity())))
  or ((public.my_role() = 'location_manager'::public.user_role) and (exists (select 1 from public.shifts s
        where s.id = shift_swap_requests.shift_id and s.location_id = public.my_location())))
);
