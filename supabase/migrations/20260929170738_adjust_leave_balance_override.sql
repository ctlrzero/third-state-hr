-- Manual per-employee leave balance override (admin panel quick-fix for
-- employees whose offer letter specifies a different entitlement than the
-- entity-wide accrual policy). Distinct from run_leave_accrual: this does
-- NOT write to leave_accrual_runs (that table requires a real policy_id and
-- represents the accrual engine's own ledger) -- it's a direct, reasoned,
-- audited correction, same spirit as set_employee_compensation.
create or replace function public.adjust_leave_balance(
  p_employee_id uuid,
  p_leave_type_id uuid,
  p_new_balance numeric,
  p_reason text
) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_balance_before numeric;
begin
  select e.entity_id into v_entity_id from employees e where e.id = p_employee_id;
  if v_entity_id is null then
    raise exception 'Employee % not found', p_employee_id;
  end if;

  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Not authorized to adjust leave balances for this employee';
  end if;

  if not exists (select 1 from leave_types where id = p_leave_type_id and entity_id = v_entity_id) then
    raise exception 'Leave type % is not configured for this employee''s entity', p_leave_type_id;
  end if;

  if p_new_balance is null or p_new_balance < 0 then
    raise exception 'Balance must be zero or a positive number';
  end if;

  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required to manually adjust a leave balance';
  end if;

  select balance_days into v_balance_before from leave_balances
    where employee_id = p_employee_id and leave_type_id = p_leave_type_id;

  if v_balance_before is null then
    insert into leave_balances (employee_id, leave_type_id, balance_days, updated_at)
    values (p_employee_id, p_leave_type_id, p_new_balance, now());
    v_balance_before := 0;
  else
    update leave_balances set balance_days = p_new_balance, updated_at = now()
      where employee_id = p_employee_id and leave_type_id = p_leave_type_id;
  end if;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values ('leave_balances', p_employee_id, auth.uid(), 'leave_balance_manually_adjusted',
    jsonb_build_object('balance_days', v_balance_before),
    jsonb_build_object('balance_days', p_new_balance, 'reason', p_reason),
    v_entity_id, p_employee_id);
end;
$$;

revoke all on function public.adjust_leave_balance(uuid, uuid, numeric, text) from public, anon;
grant execute on function public.adjust_leave_balance(uuid, uuid, numeric, text) to authenticated;
