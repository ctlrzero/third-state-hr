
-- Shared authorization + validation, then create.
create or replace function public.create_schedule_template(
  p_location_id uuid,
  p_employee_id uuid,
  p_position_id uuid,
  p_day_of_week smallint,
  p_start_time time,
  p_end_time time,
  p_break_minutes int,
  p_effective_start_date date,
  p_effective_end_date date
) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_emp record;
  v_duration_minutes numeric;
  v_new_id uuid;
begin
  select entity_id into v_entity_id from locations where id = p_location_id;
  if v_entity_id is null then raise exception 'Location % not found', p_location_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and p_location_id = my_location())
  ) then raise exception 'Not authorized to manage schedule templates for this branch'; end if;

  if p_day_of_week is null or p_day_of_week not between 0 and 6 then
    raise exception 'day_of_week must be between 0 (Sunday) and 6 (Saturday)';
  end if;
  if p_end_time <= p_start_time then raise exception 'End time must be after start time'; end if;
  if p_effective_end_date is not null and p_effective_end_date < p_effective_start_date then
    raise exception 'Effective end date cannot be before the effective start date';
  end if;

  v_duration_minutes := extract(epoch from (p_end_time - p_start_time)) / 60;
  if coalesce(p_break_minutes, 0) < 0 or p_break_minutes >= v_duration_minutes then
    raise exception 'Break minutes must be zero or more and less than the shift duration (% minutes)', v_duration_minutes;
  end if;

  select id, entity_id, home_location_id, employment_status into v_emp from employees where id = p_employee_id;
  if v_emp.id is null then raise exception 'Employee % not found', p_employee_id; end if;
  if v_emp.entity_id <> v_entity_id or v_emp.home_location_id <> p_location_id then
    raise exception 'Employee is not based at this branch';
  end if;
  if v_emp.employment_status <> 'active' then raise exception 'Cannot create a schedule template for an inactive employee'; end if;

  if exists (
    select 1 from schedule_templates t
    where t.employee_id = p_employee_id
      and t.day_of_week = p_day_of_week
      and t.is_active = true
      and t.effective_start_date <= coalesce(p_effective_end_date, 'infinity'::date)
      and coalesce(t.effective_end_date, 'infinity'::date) >= p_effective_start_date
      and t.start_time < p_end_time
      and p_start_time < t.end_time
  ) then
    raise exception 'This employee already has an active template covering this day of week, date range and time window';
  end if;

  insert into schedule_templates (
    entity_id, location_id, employee_id, position_id, day_of_week, start_time, end_time,
    break_minutes, effective_start_date, effective_end_date, created_by
  ) values (
    v_entity_id, p_location_id, p_employee_id, p_position_id, p_day_of_week, p_start_time, p_end_time,
    coalesce(p_break_minutes, 0), p_effective_start_date, p_effective_end_date, auth.uid()
  ) returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('schedule_templates', v_new_id, auth.uid(), 'schedule_template_created',
    jsonb_build_object('day_of_week', p_day_of_week, 'start_time', p_start_time, 'end_time', p_end_time,
      'effective_start_date', p_effective_start_date, 'effective_end_date', p_effective_end_date),
    v_entity_id, p_location_id, p_employee_id);

  return v_new_id;
end;
$$;

create or replace function public.replace_schedule_template(
  p_template_id uuid,
  p_position_id uuid,
  p_day_of_week smallint,
  p_start_time time,
  p_end_time time,
  p_break_minutes int,
  p_effective_start_date date,
  p_effective_end_date date
) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_old record;
  v_emp record;
  v_duration_minutes numeric;
  v_new_id uuid;
begin
  select * into v_old from schedule_templates where id = p_template_id;
  if v_old.id is null then raise exception 'Schedule template % not found', p_template_id; end if;
  if not v_old.is_active then raise exception 'This template has already been superseded or deactivated'; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_old.entity_id = my_entity())
    or (my_role() = 'location_manager' and v_old.location_id = my_location())
  ) then raise exception 'Not authorized to manage schedule templates for this branch'; end if;

  if p_day_of_week is null or p_day_of_week not between 0 and 6 then
    raise exception 'day_of_week must be between 0 (Sunday) and 6 (Saturday)';
  end if;
  if p_end_time <= p_start_time then raise exception 'End time must be after start time'; end if;
  if p_effective_end_date is not null and p_effective_end_date < p_effective_start_date then
    raise exception 'Effective end date cannot be before the effective start date';
  end if;

  v_duration_minutes := extract(epoch from (p_end_time - p_start_time)) / 60;
  if coalesce(p_break_minutes, 0) < 0 or p_break_minutes >= v_duration_minutes then
    raise exception 'Break minutes must be zero or more and less than the shift duration (% minutes)', v_duration_minutes;
  end if;

  select id, employment_status into v_emp from employees where id = v_old.employee_id;
  if v_emp.employment_status <> 'active' then raise exception 'Cannot replace a schedule template for an inactive employee'; end if;

  if exists (
    select 1 from schedule_templates t
    where t.employee_id = v_old.employee_id
      and t.id <> p_template_id
      and t.day_of_week = p_day_of_week
      and t.is_active = true
      and t.effective_start_date <= coalesce(p_effective_end_date, 'infinity'::date)
      and coalesce(t.effective_end_date, 'infinity'::date) >= p_effective_start_date
      and t.start_time < p_end_time
      and p_start_time < t.end_time
  ) then
    raise exception 'This employee already has another active template covering this day of week, date range and time window';
  end if;

  update schedule_templates set is_active = false, updated_at = now() where id = p_template_id;

  insert into schedule_templates (
    entity_id, location_id, employee_id, position_id, day_of_week, start_time, end_time,
    break_minutes, effective_start_date, effective_end_date, version_number, supersedes_template_id, created_by
  ) values (
    v_old.entity_id, v_old.location_id, v_old.employee_id, p_position_id, p_day_of_week, p_start_time, p_end_time,
    coalesce(p_break_minutes, 0), p_effective_start_date, p_effective_end_date, v_old.version_number + 1, p_template_id, auth.uid()
  ) returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('schedule_templates', v_new_id, auth.uid(), 'schedule_template_replaced',
    jsonb_build_object('supersedes', p_template_id),
    jsonb_build_object('day_of_week', p_day_of_week, 'start_time', p_start_time, 'end_time', p_end_time,
      'effective_start_date', p_effective_start_date, 'effective_end_date', p_effective_end_date, 'version_number', v_old.version_number + 1),
    v_old.entity_id, v_old.location_id, v_old.employee_id);

  return v_new_id;
end;
$$;

create or replace function public.deactivate_schedule_template(p_template_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_old record;
begin
  select * into v_old from schedule_templates where id = p_template_id;
  if v_old.id is null then raise exception 'Schedule template % not found', p_template_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_old.entity_id = my_entity())
    or (my_role() = 'location_manager' and v_old.location_id = my_location())
  ) then raise exception 'Not authorized to manage schedule templates for this branch'; end if;

  if not v_old.is_active then raise exception 'This template is already inactive'; end if;

  update schedule_templates set is_active = false, updated_at = now() where id = p_template_id;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
  values ('schedule_templates', p_template_id, auth.uid(), 'schedule_template_deactivated',
    jsonb_build_object('day_of_week', v_old.day_of_week, 'start_time', v_old.start_time, 'end_time', v_old.end_time),
    v_old.entity_id, v_old.location_id, v_old.employee_id);
end;
$$;

create or replace function public.generate_shifts_from_templates(
  p_location_id uuid, p_period_start date, p_period_end date
) returns int
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
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

  insert into shifts (entity_id, location_id, position_id, employee_id, shift_date, start_time, end_time, status, created_by, is_published, generated_from_template_id)
  select v_entity_id, t.location_id, t.position_id, t.employee_id, gs.shift_date, t.start_time, t.end_time,
    'assigned', auth.uid(), false, t.id
  from schedule_templates t
  cross join lateral generate_series(p_period_start::timestamp, p_period_end::timestamp, interval '1 day') as gs(dt)
  cross join lateral (select gs.dt::date as shift_date) gs2
  where t.location_id = p_location_id
    and t.is_active = true
    and extract(dow from gs.dt) = t.day_of_week
    and gs.dt::date >= t.effective_start_date
    and (t.effective_end_date is null or gs.dt::date <= t.effective_end_date)
    and exists (select 1 from employees e where e.id = t.employee_id and e.employment_status = 'active')
    and not exists (
      select 1 from shifts s2 where s2.employee_id = t.employee_id and s2.shift_date = gs.dt::date and s2.status <> 'cancelled'
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

create or replace function public.publish_schedule_period(
  p_location_id uuid, p_period_start date, p_period_end date
) returns int
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_published int;
begin
  select entity_id into v_entity_id from locations where id = p_location_id;
  if v_entity_id is null then raise exception 'Location % not found', p_location_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and p_location_id = my_location())
  ) then raise exception 'Not authorized to publish schedules for this branch'; end if;

  if p_period_end < p_period_start then raise exception 'Period end cannot be before period start'; end if;

  update shifts set is_published = true
    where location_id = p_location_id
      and shift_date between p_period_start and p_period_end
      and is_published = false
      and status <> 'cancelled';

  get diagnostics v_published = row_count;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('shifts', p_location_id, auth.uid(), 'schedule_shifts_published',
    jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end, 'published_count', v_published),
    v_entity_id, p_location_id);

  return v_published;
end;
$$;

revoke all on function public.create_schedule_template(uuid, uuid, uuid, smallint, time, time, int, date, date) from public, anon;
grant execute on function public.create_schedule_template(uuid, uuid, uuid, smallint, time, time, int, date, date) to authenticated;

revoke all on function public.replace_schedule_template(uuid, uuid, smallint, time, time, int, date, date) from public, anon;
grant execute on function public.replace_schedule_template(uuid, uuid, smallint, time, time, int, date, date) to authenticated;

revoke all on function public.deactivate_schedule_template(uuid) from public, anon;
grant execute on function public.deactivate_schedule_template(uuid) to authenticated;

revoke all on function public.generate_shifts_from_templates(uuid, date, date) from public, anon;
grant execute on function public.generate_shifts_from_templates(uuid, date, date) to authenticated;

revoke all on function public.publish_schedule_period(uuid, date, date) from public, anon;
grant execute on function public.publish_schedule_period(uuid, date, date) to authenticated;

