-- Auto-scheduler honours employee_work_patterns: never plans someone on a
-- fixed day off, and caps their working days per (Mon–Sun) week at their own
-- days_per_week instead of the flat 6. No pattern = the old 6-day cap.

CREATE OR REPLACE FUNCTION public._auto_schedule(p_entity_id uuid, p_start date, p_end date, p_location_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    break_minutes int, work_minutes int, b_start timestamptz, b_end timestamptz, slot_rank int, filled boolean default false) on commit drop;
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
        -- Long windows: overlapping full-length shifts (9h incl. 1h break) spread from open to close.
        v_n := ceil(v_len / 540.0)::int;
        for i in 1 .. v_n loop
          v_chunk := case when v_n = 1 or i = 1 then 0
                          when i = v_n then v_len - 540
                          else (floor(((v_len - 540)::numeric * (i - 1) / (v_n - 1)) / 15) * 15)::int end;
          v_elapsed := case when v_n = 1 then v_len else 540 end;
          v_s := w.start_time + make_interval(mins => v_chunk);
          v_e := v_s + make_interval(mins => v_elapsed);
          v_break := case when v_elapsed > 300 then 60 else 0 end;
          v_date := case when v_chunk > 0 and v_s < w.start_time then d + 1 else d end;
          select planned_start, planned_end into b_start, b_end from public._shift_planned_bounds(v_date, v_s, v_e);

          select count(*) into v_covered
            from public.shifts s
            cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) sb
           where s.location_id = l.id and s.status <> 'cancelled' and s.employee_id is not null
             and s.shift_date between v_date - 1 and v_date
             and (w.position_id is null or s.position_id = w.position_id)
             and sb.planned_start <= b_start and sb.planned_end >= b_end;

          for k in 1 .. greatest(w.staff_needed - v_covered, 0) loop
            insert into pg_temp._as_slots (shift_date, location_id, position_id, start_time, end_time, break_minutes, work_minutes, b_start, b_end, slot_rank)
            values (v_date, l.id, w.position_id, v_s, v_e, v_break, v_elapsed - v_break, b_start, b_end, k);
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;

  -- 2. Fill slots: pass 1 home-branch staff only, pass 2 anyone in the same company.
  for v_pass in 1 .. 2 loop
    for sl in select * from pg_temp._as_slots where not filled order by shift_date, slot_rank, b_start, location_id, id loop
      select e.id into v_pick
        from public.employees e
        left join public.employee_work_patterns wp on wp.employee_id = e.id
       where e.entity_id = p_entity_id and e.employment_status = 'active'
         and (e.join_date is null or e.join_date <= sl.shift_date)
         and (e.last_working_date is null or e.last_working_date >= sl.shift_date)
         and (v_pass = 2 or e.home_location_id = sl.location_id)
         and (sl.position_id is null or e.position_id = sl.position_id)
         and not coalesce(wp.days_off_mode = 'fixed' and extract(dow from sl.shift_date)::smallint = any(wp.fixed_days_off), false)
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
                 where p.employee_id = e.id and date_trunc('week', p.shift_date) = date_trunc('week', sl.shift_date)) x)
             < coalesce(wp.days_per_week, 6)
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
        'shift_date', p.shift_date, 'location_id', p.location_id, 'location', loc.name,
        'employee_id', p.employee_id, 'employee', e.full_name, 'position_id', p.position_id,
        'start_time', p.start_time, 'end_time', p.end_time, 'break_minutes', p.break_minutes,
        'cross_branch', e.home_location_id is distinct from p.location_id, 'home_location', hl.name)
        order by p.b_start, loc.name, e.full_name)
      from pg_temp._as_plan p join public.locations loc on loc.id = p.location_id
      join public.employees e on e.id = p.employee_id left join public.locations hl on hl.id = e.home_location_id), '[]'::jsonb),
    'unfilled', coalesce((select jsonb_agg(jsonb_build_object(
        'shift_date', s.shift_date, 'location', loc.name, 'role', ps.title, 'start_time', s.start_time, 'end_time', s.end_time)
        order by s.b_start, loc.name)
      from pg_temp._as_slots s join public.locations loc on loc.id = s.location_id left join public.positions ps on ps.id = s.position_id
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
end $function$;
