
create or replace function public.approve_leave_request(p_request_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_employee_id uuid;
  v_entity_id uuid;
  v_home_location uuid;
  v_leave_type_id uuid;
  v_days numeric;
  v_status text;
begin
  select lr.employee_id, e.entity_id, e.home_location_id, lr.leave_type_id, lr.days_requested, lr.status
    into v_employee_id, v_entity_id, v_home_location, v_leave_type_id, v_days, v_status
  from leave_requests lr
  join employees e on e.id = lr.employee_id
  where lr.id = p_request_id;

  if v_employee_id is null then
    raise exception 'Leave request % not found', p_request_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_home_location = my_location())
  ) then
    raise exception 'Not authorized to decide this leave request';
  end if;

  if v_status <> 'pending' then
    raise exception 'Leave request % is not pending (status: %)', p_request_id, v_status;
  end if;

  if p_action = 'approve' then
    update leave_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where id = p_request_id;
    update leave_balances set balance_days = balance_days - v_days, updated_at = now()
      where employee_id = v_employee_id and leave_type_id = v_leave_type_id;
  elsif p_action = 'reject' then
    update leave_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = p_request_id;
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$function$;

revoke all on function public.approve_leave_request(uuid, text) from public, anon;
grant execute on function public.approve_leave_request(uuid, text) to authenticated;
