-- Per-employee work pattern: how many days a week someone works and whether
-- their days off are fixed (e.g. Fri + Sat) or flexible (any day).
-- No row = previous behaviour (up to 6 days, any day).

create table if not exists public.employee_work_patterns (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  entity_id uuid not null references public.entities(id),
  days_per_week smallint not null check (days_per_week between 1 and 6),
  days_off_mode text not null check (days_off_mode in ('fixed', 'flexible')),
  fixed_days_off smallint[] not null default '{}',
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint work_pattern_days_off_valid check (
    fixed_days_off <@ array[0, 1, 2, 3, 4, 5, 6]::smallint[]
    and (
      (days_off_mode = 'flexible' and cardinality(fixed_days_off) = 0)
      or (days_off_mode = 'fixed' and cardinality(fixed_days_off) = 7 - days_per_week)
    )
  )
);

alter table public.employee_work_patterns enable row level security;

create policy employee_work_patterns_select on public.employee_work_patterns for select to authenticated
  using (
    employee_id = public.my_employee_id()
    or public.my_role() = 'owner'
    or (public.my_role() = 'entity_admin' and entity_id = public.my_entity())
    or (public.my_role() = 'location_manager' and exists (
          select 1 from public.employees e where e.id = employee_work_patterns.employee_id and e.home_location_id = public.my_location()))
  );

revoke all on public.employee_work_patterns from anon, authenticated;
grant select on public.employee_work_patterns to authenticated;

-- ---------------------------------------------------------------- set / clear

create or replace function public.set_employee_work_pattern(
  p_employee_id uuid, p_days_per_week integer, p_days_off_mode text, p_fixed_days_off integer[])
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_entity uuid;
  v_days smallint[];
  v_old jsonb;
begin
  select entity_id into v_entity from public.employees where id = p_employee_id;
  if v_entity is null then raise exception using errcode = 'P0002', message = 'Employee not found'; end if;
  perform public._require_entity_admin(v_entity);

  if p_days_per_week is null or p_days_per_week not between 1 and 6 then
    raise exception using errcode = '22023', message = 'Working days per week must be between 1 and 6';
  end if;
  if p_days_off_mode not in ('fixed', 'flexible') then
    raise exception using errcode = '22023', message = 'Days off must be fixed or flexible';
  end if;

  select coalesce(array_agg(distinct x order by x), '{}') into v_days
    from unnest(coalesce(p_fixed_days_off, '{}'::integer[])) x;
  if exists (select 1 from unnest(v_days) x where x not between 0 and 6) then
    raise exception using errcode = '22023', message = 'Days off must be days of the week';
  end if;

  if p_days_off_mode = 'flexible' then
    v_days := '{}';
  elsif cardinality(v_days) <> 7 - p_days_per_week then
    raise exception using errcode = '22023',
      message = format('Someone working %s days a week needs exactly %s fixed day%s off', p_days_per_week,
                       7 - p_days_per_week, case when 7 - p_days_per_week = 1 then '' else 's' end);
  end if;

  select to_jsonb(w) into v_old from public.employee_work_patterns w where w.employee_id = p_employee_id;

  insert into public.employee_work_patterns (employee_id, entity_id, days_per_week, days_off_mode, fixed_days_off, updated_by, updated_at)
  values (p_employee_id, v_entity, p_days_per_week, p_days_off_mode, v_days, auth.uid(), now())
  on conflict (employee_id) do update
    set days_per_week = excluded.days_per_week, days_off_mode = excluded.days_off_mode,
        fixed_days_off = excluded.fixed_days_off, updated_by = excluded.updated_by, updated_at = now();

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values ('employee_work_patterns', p_employee_id, auth.uid(), 'work_pattern_saved', v_old,
    jsonb_build_object('days_per_week', p_days_per_week, 'days_off_mode', p_days_off_mode, 'fixed_days_off', v_days),
    v_entity, p_employee_id);

  return jsonb_build_object('ok', true, 'days_per_week', p_days_per_week, 'days_off_mode', p_days_off_mode, 'fixed_days_off', v_days);
end;
$$;

create or replace function public.clear_employee_work_pattern(p_employee_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_entity uuid;
  v_old jsonb;
begin
  select entity_id into v_entity from public.employees where id = p_employee_id;
  if v_entity is null then raise exception using errcode = 'P0002', message = 'Employee not found'; end if;
  perform public._require_entity_admin(v_entity);
  delete from public.employee_work_patterns w where w.employee_id = p_employee_id returning to_jsonb(w) into v_old;
  if v_old is not null then
    insert into public.audit_log (table_name, record_id, changed_by, action, old_value, entity_id, employee_id)
    values ('employee_work_patterns', p_employee_id, auth.uid(), 'work_pattern_cleared', v_old, v_entity, p_employee_id);
  end if;
end;
$$;

-- ------------------------------------------------ warnings for manual shifts
-- Advisory only: returns warnings, never blocks. Weeks are Mon–Sun, the same
-- week the auto-scheduler uses for its limits.

create or replace function public.check_shift_work_pattern(p_employee_id uuid, p_shift_date date, p_exclude_shift_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  e record;
  wp public.employee_work_patterns;
  v_dow int := extract(dow from p_shift_date)::int;
  v_days int;
  v_warn jsonb := '[]'::jsonb;
  v_names text[] := array['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  v_week_start date := date_trunc('week', p_shift_date)::date;
begin
  select id, entity_id, home_location_id, full_name into e from public.employees where id = p_employee_id;
  if e.id is null then return jsonb_build_object('warnings', v_warn, 'pattern', null); end if;
  if not (public.my_role() = 'owner'
          or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
          or (public.my_role() = 'location_manager' and e.entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'No access to this employee';
  end if;

  select * into wp from public.employee_work_patterns where employee_id = p_employee_id;
  if wp.employee_id is null then return jsonb_build_object('warnings', v_warn, 'pattern', null); end if;

  if wp.days_off_mode = 'fixed' and v_dow = any(wp.fixed_days_off) then
    v_warn := v_warn || jsonb_build_object('code', 'fixed_day_off',
      'message', format('%s is a fixed day off for %s.', v_names[v_dow + 1], e.full_name));
  end if;

  select count(distinct s.shift_date) into v_days
    from public.shifts s
   where s.employee_id = p_employee_id and s.status <> 'cancelled'
     and date_trunc('week', s.shift_date) = date_trunc('week', p_shift_date)
     and s.shift_date <> p_shift_date
     and (p_exclude_shift_id is null or s.id <> p_exclude_shift_id);

  if v_days + 1 > wp.days_per_week then
    v_warn := v_warn || jsonb_build_object('code', 'over_days_per_week',
      'message', format('%s works %s day%s a week and already has %s in the week of %s. This would be day %s.',
                        e.full_name, wp.days_per_week, case when wp.days_per_week = 1 then '' else 's' end,
                        v_days, to_char(v_week_start, 'DD Mon'), v_days + 1));
  end if;

  return jsonb_build_object('warnings', v_warn,
    'pattern', jsonb_build_object('days_per_week', wp.days_per_week, 'days_off_mode', wp.days_off_mode, 'fixed_days_off', wp.fixed_days_off));
end;
$$;

revoke all on function public.set_employee_work_pattern(uuid, integer, text, integer[]) from public, anon;
revoke all on function public.clear_employee_work_pattern(uuid) from public, anon;
revoke all on function public.check_shift_work_pattern(uuid, date, uuid) from public, anon;
grant execute on function public.set_employee_work_pattern(uuid, integer, text, integer[]) to authenticated;
grant execute on function public.clear_employee_work_pattern(uuid) to authenticated;
grant execute on function public.check_shift_work_pattern(uuid, date, uuid) to authenticated;
