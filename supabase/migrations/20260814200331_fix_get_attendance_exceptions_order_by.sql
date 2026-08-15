
create or replace function public.get_attendance_exceptions(
  p_location_id uuid, p_period_start date, p_period_end date
) returns table (
  exception_type text,
  employee_id uuid,
  employee_name text,
  shift_date date,
  record_id uuid,
  shift_id uuid,
  clock_in_at timestamptz,
  clock_out_at timestamptz
)
language plpgsql security definer stable set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
begin
  select entity_id into v_entity_id from locations where id = p_location_id;
  if v_entity_id is null then raise exception 'Location % not found', p_location_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and p_location_id = my_location())
  ) then raise exception 'Not authorized to view attendance for this branch'; end if;

  return query
  select * from (
    select 'missing_clock_out'::text as exception_type, a.employee_id, e.full_name as employee_name, a.clock_in_at::date as shift_date,
      a.id as record_id, a.shift_id, a.clock_in_at, a.clock_out_at
    from attendance_records a
    join employees e on e.id = a.employee_id
    where a.location_id = p_location_id
      and a.clock_in_at::date between p_period_start and p_period_end
      and a.clock_out_at is null
      and a.clock_in_at::date < current_date

    union all

    select 'unmatched_shift'::text, s.employee_id, e.full_name, s.shift_date, null::uuid, s.id, null::timestamptz, null::timestamptz
    from shifts s
    join employees e on e.id = s.employee_id
    where s.location_id = p_location_id
      and s.is_published = true
      and s.status <> 'cancelled'
      and s.employee_id is not null
      and s.shift_date between p_period_start and p_period_end
      and s.shift_date < current_date
      and not exists (select 1 from attendance_records a2 where a2.shift_id = s.id)

    union all

    select 'no_shift_match'::text, a.employee_id, e.full_name, a.clock_in_at::date, a.id, a.shift_id, a.clock_in_at, a.clock_out_at
    from attendance_records a
    join employees e on e.id = a.employee_id
    where a.location_id = p_location_id
      and a.clock_in_at::date between p_period_start and p_period_end
      and a.shift_id is null
  ) combined
  order by shift_date desc;
end;
$$;

revoke all on function public.get_attendance_exceptions(uuid, date, date) from public, anon;
grant execute on function public.get_attendance_exceptions(uuid, date, date) to authenticated;

