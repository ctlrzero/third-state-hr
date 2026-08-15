
-- Phase 1.3: leave audit integration. Every leave_requests write now produces an
-- audit_log row with entity_id/location_id/employee_id populated directly (same pattern
-- as Phase 1.2), an 'actor_role' captured inside the jsonb payload (audit_log has no
-- role column), and only SAFE structural fields (status, leave_type_id, dates,
-- days_requested, balance numbers) -- never the free-text `reason` or `manager_notes`
-- fields, which can contain personal/health context and are treated the same way
-- confidential supporting-document contents are treated elsewhere: never copied into
-- audit details.
--
-- Actions covered now: leave_request_submitted, leave_request_updated,
-- leave_request_deleted (a hard DELETE is possible via existing RLS for
-- owner/entity_admin/location_manager -- auditing it wasn't explicitly named in the spec
-- but is a clear gap otherwise, since a delete would otherwise erase history silently),
-- leave_approved, leave_rejected, leave_balance_used, and a new
-- leave_balance_override_approved action for a new capability (see below).
--
-- Deferred to Phase 2.9 (not yet built, and explicitly scoped there): leave_cancelled,
-- leave_balance_reserved, leave_balance_released, leave_accrual_applied -- these describe
-- actions/mechanics (self-cancel, a true balance-reservation model, the accrual engine)
-- that don't exist in the schema yet. Auditing an action before it exists would mean
-- inventing placeholder semantics now that Phase 2.9 would likely have to redesign
-- anyway; those events will be added as part of building the actual features.

create or replace function public.log_leave_request_changes() returns trigger
security definer set search_path to 'public', 'pg_temp'
language plpgsql
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
  v_row record;
  v_safe_old jsonb;
  v_safe_new jsonb;
begin
  v_row := coalesce(new, old);

  select entity_id, home_location_id into v_entity_id, v_location_id
    from employees where id = v_row.employee_id;

  if tg_op = 'INSERT' then
    v_safe_new := jsonb_build_object(
      'status', new.status, 'leave_type_id', new.leave_type_id,
      'start_date', new.start_date, 'end_date', new.end_date, 'days_requested', new.days_requested
    );
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('leave_requests', new.id, auth.uid(), 'leave_request_submitted',
      v_safe_new || jsonb_build_object('actor_role', my_role()), v_entity_id, v_location_id, new.employee_id);
    return new;
  end if;

  if tg_op = 'UPDATE' then
    -- Skip: a pending -> approved/rejected transition made through approve_leave_request()
    -- already logs its own richer 'leave_approved' / 'leave_rejected' event (plus
    -- 'leave_balance_used' / 'leave_balance_override_approved' where relevant). Logging
    -- it again here would just duplicate the same transition under a generic name.
    if old.status = 'pending' and new.status in ('approved', 'rejected') and new.decided_by is not null then
      return new;
    end if;

    v_safe_old := jsonb_build_object('status', old.status, 'leave_type_id', old.leave_type_id, 'start_date', old.start_date, 'end_date', old.end_date, 'days_requested', old.days_requested);
    v_safe_new := jsonb_build_object('status', new.status, 'leave_type_id', new.leave_type_id, 'start_date', new.start_date, 'end_date', new.end_date, 'days_requested', new.days_requested);
    insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
    values ('leave_requests', new.id, auth.uid(), 'leave_request_updated',
      v_safe_old, v_safe_new || jsonb_build_object('actor_role', my_role()), v_entity_id, v_location_id, new.employee_id);
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_safe_old := jsonb_build_object('status', old.status, 'leave_type_id', old.leave_type_id, 'start_date', old.start_date, 'end_date', old.end_date, 'days_requested', old.days_requested);
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
    values ('leave_requests', old.id, auth.uid(), 'leave_request_deleted',
      v_safe_old || jsonb_build_object('actor_role', my_role()), v_entity_id, v_location_id, old.employee_id);
    return old;
  end if;

  return v_row;
end;
$$;

revoke all on function public.log_leave_request_changes() from public, anon, authenticated;

drop trigger if exists trg_log_leave_request_changes on public.leave_requests;
create trigger trg_log_leave_request_changes
  after insert or update or delete on public.leave_requests
  for each row execute function public.log_leave_request_changes();

-- Extend approve_leave_request with an explicit, owner/entity_admin-only override path
-- for an insufficient balance, and full audit coverage of the decision + balance change.
create or replace function public.approve_leave_request(
  p_request_id uuid,
  p_action text,
  p_override boolean default false,
  p_override_reason text default null
) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_employee_id uuid;
  v_entity_id uuid;
  v_home_location uuid;
  v_leave_type_id uuid;
  v_days numeric;
  v_status text;
  v_current_balance numeric;
  v_new_balance numeric;
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

  elsif p_action = 'reject' then
    update leave_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = p_request_id;

    insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
    values ('leave_requests', p_request_id, auth.uid(), 'leave_rejected',
      jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'rejected', 'leave_type_id', v_leave_type_id, 'days_requested', v_days, 'actor_role', my_role()),
      v_entity_id, v_home_location, v_employee_id);
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$$;

revoke all on function public.approve_leave_request(uuid, text, boolean, text) from public, anon;
grant execute on function public.approve_leave_request(uuid, text, boolean, text) to authenticated;
