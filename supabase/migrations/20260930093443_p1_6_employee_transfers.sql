-- P1-6: Transfer workflow (same company only).
-- transfer_employee schedules (or, for today, applies) a move of an employee's home branch. It returns what
-- the manager must review: future shifts still at the old branch, recurring templates there, and the
-- employee's availability / work pattern. Nothing is cancelled or deleted automatically.
-- A nightly job (00:05 Dubai) applies transfers that are due. Cross-company moves are refused:
-- offboard and onboard instead. Audited before/after in audit_log.

create table public.employee_transfers (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  from_location_id uuid references public.locations(id),
  to_location_id uuid not null references public.locations(id),
  effective_date date not null,
  reason text not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'completed', 'cancelled')),
  requested_by uuid,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancellation_reason text
);
create unique index employee_transfers_one_scheduled on public.employee_transfers (employee_id) where status = 'scheduled';
create index employee_transfers_due on public.employee_transfers (effective_date) where status = 'scheduled';

alter table public.employee_transfers enable row level security;
create policy employee_transfers_select on public.employee_transfers for select to authenticated using (
  public.my_role() = 'owner'
  or (public.my_role() = 'entity_admin' and entity_id = public.my_entity())
  or (public.my_role() = 'location_manager' and public.my_location() in (from_location_id, to_location_id))
);
revoke insert, update, delete on public.employee_transfers from anon, authenticated;
grant select on public.employee_transfers to authenticated;

-- Let a transfer move a *staff* login's branch (only the branch) — nothing else changes this way.
do $patch$
declare
  v_def text := pg_get_functiondef('public.enforce_profile_role_change_authority()'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    $a$    select p.role, p.entity_id into v_actor_role, v_actor_entity$a$,
    $a$    if current_setting('app.employee_transfer', true) = 'on'
       and old.role = 'staff' and new.role = old.role and new.entity_id is not distinct from old.entity_id
       and new.is_active is not distinct from old.is_active then
      return new;
    end if;
    select p.role, p.entity_id into v_actor_role, v_actor_entity$a$);
  if v_new = v_def then
    raise exception 'enforce_profile_role_change_authority patch point not found';
  end if;
  execute v_new;
end
$patch$;

-- What to review for a transfer (read-only).
create or replace function public._transfer_review(p_employee_id uuid, p_from_location_id uuid, p_effective_date date)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object('shift_id', s.id, 'shift_date', s.shift_date, 'start_time', s.start_time,
               'end_time', s.end_time, 'is_published', s.is_published) order by s.shift_date, s.start_time)
      from public.shifts s
      where s.employee_id = p_employee_id and s.location_id = p_from_location_id
        and s.shift_date >= p_effective_date and s.status <> 'cancelled'), '[]'::jsonb),
    'templates', coalesce((
      select jsonb_agg(jsonb_build_object('template_id', t.id, 'day_of_week', t.day_of_week, 'start_time', t.start_time,
               'end_time', t.end_time) order by t.day_of_week, t.start_time)
      from public.schedule_templates t
      where t.employee_id = p_employee_id and t.location_id = p_from_location_id and t.is_active
        and (t.effective_end_date is null or t.effective_end_date >= p_effective_date)), '[]'::jsonb),
    'availability', coalesce((
      select jsonb_agg(jsonb_build_object('day_of_week', a.day_of_week, 'is_available', a.is_available,
               'start_time', a.start_time, 'end_time', a.end_time) order by a.day_of_week)
      from public.employee_availability a where a.employee_id = p_employee_id), '[]'::jsonb),
    'work_pattern', (
      select jsonb_build_object('days_per_week', w.days_per_week, 'days_off_mode', w.days_off_mode, 'fixed_days_off', w.fixed_days_off)
      from public.employee_work_patterns w where w.employee_id = p_employee_id)
  );
$function$;
revoke all on function public._transfer_review(uuid, uuid, date) from public, anon, authenticated;

-- Applies one scheduled transfer. Internal: called by transfer_employee (effective today) and the nightly job.
create or replace function public._apply_employee_transfer(p_transfer_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  t record;
  v_old_home uuid;
  v_auth uuid;
  v_to_name text;
  v_recipient uuid;
begin
  select * into t from public.employee_transfers where id = p_transfer_id and status = 'scheduled' for update;
  if t.id is null then return; end if;

  select e.home_location_id, e.auth_user_id into v_old_home, v_auth from public.employees e where e.id = t.employee_id for update;
  select l.name into v_to_name from public.locations l where l.id = t.to_location_id;

  update public.employees set home_location_id = t.to_location_id where id = t.employee_id;

  perform set_config('app.employee_transfer', 'on', true);
  update public.profiles set location_id = t.to_location_id
  where id = v_auth and role = 'staff' and location_id is distinct from t.to_location_id;
  perform set_config('app.employee_transfer', '', true);

  update public.employee_transfers set status = 'completed', completed_at = now() where id = t.id;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('employee_transfers', t.id, auth.uid(), 'employee_transferred',
          jsonb_build_object('home_location_id', v_old_home),
          jsonb_build_object('home_location_id', t.to_location_id, 'effective_date', t.effective_date, 'reason', t.reason),
          t.entity_id, t.to_location_id, t.employee_id);

  perform public.create_notification(t.entity_id, null, t.employee_id, 'employee_transferred',
    'Your home branch has changed',
    format('From %s your home branch is %s.', to_char(t.effective_date, 'Dy DD Mon YYYY'), v_to_name),
    null, null, 'normal', 'employee_transferred:' || t.id);

  for v_recipient in
    select p.id from public.profiles p
    where p.role = 'location_manager' and p.is_active and p.location_id = t.to_location_id
  loop
    perform public.create_notification(t.entity_id, v_recipient, null, 'employee_transferred',
      'New team member',
      format('%s now belongs to %s. Check their availability and add them to the schedule.',
             (select coalesce(e.preferred_name, e.full_name) from public.employees e where e.id = t.employee_id), v_to_name),
      'employees', t.employee_id, 'normal', 'employee_transferred:' || t.id || ':' || v_recipient);
  end loop;
end;
$function$;
revoke all on function public._apply_employee_transfer(uuid) from public, anon, authenticated;

create or replace function public.transfer_employee(
  p_employee_id uuid, p_new_home_location_id uuid, p_effective_date date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  e record;
  v_to record;
  v_id uuid;
  v_status text := 'scheduled';
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_recipient uuid;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;

  select emp.id, emp.entity_id, emp.home_location_id, emp.employment_status, coalesce(emp.preferred_name, emp.full_name) as name
    into e from public.employees emp where emp.id = p_employee_id;
  if e.id is null then
    raise exception using errcode = 'P0002', message = 'Employee not found';
  end if;
  if not (v_role = 'owner' or (v_role = 'entity_admin' and e.entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'Only the owner or a company admin can transfer an employee';
  end if;

  select l.id, l.entity_id, l.name into v_to from public.locations l where l.id = p_new_home_location_id;
  if v_to.id is null then
    raise exception using errcode = 'P0002', message = 'Branch not found';
  end if;
  if v_to.entity_id <> e.entity_id then
    raise exception using errcode = '22023',
      message = 'Transfers are within the same company. To move someone to another company, offboard and onboard them.';
  end if;
  if e.home_location_id = v_to.id then
    raise exception using errcode = '22023', message = format('%s is already at %s', e.name, v_to.name);
  end if;
  if e.employment_status = 'inactive' then
    raise exception using errcode = '22023', message = 'This employee is inactive';
  end if;
  if v_reason is null then
    raise exception using errcode = '22023', message = 'Give a reason for the transfer';
  end if;
  if p_effective_date is null or p_effective_date < v_today then
    raise exception using errcode = '22023', message = 'The transfer date can''t be in the past';
  end if;
  if exists (select 1 from public.employee_transfers where employee_id = e.id and status = 'scheduled') then
    raise exception using errcode = '22023', message = 'A transfer is already scheduled for this employee — cancel it first';
  end if;

  insert into public.employee_transfers (entity_id, employee_id, from_location_id, to_location_id, effective_date, reason, requested_by)
  values (e.entity_id, e.id, e.home_location_id, v_to.id, p_effective_date, v_reason, auth.uid())
  returning id into v_id;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('employee_transfers', v_id, auth.uid(), 'employee_transfer_scheduled',
          jsonb_build_object('home_location_id', e.home_location_id),
          jsonb_build_object('home_location_id', v_to.id, 'effective_date', p_effective_date, 'reason', v_reason),
          e.entity_id, e.home_location_id, e.id);

  -- Tell the current branch's managers so they can plan around the move.
  for v_recipient in
    select p.id from public.profiles p
    where p.role = 'location_manager' and p.is_active and p.location_id = e.home_location_id
  loop
    perform public.create_notification(e.entity_id, v_recipient, null, 'employee_transfer_scheduled',
      'Team member moving branch',
      format('%s moves to %s from %s. Review their shifts after that date.', e.name, v_to.name, to_char(p_effective_date, 'Dy DD Mon')),
      'employees', e.id, 'normal', 'employee_transfer_scheduled:' || v_id || ':' || v_recipient);
  end loop;

  if p_effective_date <= v_today then
    perform public._apply_employee_transfer(v_id);
    v_status := 'completed';
  end if;

  return jsonb_build_object('ok', true, 'transfer_id', v_id, 'status', v_status, 'effective_date', p_effective_date,
    'from_location_id', e.home_location_id, 'to_location_id', v_to.id, 'to_location_name', v_to.name,
    'review', public._transfer_review(e.id, e.home_location_id, p_effective_date));
end;
$function$;
revoke all on function public.transfer_employee(uuid, uuid, date, text) from public, anon;
grant execute on function public.transfer_employee(uuid, uuid, date, text) to authenticated, service_role;

create or replace function public.cancel_employee_transfer(p_transfer_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  t record;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select * into t from public.employee_transfers where id = p_transfer_id for update;
  if t.id is null then
    raise exception using errcode = 'P0002', message = 'Transfer not found';
  end if;
  if not (v_role = 'owner' or (v_role = 'entity_admin' and t.entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'Only the owner or a company admin can cancel a transfer';
  end if;
  if t.status <> 'scheduled' then
    raise exception using errcode = '22023', message = format('This transfer is already %s', t.status);
  end if;
  update public.employee_transfers
  set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
      cancellation_reason = nullif(btrim(coalesce(p_reason, '')), '')
  where id = t.id;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('employee_transfers', t.id, auth.uid(), 'employee_transfer_cancelled', jsonb_build_object('status', 'scheduled'),
          jsonb_build_object('status', 'cancelled', 'reason', nullif(btrim(coalesce(p_reason, '')), '')),
          t.entity_id, t.from_location_id, t.employee_id);
  return jsonb_build_object('ok', true);
end;
$function$;
revoke all on function public.cancel_employee_transfer(uuid, text) from public, anon;
grant execute on function public.cancel_employee_transfer(uuid, text) to authenticated, service_role;

-- Review list for an existing transfer (e.g. reopening the employee profile before the date).
create or replace function public.get_transfer_review(p_transfer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  t record;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select * into t from public.employee_transfers where id = p_transfer_id;
  if t.id is null then
    raise exception using errcode = 'P0002', message = 'Transfer not found';
  end if;
  if not (v_role = 'owner' or (v_role = 'entity_admin' and t.entity_id = public.my_entity())
          or (v_role = 'location_manager' and public.my_location() in (t.from_location_id, t.to_location_id))) then
    raise exception using errcode = '42501', message = 'Not authorized to view this transfer';
  end if;
  return public._transfer_review(t.employee_id, t.from_location_id, t.effective_date);
end;
$function$;
revoke all on function public.get_transfer_review(uuid) from public, anon;
grant execute on function public.get_transfer_review(uuid) to authenticated, service_role;

create or replace function public.run_due_employee_transfers()
returns int
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
  v_n int := 0;
begin
  for v_id in
    select id from public.employee_transfers
    where status = 'scheduled' and effective_date <= (now() at time zone 'Asia/Dubai')::date
    order by effective_date
  loop
    begin
      perform public._apply_employee_transfer(v_id);
      v_n := v_n + 1;
    exception when others then
      raise warning 'employee transfer % failed: %', v_id, sqlerrm;
    end;
  end loop;
  return v_n;
end;
$function$;
revoke all on function public.run_due_employee_transfers() from public, anon, authenticated;

-- 20:05 UTC = 00:05 Dubai.
select cron.schedule('employee-transfers-due', '5 20 * * *', 'select public.run_due_employee_transfers();');
