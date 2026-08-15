
-- Use clock_timestamp() instead of now() for the actual clock-in/out
-- instants. now() is frozen to the start of the enclosing transaction, which
-- is fine for ordinary business-logic timestamps but wrong here: two
-- SECURITY DEFINER calls issued back-to-back (or, as in live verification,
-- two RPC calls composed inside one wrapping test transaction) could
-- otherwise get an identical clock_in_at/clock_out_at and trip the
-- clock_out-after-clock_in check constraint.
create or replace function public.clock_in() returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_emp record;
  v_shift_id uuid;
  v_new_id uuid;
  v_now timestamptz := clock_timestamp();
begin
  select id, entity_id, home_location_id, employment_status into v_emp from employees where id = my_employee_id();
  if v_emp.id is null then raise exception 'No employee record is linked to your account'; end if;
  if v_emp.employment_status <> 'active' then raise exception 'Inactive employees cannot clock in'; end if;

  if exists (select 1 from attendance_records where employee_id = v_emp.id and clock_out_at is null) then
    raise exception 'You already have an open clock-in — clock out first';
  end if;

  select id into v_shift_id from shifts
    where employee_id = v_emp.id and shift_date = current_date and status <> 'cancelled' and is_published = true
    order by start_time limit 1;

  insert into attendance_records (entity_id, location_id, employee_id, shift_id, clock_in_at)
  values (v_emp.entity_id, v_emp.home_location_id, v_emp.id, v_shift_id, v_now)
  returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', v_new_id, auth.uid(), 'attendance_clock_in',
    jsonb_build_object('shift_id', v_shift_id, 'clock_in_at', v_now), v_emp.entity_id, v_emp.home_location_id, v_emp.id);

  return jsonb_build_object('id', v_new_id, 'shift_id', v_shift_id);
end;
$$;

create or replace function public.clock_out() returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_emp_id uuid := my_employee_id();
  v_record record;
  v_now timestamptz := clock_timestamp();
begin
  if v_emp_id is null then raise exception 'No employee record is linked to your account'; end if;

  select id, entity_id, location_id, clock_in_at into v_record
    from attendance_records
    where employee_id = v_emp_id and clock_out_at is null
    order by clock_in_at desc limit 1
    for update;

  if v_record.id is null then raise exception 'No open clock-in found to close'; end if;
  if v_now <= v_record.clock_in_at then v_now := v_record.clock_in_at + interval '1 second'; end if;

  update attendance_records set clock_out_at = v_now, updated_at = v_now where id = v_record.id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('attendance_records', v_record.id, auth.uid(), 'attendance_clock_out',
    jsonb_build_object('clock_in_at', v_record.clock_in_at, 'clock_out_at', v_now), v_record.entity_id, v_record.location_id, v_emp_id);

  return jsonb_build_object('id', v_record.id);
end;
$$;

revoke all on function public.clock_in() from public, anon;
grant execute on function public.clock_in() to authenticated;
revoke all on function public.clock_out() from public, anon;
grant execute on function public.clock_out() to authenticated;

