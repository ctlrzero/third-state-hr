-- 1. Breaks: templates already carry break_minutes; shifts never stored it.
alter table public.shifts add column if not exists break_minutes integer not null default 0;
alter table public.shifts add constraint shifts_break_minutes_nonneg check (break_minutes >= 0);

update public.shifts s set break_minutes = t.break_minutes
from public.schedule_templates t
where s.generated_from_template_id = t.id and t.break_minutes is not null;

-- 2. Validation on every insert/update of a non-cancelled shift.
create or replace function public.validate_shift()
returns trigger
language plpgsql
security definer
set search_path = ''
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

drop trigger if exists trg_shift_validate on public.shifts;
create trigger trg_shift_validate
  before insert or update on public.shifts
  for each row execute function public.validate_shift();

revoke all on function public.validate_shift() from public, anon, authenticated;

-- 3. Generation now carries the template's break onto each shift (otherwise unchanged).
create or replace function public.generate_shifts_from_templates(p_location_id uuid, p_period_start date, p_period_end date)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_entity_id uuid;
  v_generated int;
begin
  select entity_id into v_entity_id from locations where id = p_location_id;
  if v_entity_id is null then raise exception 'Location % not found', p_location_id; end if;

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
  on conflict (generated_from_template_id, shift_date) where generated_from_template_id is not null do nothing;

  get diagnostics v_generated = row_count;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('shifts', p_location_id, auth.uid(), 'schedule_shifts_generated',
    jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end, 'generated_count', v_generated),
    v_entity_id, p_location_id);

  return v_generated;
end;
$function$;;
