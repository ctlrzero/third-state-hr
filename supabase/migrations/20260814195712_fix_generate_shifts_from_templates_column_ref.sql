
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
  select v_entity_id, t.location_id, t.position_id, t.employee_id, gs2.shift_date, t.start_time, t.end_time,
    'assigned', auth.uid(), false, t.id
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
$$;

revoke all on function public.generate_shifts_from_templates(uuid, date, date) from public, anon;
grant execute on function public.generate_shifts_from_templates(uuid, date, date) to authenticated;

