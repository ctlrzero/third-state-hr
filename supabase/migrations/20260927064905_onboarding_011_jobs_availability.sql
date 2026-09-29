create or replace function public.upsert_position(p_entity_id uuid, p_position_id uuid, p_title text, p_department text,
  p_description text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_old public.positions; v_id uuid;
begin
  if not public.is_active_user() or not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized to manage jobs for this company' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then raise exception 'Job title is required' using errcode = '22023'; end if;
  if exists (select 1 from public.positions where entity_id = p_entity_id and lower(title) = lower(btrim(p_title))
              and id is distinct from p_position_id) then
    raise exception 'Another job already has this title' using errcode = '23505';
  end if;
  if p_position_id is null then
    insert into public.positions (entity_id, title, department, description)
    values (p_entity_id, btrim(p_title), nullif(btrim(coalesce(p_department, '')), ''), nullif(btrim(coalesce(p_description, '')), ''))
    returning id into v_id;
  else
    select * into v_old from public.positions where id = p_position_id for update;
    if v_old.id is null or v_old.entity_id <> p_entity_id then raise exception 'Job not found' using errcode = 'P0002'; end if;
    update public.positions set title = btrim(p_title), department = nullif(btrim(coalesce(p_department, '')), ''),
           description = nullif(btrim(coalesce(p_description, '')), '')
     where id = p_position_id
    returning id into v_id;
  end if;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id)
  values ('positions', v_id, auth.uid(), case when p_position_id is null then 'position_created' else 'position_updated' end,
    case when v_old.id is not null then jsonb_build_object('title', v_old.title, 'department', v_old.department, 'description', v_old.description) end,
    jsonb_build_object('title', p_title, 'department', p_department, 'description', p_description), p_entity_id);
  return v_id;
end;
$$;

create or replace function public.get_my_availability()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_emp uuid := public.my_employee_id();
begin
  if v_emp is null then raise exception 'No employee record for this login' using errcode = '42501'; end if;
  return jsonb_build_object(
    'confirmed_at', (select availability_confirmed_at from public.employees where id = v_emp),
    'days', coalesce((select jsonb_agg(jsonb_build_object('day_of_week', a.day_of_week, 'is_available', a.is_available,
                        'start_time', a.start_time, 'end_time', a.end_time) order by a.day_of_week)
                      from public.employee_availability a where a.employee_id = v_emp), '[]'::jsonb));
end;
$$;

create or replace function public.save_my_availability(p_days jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  d jsonb;
  v_dow integer;
  v_start time;
  v_end time;
  v_seen integer[] := '{}';
begin
  i := public._onb_my_open_instance();
  if i.id is null then
    raise exception 'Ask your manager to change your availability' using errcode = '42501';
  end if;
  if p_days is null or jsonb_typeof(p_days) <> 'array' or jsonb_array_length(p_days) <> 7 then
    raise exception 'Give availability for all seven days' using errcode = '22023';
  end if;
  for d in select * from jsonb_array_elements(p_days) loop
    v_dow := (d ->> 'day_of_week')::integer;
    if v_dow is null or v_dow not between 0 and 6 or v_dow = any(v_seen) then
      raise exception 'Each day of the week must appear once' using errcode = '22023';
    end if;
    v_seen := v_seen || v_dow;
    v_start := nullif(d ->> 'start_time', '')::time;
    v_end := nullif(d ->> 'end_time', '')::time;
    if coalesce((d ->> 'is_available')::boolean, false) and v_start is not null and v_end is not null and v_end <= v_start then
      raise exception 'The end time must be after the start time' using errcode = '22023';
    end if;
  end loop;
  delete from public.employee_availability where employee_id = i.employee_id;
  insert into public.employee_availability (employee_id, day_of_week, is_available, start_time, end_time)
  select i.employee_id, (x ->> 'day_of_week')::integer, coalesce((x ->> 'is_available')::boolean, false),
         case when coalesce((x ->> 'is_available')::boolean, false) then nullif(x ->> 'start_time', '')::time end,
         case when coalesce((x ->> 'is_available')::boolean, false) then nullif(x ->> 'end_time', '')::time end
    from jsonb_array_elements(p_days) x;
  update public.employees set availability_confirmed_at = now(), updated_at = now() where id = i.employee_id;
  perform public._onb_audit(i.id, 'employee_availability', i.employee_id, 'availability_confirmed', null, jsonb_build_object('days', p_days));
  perform public._onb_sync_derived(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['upsert_position(uuid, uuid, text, text, text)', 'get_my_availability()', 'save_my_availability(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;;
