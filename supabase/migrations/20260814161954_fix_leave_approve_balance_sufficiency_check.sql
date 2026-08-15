
-- Known limitation from the Leave module pass: approve_leave_request()
-- decremented leave_balances.balance_days on approval without ever
-- checking whether the balance was sufficient, so an approval could drive
-- a balance negative with no warning. Fixed by checking the current
-- balance (defaulting to 0 if no leave_balances row exists yet for that
-- employee/leave_type — same as the frontend already treats a missing
-- row) before decrementing, and raising a clear error instead of
-- decrementing past zero. This does not change who is authorized to
-- decide a request, or the pending-status idempotency guard added
-- earlier — both checks remain exactly as they were.
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
  v_current_balance numeric;
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
    select balance_days into v_current_balance
      from leave_balances
      where employee_id = v_employee_id and leave_type_id = v_leave_type_id;

    if coalesce(v_current_balance, 0) < v_days then
      raise exception 'Insufficient balance: employee has % day(s) but the request is for % day(s). Reject the request or adjust the balance first.',
        coalesce(v_current_balance, 0), v_days;
    end if;

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

