
create or replace function public.approve_leave_request(p_request_id uuid, p_action text, p_override boolean default false, p_override_reason text default null) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_employee_id uuid;
  v_entity_id uuid;
  v_home_location uuid;
  v_leave_type_id uuid;
  v_days numeric;
  v_status text;
  v_balance_reserved boolean;
  v_current_balance numeric;
  v_new_balance numeric;
begin
  select lr.employee_id, e.entity_id, e.home_location_id, lr.leave_type_id, lr.days_requested, lr.status, lr.balance_reserved
    into v_employee_id, v_entity_id, v_home_location, v_leave_type_id, v_days, v_status, v_balance_reserved
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
    if v_balance_reserved then
      -- Balance was already held at submission time — approval just
      -- finalizes it. No further balance movement, and no second
      -- leave_balance_used entry (leave_balance_reserved already covers it).
      update leave_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where id = p_request_id;

      insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_approved',
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('status', 'approved', 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'actor_role', my_role(), 'balance_was_reserved', true),
        v_entity_id, v_home_location, v_employee_id);
    else
      select balance_days into v_current_balance from leave_balances where employee_id = v_employee_id and leave_type_id = v_leave_type_id;

      if coalesce(v_current_balance, 0) < v_days then
        if not p_override then
          raise exception 'Insufficient balance: employee has % day(s) but the request is for % day(s). Reject the request or use an authorised override.',
            coalesce(v_current_balance, 0), v_days;
        end if;
        if not (my_role() = 'owner' or my_role() = 'entity_admin') then
          raise exception 'Only an Owner or Entity Admin may override an insufficient-balance approval';
        end if;
        if p_override_reason is null or length(trim(p_override_reason)) = 0 then
          raise exception 'An override reason is required to approve against an insufficient balance';
        end if;
      end if;

      update leave_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where id = p_request_id;
      update leave_balances set balance_days = balance_days - v_days, updated_at = now()
        where employee_id = v_employee_id and leave_type_id = v_leave_type_id
        returning balance_days into v_new_balance;

      insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_approved',
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('status', 'approved', 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'actor_role', my_role()),
        v_entity_id, v_home_location, v_employee_id);

      insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_balance_used',
        jsonb_build_object('balance_days', coalesce(v_current_balance, 0)),
        jsonb_build_object('balance_days', v_new_balance, 'leave_type_id', v_leave_type_id, 'days_used', v_days, 'actor_role', my_role()),
        v_entity_id, v_home_location, v_employee_id);

      if p_override then
        insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
        values ('leave_requests', p_request_id, auth.uid(), 'leave_balance_override_approved',
          jsonb_build_object('balance_days', coalesce(v_current_balance, 0)),
          jsonb_build_object('balance_days', v_new_balance, 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'reason', p_override_reason, 'actor_role', my_role()),
          v_entity_id, v_home_location, v_employee_id);
      end if;
    end if;

    perform public.create_notification(
      v_entity_id, null, v_employee_id, 'leave_approved', 'Leave request approved',
      format('Your leave request for %s day(s) has been approved.', v_days),
      'leave_requests', p_request_id, 'normal', 'leave_decided:' || p_request_id::text
    );

  elsif p_action = 'reject' then
    update leave_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = p_request_id;

    insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
    values ('leave_requests', p_request_id, auth.uid(), 'leave_rejected',
      jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'rejected', 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'actor_role', my_role()),
      v_entity_id, v_home_location, v_employee_id);

    if v_balance_reserved then
      update leave_balances set balance_days = balance_days + v_days, updated_at = now()
        where employee_id = v_employee_id and leave_type_id = v_leave_type_id
        returning balance_days into v_new_balance;
      update leave_requests set balance_reserved = false where id = p_request_id;

      insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
      values ('leave_requests', p_request_id, auth.uid(), 'leave_balance_released',
        jsonb_build_object('leave_type_id', v_leave_type_id, 'days_released', v_days, 'balance_after', v_new_balance, 'reason', 'rejected'),
        v_entity_id, v_home_location, v_employee_id);
    end if;

    perform public.create_notification(
      v_entity_id, null, v_employee_id, 'leave_rejected', 'Leave request rejected',
      format('Your leave request for %s day(s) was rejected.', v_days),
      'leave_requests', p_request_id, 'normal', 'leave_decided:' || p_request_id::text
    );
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$$;

-- Employee self-cancel of their own still-Pending request. Idempotent: a
-- second call on an already-cancelled request is a no-op rather than an
-- error, so a retried/duplicate client call can never double-release a
-- balance that was already released once.
create or replace function public.cancel_leave_request(p_request_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
  v_entity_id uuid;
  v_home_location uuid;
  v_new_balance numeric;
  v_manager_id uuid;
begin
  select lr.*, e.entity_id, e.home_location_id into v_row
    from leave_requests lr join employees e on e.id = lr.employee_id
    where lr.id = p_request_id
    for update of lr;

  if v_row.id is null then raise exception 'Leave request % not found', p_request_id; end if;
  if v_row.employee_id <> my_employee_id() then raise exception 'You can only cancel your own leave requests'; end if;

  if v_row.status = 'cancelled' then
    -- Idempotent no-op: already cancelled (and its balance, if any, already released).
    return jsonb_build_object('ok', true, 'already_cancelled', true);
  end if;
  if v_row.status <> 'pending' then
    raise exception 'Only a pending leave request can be cancelled — this one is %', v_row.status;
  end if;

  v_entity_id := v_row.entity_id;
  v_home_location := v_row.home_location_id;

  update leave_requests set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), cancellation_reason = p_reason
    where id = p_request_id;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('leave_requests', p_request_id, auth.uid(), 'leave_cancelled',
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'cancelled', 'leave_type_id', v_row.leave_type_id, 'days_requested', v_row.days_requested, 'reason', p_reason),
    v_entity_id, v_home_location, v_row.employee_id);

  if v_row.balance_reserved then
    update leave_balances set balance_days = balance_days + v_row.days_requested, updated_at = now()
      where employee_id = v_row.employee_id and leave_type_id = v_row.leave_type_id
      returning balance_days into v_new_balance;
    update leave_requests set balance_reserved = false where id = p_request_id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('leave_requests', p_request_id, auth.uid(), 'leave_balance_released',
      jsonb_build_object('leave_type_id', v_row.leave_type_id, 'days_released', v_row.days_requested, 'balance_after', v_new_balance, 'reason', 'self_cancelled'),
      v_entity_id, v_home_location, v_row.employee_id);
  end if;

  for v_manager_id in
    select id from profiles where role = 'location_manager' and location_id = v_home_location
  loop
    perform public.create_notification(
      v_entity_id, v_manager_id, null, 'leave_cancelled', 'Leave request cancelled',
      format('A pending leave request for %s day(s) was cancelled by the employee.', v_row.days_requested),
      'leave_requests', p_request_id, 'normal', 'leave_cancelled:' || p_request_id::text || ':' || v_manager_id::text
    );
  end loop;

  return jsonb_build_object('ok', true, 'already_cancelled', false);
end;
$$;

revoke all on function public.cancel_leave_request(uuid, text) from public, anon;
grant execute on function public.cancel_leave_request(uuid, text) to authenticated;

