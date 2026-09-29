-- History of every change to a PUBLISHED shift. No FK to shifts so evidence survives deletion.
create table if not exists public.shift_adjustments (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null,
  entity_id uuid not null references public.entities(id) on delete cascade,
  location_id uuid,
  employee_id uuid,
  previous_employee_id uuid,
  change_type text not null check (change_type in ('cancelled','unpublished','reassigned','date_changed','location_changed','time_changed','break_changed','deleted')),
  reason text,
  old_values jsonb not null,
  new_values jsonb,
  changed_by uuid,
  changed_at timestamptz not null default now()
);
create index if not exists shift_adjustments_shift_idx on public.shift_adjustments (shift_id, changed_at);
create index if not exists shift_adjustments_scope_idx on public.shift_adjustments (entity_id, location_id);

alter table public.shift_adjustments enable row level security;

create policy shift_adjustments_select on public.shift_adjustments
  for select to authenticated
  using (
    (select public.my_role()) = 'owner'
    or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))
    or ((select public.my_role()) = 'location_manager' and location_id = (select public.my_location()))
    or (employee_id = (select public.my_employee_id()))
    or (previous_employee_id = (select public.my_employee_id()))
  );
-- No insert/update/delete policies: rows are written only by the trigger below.
revoke all on public.shift_adjustments from anon;
grant select on public.shift_adjustments to authenticated;

create or replace function public.record_published_shift_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_change text;
  v_reason text := nullif(btrim(current_setting('app.shift_adjust_reason', true)), '');
  v_old jsonb := to_jsonb(old) - 'created_by' - 'created_at';
  v_new jsonb;
begin
  if not old.is_published then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    v_change := 'deleted';
  else
    v_change := case
      when new.status = 'cancelled' and old.status <> 'cancelled' then 'cancelled'
      when not new.is_published then 'unpublished'
      when new.employee_id is distinct from old.employee_id then 'reassigned'
      when new.shift_date is distinct from old.shift_date then 'date_changed'
      when new.location_id is distinct from old.location_id then 'location_changed'
      when new.start_time is distinct from old.start_time or new.end_time is distinct from old.end_time then 'time_changed'
      when new.break_minutes is distinct from old.break_minutes then 'break_changed'
      else null
    end;
    if v_change is null then
      return new;
    end if;
    v_new := to_jsonb(new) - 'created_by' - 'created_at';
  end if;

  insert into public.shift_adjustments
    (shift_id, entity_id, location_id, employee_id, previous_employee_id, change_type, reason, old_values, new_values, changed_by)
  values
    (old.id, old.entity_id, coalesce(new.location_id, old.location_id),
     case when tg_op = 'DELETE' then old.employee_id else new.employee_id end,
     old.employee_id, v_change, v_reason, v_old, v_new, auth.uid());

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('shifts', old.id, auth.uid(),
          case when tg_op = 'DELETE' then 'published_shift_deleted' else 'published_shift_adjusted' end,
          v_old, coalesce(v_new, '{}'::jsonb) || jsonb_build_object('change_type', v_change, 'reason', v_reason),
          old.entity_id, coalesce(new.location_id, old.location_id), old.employee_id);

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_record_published_shift_change on public.shifts;
create trigger trg_record_published_shift_change
  after update or delete on public.shifts
  for each row execute function public.record_published_shift_change();

revoke all on function public.record_published_shift_change() from public, anon, authenticated;

-- Controlled way to change a published shift: reason is mandatory, originals are kept above.
create or replace function public.adjust_published_shift(
  p_shift_id uuid,
  p_reason text,
  p_shift_date date default null,
  p_start_time time default null,
  p_end_time time default null,
  p_break_minutes integer default null,
  p_employee_id uuid default null,
  p_location_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.shifts%rowtype;
  v_role public.user_role := public.my_role();
  v_target_location uuid;
  v_target_entity uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception using errcode = '22023', message = 'A reason is required to change a published shift';
  end if;

  select * into v from public.shifts where id = p_shift_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Shift not found';
  end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v.location_id = public.my_location())
  ) then
    raise exception using errcode = '42501', message = 'Not authorised to change this shift';
  end if;

  if not v.is_published then
    raise exception using errcode = '22023', message = 'This shift is still a draft; edit it directly before publishing';
  end if;
  if v.status = 'cancelled' then
    raise exception using errcode = '22023', message = 'This shift is cancelled';
  end if;

  v_target_location := coalesce(p_location_id, v.location_id);
  if v_target_location <> v.location_id then
    select entity_id into v_target_entity from public.locations where id = v_target_location and is_active;
    if v_target_entity is null or v_target_entity <> v.entity_id then
      raise exception using errcode = '22023', message = 'The new branch must be an active branch of the same entity';
    end if;
    if v_role = 'location_manager' then
      raise exception using errcode = '42501', message = 'Managers can only change shifts within their own branch';
    end if;
  end if;

  if p_employee_id is not null and p_employee_id is distinct from v.employee_id then
    if not exists (
      select 1 from public.employees e
      where e.id = p_employee_id and e.entity_id = v.entity_id and e.employment_status = 'active'
    ) then
      raise exception using errcode = '22023', message = 'The new employee must be an active employee of the same entity';
    end if;
  end if;

  perform set_config('app.shift_adjust_reason', btrim(p_reason), true);

  update public.shifts set
    shift_date    = coalesce(p_shift_date, shift_date),
    start_time    = coalesce(p_start_time, start_time),
    end_time      = coalesce(p_end_time, end_time),
    break_minutes = coalesce(p_break_minutes, break_minutes),
    employee_id   = coalesce(p_employee_id, employee_id),
    location_id   = v_target_location
  where id = p_shift_id;

  perform set_config('app.shift_adjust_reason', '', true);
end;
$$;

revoke all on function public.adjust_published_shift(uuid, text, date, time, time, integer, uuid, uuid) from public, anon;
grant execute on function public.adjust_published_shift(uuid, text, date, time, time, integer, uuid, uuid) to authenticated;

-- Same controlled path for cancelling a published shift.
create or replace function public.cancel_published_shift(p_shift_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.shifts%rowtype;
  v_role public.user_role := public.my_role();
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception using errcode = '22023', message = 'A reason is required to cancel a published shift';
  end if;
  select * into v from public.shifts where id = p_shift_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Shift not found';
  end if;
  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v.location_id = public.my_location())
  ) then
    raise exception using errcode = '42501', message = 'Not authorised to cancel this shift';
  end if;
  if v.status = 'cancelled' then
    return;
  end if;
  perform set_config('app.shift_adjust_reason', btrim(p_reason), true);
  update public.shifts set status = 'cancelled' where id = p_shift_id;
  perform set_config('app.shift_adjust_reason', '', true);
end;
$$;

revoke all on function public.cancel_published_shift(uuid, text) from public, anon;
grant execute on function public.cancel_published_shift(uuid, text) to authenticated;;
