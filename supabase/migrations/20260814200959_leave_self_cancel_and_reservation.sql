
-- Phase 2.9a: leave self-cancel + a proper reserve-at-submission /
-- release-or-confirm-at-decision balance model. Previously balance was only
-- ever touched at approval time, which meant a pending request held no claim
-- on the balance at all — two pending requests could together exceed the
-- employee's remaining days with neither one flagged until whichever was
-- decided second. Submission now reserves the balance immediately (when
-- there's enough to reserve); approval converts that reservation into a
-- permanent deduction with no further balance change; rejection or
-- self-cancellation releases it back. This is also where the
-- leave_cancelled / leave_balance_reserved / leave_balance_released audit
-- event types anticipated (but deliberately not implemented) back in
-- Phase 1.3 finally land.

alter table public.leave_requests add column balance_reserved boolean not null default false;
alter table public.leave_requests add column cancelled_at timestamptz;
alter table public.leave_requests add column cancelled_by uuid references auth.users(id);
alter table public.leave_requests add column cancellation_reason text;

create or replace function public.log_leave_request_changes() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
  v_row record;
  v_safe_old jsonb;
  v_safe_new jsonb;
  v_manager_id uuid;
  v_new_balance numeric;
  v_reserved_rows int;
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

    if new.status = 'pending' then
      for v_manager_id in
        select id from profiles where role = 'location_manager' and location_id = v_location_id
      loop
        perform public.create_notification(
          v_entity_id, v_manager_id, null, 'leave_request_submitted',
          'New leave request',
          format('A leave request for %s day(s) is awaiting your decision.', new.days_requested),
          'leave_requests', new.id, 'normal',
          'leave_request_submitted:' || new.id::text || ':' || v_manager_id::text
        );
      end loop;

      -- Best-effort reservation: only if there's enough balance to reserve
      -- right now. If not, the request still stands (unchanged UX from
      -- Phase 1.3) and balance_reserved stays false — approval still runs
      -- its own insufficient-balance/override check, unchanged.
      update leave_balances set balance_days = balance_days - new.days_requested, updated_at = now()
        where employee_id = new.employee_id and leave_type_id = new.leave_type_id and balance_days >= new.days_requested
        returning balance_days into v_new_balance;
      get diagnostics v_reserved_rows = row_count;

      if v_reserved_rows > 0 then
        update leave_requests set balance_reserved = true where id = new.id;
        insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
        values ('leave_requests', new.id, auth.uid(), 'leave_balance_reserved',
          jsonb_build_object('leave_type_id', new.leave_type_id, 'days_reserved', new.days_requested, 'balance_after', v_new_balance),
          v_entity_id, v_location_id, new.employee_id);
      end if;
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.status = 'pending' and new.status in ('approved', 'rejected') and new.decided_by is not null then
      return new;
    end if;
    if old.status = 'pending' and new.status = 'cancelled' and new.cancelled_by is not null then
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

