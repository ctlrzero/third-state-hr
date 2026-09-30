-- "Morning shifts only" for people like Jordan: a per-employee shift type the auto-scheduler respects.
-- Morning = the shift starts before 10:00. No pattern row / 'any' = any shift (as before).
alter table public.employee_work_patterns
  add column if not exists shift_type text not null default 'any' check (shift_type in ('any', 'morning'));

create or replace function public.set_employee_shift_type(p_employee_id uuid, p_shift_type text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_entity uuid;
  v_old text;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select entity_id into v_entity from public.employees where id = p_employee_id;
  if v_entity is null then raise exception using errcode = 'P0002', message = 'Employee not found'; end if;
  perform public._require_entity_admin(v_entity);
  if p_shift_type is null or p_shift_type not in ('any', 'morning') then
    raise exception using errcode = '22023', message = 'Shift type must be any or morning';
  end if;

  select shift_type into v_old from public.employee_work_patterns where employee_id = p_employee_id;

  -- No pattern yet: create the default one (6 days, any day off) so the type has somewhere to live.
  insert into public.employee_work_patterns (employee_id, entity_id, days_per_week, days_off_mode, fixed_days_off, shift_type, updated_by, updated_at)
  values (p_employee_id, v_entity, 6, 'flexible', '{}', p_shift_type, auth.uid(), now())
  on conflict (employee_id) do update set shift_type = excluded.shift_type, updated_by = excluded.updated_by, updated_at = now();

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values ('employee_work_patterns', p_employee_id, auth.uid(), 'work_pattern_shift_type_saved',
    jsonb_build_object('shift_type', coalesce(v_old, 'any')), jsonb_build_object('shift_type', p_shift_type), v_entity, p_employee_id);

  return jsonb_build_object('ok', true, 'shift_type', p_shift_type);
end;
$$;
revoke all on function public.set_employee_shift_type(uuid, text) from public, anon;
grant execute on function public.set_employee_shift_type(uuid, text) to authenticated;

-- The auto-scheduler: a morning-only person is only offered shifts that start before 10:00.
do $m$
declare v text;
begin
  v := pg_get_functiondef('public._auto_schedule(uuid,date,date,uuid[])'::regprocedure);
  if position($a$         and (sl.position_id is null or e.position_id = sl.position_id)
$a$ in v) = 0 then raise exception 'patch point missing'; end if;
  v := replace(v, $a$         and (sl.position_id is null or e.position_id = sl.position_id)
$a$, $b$         and (sl.position_id is null or e.position_id = sl.position_id)
         and (coalesce(wp.shift_type, 'any') = 'any' or sl.start_time < time '10:00')
$b$);
  execute v;
end $m$;
