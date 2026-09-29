-- ===== Setup data: when each branch opens, and how many people it needs =====

create table if not exists public.location_operating_hours (
  location_id uuid not null references public.locations(id) on delete cascade,
  entity_id uuid not null references public.entities(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6), -- 0 = Sunday
  is_closed boolean not null default false,
  open_time time,
  close_time time,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (location_id, day_of_week),
  check (is_closed or (open_time is not null and close_time is not null and open_time <> close_time))
);

create table if not exists public.location_staffing_needs (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id) on delete cascade,
  entity_id uuid not null references public.entities(id) on delete cascade,
  day_of_week smallint check (day_of_week between 0 and 6), -- null = every open day
  start_time time not null,
  end_time time not null,
  position_id uuid references public.positions(id),
  staff_needed smallint not null check (staff_needed between 1 and 50),
  created_by uuid,
  created_at timestamptz not null default now(),
  check (start_time <> end_time)
);
create index if not exists location_staffing_needs_location_idx on public.location_staffing_needs (location_id);
create index if not exists location_staffing_needs_position_idx on public.location_staffing_needs (position_id);
create index if not exists location_operating_hours_entity_idx on public.location_operating_hours (entity_id);
create index if not exists location_staffing_needs_entity_idx on public.location_staffing_needs (entity_id);

alter table public.location_operating_hours enable row level security;
alter table public.location_staffing_needs enable row level security;

create policy location_operating_hours_select on public.location_operating_hours for select to authenticated using (
  (select public.my_role()) = 'owner'
  or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager' and location_id = (select public.my_location()))
);
create policy location_staffing_needs_select on public.location_staffing_needs for select to authenticated using (
  (select public.my_role()) = 'owner'
  or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager' and location_id = (select public.my_location()))
);
revoke all on public.location_operating_hours, public.location_staffing_needs from anon;
grant select on public.location_operating_hours, public.location_staffing_needs to authenticated;

create or replace function public._require_entity_admin(p_entity_id uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'Only an admin can do this for this company';
  end if;
end $$;
revoke all on function public._require_entity_admin(uuid) from public, anon, authenticated;

-- p_hours: [{"day_of_week":0,"is_closed":false,"open_time":"07:00","close_time":"22:00"}, ...]
create or replace function public.set_location_operating_hours(p_location_id uuid, p_hours jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_entity uuid; x jsonb;
begin
  select entity_id into v_entity from public.locations where id = p_location_id;
  if v_entity is null then raise exception using errcode = 'P0002', message = 'Branch not found'; end if;
  perform public._require_entity_admin(v_entity);
  for x in select * from jsonb_array_elements(coalesce(p_hours, '[]'::jsonb)) loop
    insert into public.location_operating_hours (location_id, entity_id, day_of_week, is_closed, open_time, close_time, updated_by, updated_at)
    values (p_location_id, v_entity, (x->>'day_of_week')::smallint, coalesce((x->>'is_closed')::boolean, false),
            case when coalesce((x->>'is_closed')::boolean, false) then null else (x->>'open_time')::time end,
            case when coalesce((x->>'is_closed')::boolean, false) then null else (x->>'close_time')::time end,
            auth.uid(), now())
    on conflict (location_id, day_of_week) do update
      set is_closed = excluded.is_closed, open_time = excluded.open_time, close_time = excluded.close_time,
          updated_by = excluded.updated_by, updated_at = now();
  end loop;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('location_operating_hours', p_location_id, auth.uid(), 'operating_hours_saved', p_hours, v_entity, p_location_id);
end $$;

-- p_needs replaces all needs for the branch:
-- [{"day_of_week":null,"start_time":"07:00","end_time":"15:00","position_id":null,"staff_needed":2}, ...]
create or replace function public.set_location_staffing_needs(p_location_id uuid, p_needs jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_entity uuid; x jsonb; v_n integer := 0; v_old jsonb;
begin
  select entity_id into v_entity from public.locations where id = p_location_id;
  if v_entity is null then raise exception using errcode = 'P0002', message = 'Branch not found'; end if;
  perform public._require_entity_admin(v_entity);
  select coalesce(jsonb_agg(to_jsonb(n)), '[]'::jsonb) into v_old from public.location_staffing_needs n where n.location_id = p_location_id;
  delete from public.location_staffing_needs where location_id = p_location_id;
  for x in select * from jsonb_array_elements(coalesce(p_needs, '[]'::jsonb)) loop
    if nullif(x->>'position_id', '') is not null and not exists (
      select 1 from public.positions p where p.id = (x->>'position_id')::uuid and p.entity_id = v_entity) then
      raise exception using errcode = '22023', message = 'Role must belong to the same company';
    end if;
    insert into public.location_staffing_needs (location_id, entity_id, day_of_week, start_time, end_time, position_id, staff_needed, created_by)
    values (p_location_id, v_entity, nullif(x->>'day_of_week', '')::smallint, (x->>'start_time')::time, (x->>'end_time')::time,
            nullif(x->>'position_id', '')::uuid, coalesce((x->>'staff_needed')::smallint, 1), auth.uid());
    v_n := v_n + 1;
  end loop;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id)
  values ('location_staffing_needs', p_location_id, auth.uid(), 'staffing_needs_saved', v_old, p_needs, v_entity, p_location_id);
  return v_n;
end $$;

create or replace function public.get_scheduling_setup(p_entity_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_role public.user_role := public.my_role();
begin
  if not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'No access to this company';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'location_id', l.id, 'name', l.name,
      'hours', coalesce((select jsonb_agg(jsonb_build_object('day_of_week', h.day_of_week, 'is_closed', h.is_closed,
                          'open_time', h.open_time, 'close_time', h.close_time) order by h.day_of_week)
                         from public.location_operating_hours h where h.location_id = l.id), '[]'::jsonb),
      'needs', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'day_of_week', n.day_of_week, 'start_time', n.start_time,
                          'end_time', n.end_time, 'position_id', n.position_id, 'staff_needed', n.staff_needed)
                          order by n.day_of_week nulls first, n.start_time)
                         from public.location_staffing_needs n where n.location_id = l.id), '[]'::jsonb))
      order by l.name)
    from public.locations l
    where l.entity_id = p_entity_id and l.is_active
      and (v_role <> 'location_manager' or l.id = public.my_location())), '[]'::jsonb);
end $$;

-- ===== The engine =====
-- Rules: one shift per person per day; no overlaps (incl. overnight); max 8 working hours per shift
-- (9h with a 60-min break for anything over 5h); max 48 working hours and 6 working days per week;
-- respects availability, approved leave, join/leaving dates and role; home branch first, then
-- borrows staff from another branch of the same company; spreads hours evenly.
create or replace function public._auto_schedule(p_entity_id uuid, p_start date, p_end date, p_location_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d date; v_date date; l record; h record; w record; sl record;
  v_dow int; v_len int; v_n int; v_chunk int; i int; k int;
  v_s time; v_e time; v_elapsed int; v_break int; v_covered int;
  b_start timestamptz; b_end timestamptz;
  v_no_hours text[] := '{}';
  v_pick uuid; v_pass int;
  v_result jsonb;
begin
  drop table if exists pg_temp._as_slots;
  drop table if exists pg_temp._as_plan;
  create temp table _as_slots (id serial, shift_date date, location_id uuid, position_id uuid, start_time time, end_time time,
    break_minutes int, work_minutes int, b_start timestamptz, b_end timestamptz, filled boolean default false) on commit drop;
  create temp table _as_plan (shift_date date, location_id uuid, position_id uuid, employee_id uuid, start_time time, end_time time,
    break_minutes int, work_minutes int, b_start timestamptz, b_end timestamptz) on commit drop;

  -- 1. Turn opening hours + staffing needs into open slots, minus what is already scheduled.
  for d in select generate_series(p_start, p_end, interval '1 day')::date loop
    v_dow := extract(dow from d)::int;
    for l in select * from public.locations
              where entity_id = p_entity_id and is_active and (p_location_ids is null or id = any(p_location_ids))
              order by name loop
      select * into h from public.location_operating_hours where location_id = l.id and day_of_week = v_dow;
      if not found then
        if not (l.name = any(v_no_hours)) then v_no_hours := v_no_hours || l.name; end if;
        continue;
      end if;
      continue when h.is_closed;

      for w in
        select n.start_time, n.end_time, n.position_id, n.staff_needed::int as staff_needed
          from public.location_staffing_needs n
         where n.location_id = l.id and (n.day_of_week is null or n.day_of_week = v_dow)
        union all
        select h.open_time, h.close_time, null::uuid, 1
         where not exists (select 1 from public.location_staffing_needs n2
                            where n2.location_id = l.id and (n2.day_of_week is null or n2.day_of_week = v_dow))
      loop
        v_len := ((extract(epoch from (w.end_time - w.start_time)) / 60)::int + 1440) % 1440;
        continue when v_len = 0;
        v_n := ceil(v_len / 540.0)::int;
        v_chunk := (floor(v_len::numeric / v_n / 15) * 15)::int;
        for i in 1 .. v_n loop
          v_s := w.start_time + make_interval(mins => (i - 1) * v_chunk);
          v_elapsed := case when i = v_n then v_len - (v_n - 1) * v_chunk else v_chunk end;
          v_e := v_s + make_interval(mins => v_elapsed);
          v_break := case when v_elapsed > 300 then 60 else 0 end;
          v_date := case when i > 1 and v_s < w.start_time then d + 1 else d end;
          select planned_start, planned_end into b_start, b_end from public._shift_planned_bounds(v_date, v_s, v_e);

          select count(*) into v_covered
            from public.shifts s
            cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) sb
           where s.location_id = l.id and s.status <> 'cancelled' and s.employee_id is not null
             and s.shift_date between v_date - 1 and v_date
             and (w.position_id is null or s.position_id = w.position_id)
             and sb.planned_start <= b_start and sb.planned_end >= b_end;

          for k in 1 .. greatest(w.staff_needed - v_covered, 0) loop
            insert into pg_temp._as_slots (shift_date, location_id, position_id, start_time, end_time, break_minutes, work_minutes, b_start, b_end)
            values (v_date, l.id, w.position_id, v_s, v_e, v_break, v_elapsed - v_break, b_start, b_end);
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;

  -- 2. Fill slots: pass 1 home-branch staff only, pass 2 anyone in the same company.
  for v_pass in 1 .. 2 loop
    for sl in select * from pg_temp._as_slots where not filled order by b_start, location_id, id loop
      select e.id into v_pick
        from public.employees e
       where e.entity_id = p_entity_id and e.employment_status = 'active'
         and (e.join_date is null or e.join_date <= sl.shift_date)
         and (e.last_working_date is null or e.last_working_date >= sl.shift_date)
         and (v_pass = 2 or e.home_location_id = sl.location_id)
         and (sl.position_id is null or e.position_id = sl.position_id)
         and (not exists (select 1 from public.employee_availability a where a.employee_id = e.id)
              or exists (select 1 from public.employee_availability a
                          where a.employee_id = e.id and a.day_of_week = extract(dow from sl.shift_date)::int and a.is_available
                            and (a.start_time is null or a.start_time <= sl.start_time)
                            and (a.end_time is null or (sl.end_time > sl.start_time and sl.end_time <= a.end_time))))
         and not exists (select 1 from public.leave_requests lr
                          where lr.employee_id = e.id and lr.status = 'approved' and sl.shift_date between lr.start_date and lr.end_date)
         and not exists (select 1 from public.shifts s
                          where s.employee_id = e.id and s.status <> 'cancelled' and s.shift_date = sl.shift_date)
         and not exists (select 1 from pg_temp._as_plan p where p.employee_id = e.id and p.shift_date = sl.shift_date)
         and not exists (select 1 from public.shifts s
                          cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) sb
                          where s.employee_id = e.id and s.status <> 'cancelled'
                            and s.shift_date between sl.shift_date - 1 and sl.shift_date + 1
                            and tstzrange(sb.planned_start, sb.planned_end) && tstzrange(sl.b_start, sl.b_end))
         and not exists (select 1 from pg_temp._as_plan p
                          where p.employee_id = e.id and tstzrange(p.b_start, p.b_end) && tstzrange(sl.b_start, sl.b_end))
         and (select count(distinct x.dt) from (
                select s.shift_date as dt from public.shifts s
                 where s.employee_id = e.id and s.status <> 'cancelled'
                   and date_trunc('week', s.shift_date) = date_trunc('week', sl.shift_date)
                union
                select p.shift_date from pg_temp._as_plan p
                 where p.employee_id = e.id and date_trunc('week', p.shift_date) = date_trunc('week', sl.shift_date)) x) < 6
         and coalesce((select sum((extract(epoch from (sb.planned_end - sb.planned_start)) / 60)::int - s.break_minutes)
                         from public.shifts s
                         cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) sb
                        where s.employee_id = e.id and s.status <> 'cancelled'
                          and date_trunc('week', s.shift_date) = date_trunc('week', sl.shift_date)), 0)
             + coalesce((select sum(p.work_minutes) from pg_temp._as_plan p
                          where p.employee_id = e.id and date_trunc('week', p.shift_date) = date_trunc('week', sl.shift_date)), 0)
             + sl.work_minutes <= 2880
       order by (e.home_location_id = sl.location_id) desc,
                coalesce((select sum(p.work_minutes) from pg_temp._as_plan p where p.employee_id = e.id), 0),
                e.full_name
       limit 1;

      if v_pick is not null then
        insert into pg_temp._as_plan (shift_date, location_id, position_id, employee_id, start_time, end_time, break_minutes, work_minutes, b_start, b_end)
        values (sl.shift_date, sl.location_id, sl.position_id, v_pick, sl.start_time, sl.end_time, sl.break_minutes, sl.work_minutes, sl.b_start, sl.b_end);
        update pg_temp._as_slots set filled = true where id = sl.id;
      end if;
    end loop;
  end loop;

  -- 3. Report.
  select jsonb_build_object(
    'period_start', p_start, 'period_end', p_end,
    'shifts', coalesce((select jsonb_agg(jsonb_build_object(
        'shift_date', p.shift_date, 'location_id', p.location_id, 'location', l.name,
        'employee_id', p.employee_id, 'employee', e.full_name, 'position_id', p.position_id,
        'start_time', p.start_time, 'end_time', p.end_time, 'break_minutes', p.break_minutes,
        'cross_branch', e.home_location_id is distinct from p.location_id, 'home_location', hl.name)
        order by p.b_start, l.name, e.full_name)
      from pg_temp._as_plan p join public.locations l on l.id = p.location_id
      join public.employees e on e.id = p.employee_id left join public.locations hl on hl.id = e.home_location_id), '[]'::jsonb),
    'unfilled', coalesce((select jsonb_agg(jsonb_build_object(
        'shift_date', s.shift_date, 'location', l.name, 'role', ps.title, 'start_time', s.start_time, 'end_time', s.end_time)
        order by s.b_start, l.name)
      from pg_temp._as_slots s join public.locations l on l.id = s.location_id left join public.positions ps on ps.id = s.position_id
      where not s.filled), '[]'::jsonb),
    'warnings', to_jsonb(array_remove(array[
        case when cardinality(v_no_hours) > 0 then 'Opening hours not set for: ' || array_to_string(v_no_hours, ', ') || '. Nothing was planned there.' end,
        (select 'No availability on file, assumed available: ' || string_agg(distinct e.full_name, ', ')
           from pg_temp._as_plan p join public.employees e on e.id = p.employee_id
          where not exists (select 1 from public.employee_availability a where a.employee_id = e.id))
      ], null)),
    'summary', jsonb_build_object(
      'planned', (select count(*) from pg_temp._as_plan),
      'cross_branch', (select count(*) from pg_temp._as_plan p join public.employees e on e.id = p.employee_id
                        where e.home_location_id is distinct from p.location_id),
      'unfilled', (select count(*) from pg_temp._as_slots where not filled),
      'planned_hours', coalesce((select round(sum(work_minutes) / 60.0, 1) from pg_temp._as_plan), 0)))
  into v_result;
  return v_result;
end $$;
revoke all on function public._auto_schedule(uuid, date, date, uuid[]) from public, anon, authenticated;

create or replace function public._auto_schedule_check(p_entity_id uuid, p_period_start date, p_period_end date)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._require_entity_admin(p_entity_id);
  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then
    raise exception using errcode = '22023', message = 'Choose a valid period';
  end if;
  if p_period_end - p_period_start > 30 then
    raise exception using errcode = '22023', message = 'Plan at most 31 days at a time';
  end if;
  if p_period_start < (now() at time zone 'Asia/Dubai')::date then
    raise exception using errcode = '22023', message = 'The period cannot start in the past';
  end if;
end $$;
revoke all on function public._auto_schedule_check(uuid, date, date) from public, anon, authenticated;

-- Preview only: nothing is saved.
create or replace function public.propose_auto_schedule(p_entity_id uuid, p_period_start date, p_period_end date, p_location_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public._auto_schedule_check(p_entity_id, p_period_start, p_period_end);
  return public._auto_schedule(p_entity_id, p_period_start, p_period_end, p_location_ids);
end $$;

-- Creates the plan as DRAFT shifts (not visible to staff until published with "Publish period").
create or replace function public.apply_auto_schedule(p_entity_id uuid, p_period_start date, p_period_end date, p_location_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_plan jsonb; v_created integer;
begin
  perform public._auto_schedule_check(p_entity_id, p_period_start, p_period_end);
  v_plan := public._auto_schedule(p_entity_id, p_period_start, p_period_end, p_location_ids);

  insert into public.shifts (entity_id, location_id, position_id, employee_id, shift_date, start_time, end_time, break_minutes,
                             status, created_by, is_published, notes)
  select p_entity_id, p.location_id, p.position_id, p.employee_id, p.shift_date, p.start_time, p.end_time, p.break_minutes,
         'assigned', auth.uid(), false, 'Auto-scheduled'
    from pg_temp._as_plan p;
  get diagnostics v_created = row_count;

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
  values ('shifts', p_entity_id, auth.uid(), 'auto_schedule_applied',
          jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end, 'locations', p_location_ids,
                             'created', v_created, 'summary', v_plan->'summary'), p_entity_id);

  return v_plan || jsonb_build_object('created', v_created);
end $$;

revoke all on function public.set_location_operating_hours(uuid, jsonb) from public, anon;
revoke all on function public.set_location_staffing_needs(uuid, jsonb) from public, anon;
revoke all on function public.get_scheduling_setup(uuid) from public, anon;
revoke all on function public.propose_auto_schedule(uuid, date, date, uuid[]) from public, anon;
revoke all on function public.apply_auto_schedule(uuid, date, date, uuid[]) from public, anon;
grant execute on function public.set_location_operating_hours(uuid, jsonb) to authenticated;
grant execute on function public.set_location_staffing_needs(uuid, jsonb) to authenticated;
grant execute on function public.get_scheduling_setup(uuid) to authenticated;
grant execute on function public.propose_auto_schedule(uuid, date, date, uuid[]) to authenticated;
grant execute on function public.apply_auto_schedule(uuid, date, date, uuid[]) to authenticated;

notify pgrst, 'reload schema';;
