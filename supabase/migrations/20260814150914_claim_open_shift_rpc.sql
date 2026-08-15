
-- Staff can already see unfilled ('open') shifts at their own home location
-- via shifts_select_open_home_location. Give them a matching way to actually
-- pick one up, with the same location/active-employee checks as claiming a
-- swap, rather than leaving that visibility half-wired.
create or replace function public.claim_open_shift(p_shift_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_shift record;
begin
  select id, employee_id, status, location_id into v_shift
    from public.shifts
    where id = p_shift_id;

  if v_shift.id is null then
    raise exception 'Shift % not found', p_shift_id;
  end if;

  if v_shift.status <> 'open' or v_shift.employee_id is not null then
    raise exception 'This shift is no longer open';
  end if;

  if not is_active_employee(my_employee_id()) then
    raise exception 'Inactive employees cannot pick up shifts';
  end if;

  if v_shift.location_id <> my_home_location() then
    raise exception 'You can only pick up open shifts at your own location';
  end if;

  update public.shifts
    set employee_id = my_employee_id(), status = 'assigned'
    where id = p_shift_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('shifts', p_shift_id, auth.uid(), 'shift_claimed', jsonb_build_object('employee_id', my_employee_id()));
end;
$$;

revoke all on function public.claim_open_shift(uuid) from public, anon;
grant execute on function public.claim_open_shift(uuid) to authenticated;
