-- P2-1: Absence cover — offers the manager sends, the employee accepts.
--   * ai_suggestions: every AI suggestion is stored with its inputs, output and model (plan rule for Phase 2).
--   * shift_offers + send_shift_offer / respond_shift_offer / get_my_shift_offers: a manager (or supervisor)
--     offers a published, not-yet-started shift to eligible colleagues; the first to accept gets it.
--     Eligibility (_shift_eligibility) is checked when sending and again when accepting, and the shift must
--     still be as it was (same person, same time) — otherwise the offer closes.
--   * run_no_clock_in_alerts (every 5 min): tells branch managers and supervisors when someone hasn't
--     clocked in 15 minutes after their start and hasn't reported an absence.

create table public.ai_suggestions (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  location_id uuid references public.locations(id),
  kind text not null check (kind in ('cover_offer')),
  target_type text not null,
  target_id uuid not null,
  inputs jsonb not null,
  output jsonb not null,
  model text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index ai_suggestions_target on public.ai_suggestions (target_type, target_id);
alter table public.ai_suggestions enable row level security;
create policy ai_suggestions_select on public.ai_suggestions for select to authenticated using (
  public.my_role() = 'owner'
  or (public.my_role() = 'entity_admin' and entity_id = public.my_entity())
  or (public.my_role() in ('location_manager', 'shift_supervisor') and location_id = public.my_location())
);
revoke insert, update, delete on public.ai_suggestions from anon, authenticated;
grant select on public.ai_suggestions to authenticated;

create table public.shift_offers (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts(id) on delete cascade,
  entity_id uuid not null references public.entities(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  employee_id uuid not null references public.employees(id) on delete cascade,
  replacing_employee_id uuid references public.employees(id),
  message text,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'closed')),
  suggestion_id uuid references public.ai_suggestions(id),
  offered_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  close_reason text
);
create unique index shift_offers_one_pending on public.shift_offers (shift_id, employee_id) where status = 'pending';
create index shift_offers_employee_pending on public.shift_offers (employee_id) where status = 'pending';
alter table public.shift_offers enable row level security;
create policy shift_offers_select on public.shift_offers for select to authenticated using (
  employee_id = public.my_employee_id()
  or public.my_role() = 'owner'
  or (public.my_role() = 'entity_admin' and entity_id = public.my_entity())
  or (public.my_role() in ('location_manager', 'shift_supervisor') and location_id = public.my_location())
);
revoke insert, update, delete on public.shift_offers from anon, authenticated;
grant select on public.shift_offers to authenticated;

-- Who may run cover for a shift's branch.
create or replace function public._can_run_cover(p_entity_id uuid, p_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select public.my_role() = 'owner'
      or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())
      or (public.my_role() in ('location_manager', 'shift_supervisor') and p_location_id = public.my_location());
$function$;
revoke all on function public._can_run_cover(uuid, uuid) from public, anon, authenticated;

-- Called by the cover-assistant Edge Function with the caller's JWT.
create or replace function public.log_ai_suggestion(p_kind text, p_shift_id uuid, p_inputs jsonb, p_output jsonb, p_model text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  s record;
  v_id uuid;
begin
  if auth.uid() is null or public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if p_kind <> 'cover_offer' then
    raise exception using errcode = '22023', message = 'Unknown suggestion kind';
  end if;
  select id, entity_id, location_id into s from public.shifts where id = p_shift_id;
  if s.id is null then
    raise exception using errcode = 'P0002', message = 'Shift not found';
  end if;
  if not public._can_run_cover(s.entity_id, s.location_id) then
    raise exception using errcode = '42501', message = 'Not authorized to find cover for this shift';
  end if;
  insert into public.ai_suggestions (entity_id, location_id, kind, target_type, target_id, inputs, output, model)
  values (s.entity_id, s.location_id, p_kind, 'shifts', s.id, coalesce(p_inputs, '{}'::jsonb), coalesce(p_output, '{}'::jsonb), p_model)
  returning id into v_id;
  return v_id;
end;
$function$;
revoke all on function public.log_ai_suggestion(text, uuid, jsonb, jsonb, text) from public, anon;
grant execute on function public.log_ai_suggestion(text, uuid, jsonb, jsonb, text) to authenticated;

create or replace function public.send_shift_offer(p_shift_id uuid, p_employee_ids uuid[], p_message text, p_suggestion_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  s record;
  v_emp uuid;
  v_reason text;
  v_sent jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_name text;
  v_id uuid;
  v_msg text := nullif(btrim(coalesce(p_message, '')), '');
  v_when text;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select sh.*, b.planned_start, l.name as location_name into s
  from public.shifts sh
  join public.locations l on l.id = sh.location_id
  cross join lateral public._shift_planned_bounds(sh.shift_date, sh.start_time, sh.end_time) b
  where sh.id = p_shift_id;
  if s.id is null then
    raise exception using errcode = 'P0002', message = 'Shift not found';
  end if;
  if not public._can_run_cover(s.entity_id, s.location_id) then
    raise exception using errcode = '42501', message = 'Not authorized to offer this shift';
  end if;
  if not s.is_published or s.status = 'cancelled' then
    raise exception using errcode = '22023', message = 'Only a published, active shift can be offered';
  end if;
  if s.planned_start <= now() then
    raise exception using errcode = '22023', message = 'This shift has already started';
  end if;
  if p_employee_ids is null or cardinality(p_employee_ids) = 0 then
    raise exception using errcode = '22023', message = 'Choose who to offer the shift to';
  end if;
  if length(coalesce(v_msg, '')) > 1000 then
    raise exception using errcode = '22023', message = 'Keep the message under 1000 characters';
  end if;
  if p_suggestion_id is not null and not exists (
    select 1 from public.ai_suggestions a where a.id = p_suggestion_id and a.target_type = 'shifts' and a.target_id = s.id) then
    raise exception using errcode = '22023', message = 'That suggestion is for a different shift';
  end if;

  v_when := format('%s %s–%s at %s', to_char(s.shift_date, 'Dy DD Mon'), to_char(s.start_time, 'HH24:MI'),
                   to_char(s.end_time, 'HH24:MI'), s.location_name);

  foreach v_emp in array p_employee_ids loop
    select coalesce(e.preferred_name, e.full_name) into v_name
    from public.employees e where e.id = v_emp and e.entity_id = s.entity_id;
    if v_name is null then
      v_skipped := v_skipped || jsonb_build_object('employee_id', v_emp, 'reason', 'Not in this company');
      continue;
    end if;
    if v_emp is not distinct from s.employee_id or v_emp is not distinct from public.my_employee_id() then
      v_skipped := v_skipped || jsonb_build_object('employee_id', v_emp, 'name', v_name, 'reason', 'Can''t offer to this person');
      continue;
    end if;
    v_reason := public._shift_eligibility(v_emp, s.id);
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('employee_id', v_emp, 'name', v_name, 'reason', v_reason);
      continue;
    end if;
    if exists (select 1 from public.shift_offers o where o.shift_id = s.id and o.employee_id = v_emp and o.status = 'pending') then
      v_skipped := v_skipped || jsonb_build_object('employee_id', v_emp, 'name', v_name, 'reason', 'Already offered');
      continue;
    end if;
    insert into public.shift_offers (shift_id, entity_id, location_id, employee_id, replacing_employee_id, message, suggestion_id)
    values (s.id, s.entity_id, s.location_id, v_emp, s.employee_id, v_msg, p_suggestion_id)
    returning id into v_id;
    perform public.create_notification(s.entity_id, null, v_emp, 'shift_offer',
      'Can you cover a shift?', coalesce(v_msg, 'Can you cover ' || v_when || '?'),
      'shift_offers', v_id, 'high', 'shift_offer:' || v_id);
    v_sent := v_sent || jsonb_build_object('employee_id', v_emp, 'name', v_name, 'offer_id', v_id);
  end loop;

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('shift_offers', s.id, auth.uid(), 'shift_offer_sent',
          jsonb_build_object('shift_id', s.id, 'sent', v_sent, 'skipped', v_skipped, 'suggestion_id', p_suggestion_id),
          s.entity_id, s.location_id);

  return jsonb_build_object('ok', true, 'sent', v_sent, 'skipped', v_skipped);
end;
$function$;
revoke all on function public.send_shift_offer(uuid, uuid[], text, uuid) from public, anon;
grant execute on function public.send_shift_offer(uuid, uuid[], text, uuid) to authenticated, service_role;

create or replace function public.respond_shift_offer(p_offer_id uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  o public.shift_offers;
  s record;
  v_me uuid := public.my_employee_id();
  v_reason text;
  v_name text;
  v_when text;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select * into o from public.shift_offers where id = p_offer_id for update;
  if o.id is null or o.employee_id is distinct from v_me then
    raise exception using errcode = 'P0002', message = 'Offer not found';
  end if;
  if o.status <> 'pending' then
    raise exception using errcode = '22023', message = case o.status
      when 'accepted' then 'You already accepted this shift'
      when 'declined' then 'You already declined this offer'
      else coalesce('This offer is closed: ' || o.close_reason, 'This offer is closed') end;
  end if;

  select sh.*, b.planned_start into s
  from public.shifts sh
  cross join lateral public._shift_planned_bounds(sh.shift_date, sh.start_time, sh.end_time) b
  where sh.id = o.shift_id for update of sh;

  select coalesce(e.preferred_name, e.full_name) into v_name from public.employees e where e.id = v_me;
  v_when := format('%s %s–%s', to_char(s.shift_date, 'Dy DD Mon'), to_char(s.start_time, 'HH24:MI'), to_char(s.end_time, 'HH24:MI'));

  if not p_accept then
    update public.shift_offers set status = 'declined', responded_at = now() where id = o.id;
    perform public.create_notification(o.entity_id, o.offered_by, null, 'shift_offer_declined',
      v_name || ' can''t cover', format('%s declined the shift on %s.', v_name, v_when),
      'shifts', o.shift_id, 'normal', 'shift_offer_declined:' || o.id);
    return jsonb_build_object('ok', true, 'status', 'declined');
  end if;

  -- The shift must still be what was offered.
  if s.status = 'cancelled' or not s.is_published then
    update public.shift_offers set status = 'closed', close_reason = 'the shift was cancelled', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'status', 'closed', 'message', 'Sorry — this shift was cancelled.');
  end if;
  if s.planned_start <= now() then
    update public.shift_offers set status = 'closed', close_reason = 'the shift has started', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'status', 'closed', 'message', 'Sorry — this shift has already started.');
  end if;
  if s.employee_id is distinct from o.replacing_employee_id then
    update public.shift_offers set status = 'closed', close_reason = 'someone else is covering it', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'status', 'closed', 'message', 'Thanks — someone else is already covering this shift.');
  end if;
  v_reason := public._shift_eligibility(v_me, s.id);
  if v_reason is not null then
    raise exception using errcode = '22023', message = 'You can''t take this shift: ' || v_reason;
  end if;

  perform set_config('app.shift_adjust_reason', 'Cover: shift offer accepted', true);
  update public.shifts set employee_id = v_me where id = s.id;
  perform set_config('app.shift_adjust_reason', '', true);

  update public.shift_offers set status = 'accepted', responded_at = now() where id = o.id;
  update public.shift_offers set status = 'closed', close_reason = 'someone else is covering it', responded_at = now()
  where shift_id = s.id and status = 'pending' and id <> o.id;

  perform public.create_notification(o.entity_id, o.offered_by, null, 'shift_offer_accepted',
    v_name || ' is covering', format('%s accepted the shift on %s. The schedule is updated.', v_name, v_when),
    'shifts', o.shift_id, 'normal', 'shift_offer_accepted:' || o.id);
  if o.replacing_employee_id is not null then
    perform public.create_notification(o.entity_id, null, o.replacing_employee_id, 'shift_covered',
      'Your shift is covered', format('%s is covering your shift on %s.', v_name, v_when),
      null, null, 'normal', 'shift_covered:' || o.id);
  end if;
  return jsonb_build_object('ok', true, 'status', 'accepted');
end;
$function$;
revoke all on function public.respond_shift_offer(uuid, boolean) from public, anon;
grant execute on function public.respond_shift_offer(uuid, boolean) to authenticated, service_role;

create or replace function public.get_my_shift_offers()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'offer_id', o.id, 'shift_id', s.id, 'shift_date', s.shift_date, 'start_time', s.start_time,
           'end_time', s.end_time, 'location', l.name, 'position', p.title, 'message', o.message,
           'created_at', o.created_at)
         order by s.shift_date, s.start_time), '[]'::jsonb)
  from public.shift_offers o
  join public.shifts s on s.id = o.shift_id
  join public.locations l on l.id = s.location_id
  left join public.positions p on p.id = s.position_id
  cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
  where o.employee_id = public.my_employee_id() and o.status = 'pending'
    and s.status <> 'cancelled' and b.planned_start > now();
$function$;
revoke all on function public.get_my_shift_offers() from public, anon;
grant execute on function public.get_my_shift_offers() to authenticated;

-- No clock-in 15 minutes after start (and no absence reported, not on leave): tell the branch.
create or replace function public.run_no_clock_in_alerts()
returns int
language plpgsql
security definer
set search_path to ''
as $function$
declare
  r record;
  v_recipient uuid;
  v_n int := 0;
begin
  for r in
    select s.id, s.entity_id, s.location_id, s.employee_id, s.start_time, coalesce(e.preferred_name, e.full_name) as name
    from public.shifts s
    join public.employees e on e.id = s.employee_id
    cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
    where s.is_published and s.status <> 'cancelled'
      and s.shift_date between (now() at time zone 'Asia/Dubai')::date - 1 and (now() at time zone 'Asia/Dubai')::date
      and b.planned_start between now() - interval '45 minutes' and now() - interval '15 minutes'
      and b.planned_end > now()
      and not exists (select 1 from public.attendance_records a where a.shift_id = s.id)
      and not exists (select 1 from public.attendance_records a
                      where a.employee_id = s.employee_id and a.clock_out_at is null
                        and a.clock_in_at > b.planned_start - interval '2 hours')
      and not exists (select 1 from public.shift_adjustments sa where sa.shift_id = s.id and sa.change_type = 'absence_reported')
      and not exists (select 1 from public.leave_requests lr where lr.employee_id = s.employee_id
                        and lr.status = 'approved' and s.shift_date between lr.start_date and lr.end_date)
  loop
    for v_recipient in
      select p.id from public.profiles p
      where p.is_active and p.role in ('location_manager', 'shift_supervisor') and p.location_id = r.location_id
        and p.id is distinct from (select auth_user_id from public.employees where id = r.employee_id)
    loop
      perform public.create_notification(r.entity_id, v_recipient, null, 'no_clock_in',
        r.name || ' hasn''t clocked in',
        format('%s was due at %s and hasn''t clocked in. Call them, or find cover on the Today board.', r.name, to_char(r.start_time, 'HH24:MI')),
        'shifts', r.id, 'high', 'no_clock_in:' || r.id || ':' || v_recipient);
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end;
$function$;
revoke all on function public.run_no_clock_in_alerts() from public, anon, authenticated;

select cron.schedule('no-clock-in-alerts', '*/5 * * * *', 'select public.run_no_clock_in_alerts();');
