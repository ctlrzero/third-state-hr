
-- Replace direct-table writes to timesheet_entries / tips_pools / payslip_deductions
-- with SECURITY DEFINER RPCs, per explicit architecture decision:
--   * RPCs resolve the caller via auth.uid(), derive role/entity server-side (my_role()/
--     my_entity()/my_location()), and never trust client-supplied identity/scope values.
--   * Each RPC locks the parent payroll_runs row with SELECT ... FOR UPDATE before acting,
--     so concurrent status-advance and edit attempts serialize correctly.
--   * A locked run does NOT raise an exception -- it inserts a 'payroll_change_rejected'
--     audit_log row and returns {ok:false, code:'PAYROLL_RUN_LOCKED', message, request_id}
--     normally, so the rejection audit row commits (unlike the trigger-based approach,
--     which cannot durably log because raising an exception rolls back everything in the
--     same transaction, including any log insert -- see the immutability trigger below,
--     which is now enforcement-only backstop with no logging responsibility).
--   * A draft-run write performs the mutation and logs 'payroll_change_succeeded'.
--   * Direct SQL writes remain blocked by revoked table grants (below) and, as a second
--     backstop, RLS + the existing BEFORE trigger. Bypass/direct-SQL attempts are expected
--     to surface only in Postgres/pgAudit platform logs, not in audit_log -- this boundary
--     is intentional and is documented in the README.

-- 1. Remove direct authenticated write access to the payroll child tables entirely.
--    SELECT stays (self/scoped read policies are unaffected). The RPCs below run as the
--    function owner, which retains full table access regardless of these revokes.
revoke insert, update, delete on public.timesheet_entries from authenticated;
revoke insert, update, delete on public.tips_pools from authenticated;
revoke insert, update, delete on public.payslip_deductions from authenticated;

-- 2. Simplify the immutability trigger to pure enforcement: no audit_log writes (any
--    insert made right before RAISE EXCEPTION is rolled back along with everything else
--    in the aborting transaction, so it can never durably log a blocked attempt -- keeping
--    it was dead code that gave a false impression of coverage). It still unconditionally
--    blocks any write to a non-draft run's children, from any source, RPC or direct SQL.
create or replace function public.enforce_payroll_child_immutability()
returns trigger
security definer
set search_path to 'public', 'pg_temp'
language plpgsql
as $$
declare
  v_run_id uuid;
  v_status text;
begin
  v_run_id := coalesce(new.payroll_run_id, old.payroll_run_id);
  select status into v_status from public.payroll_runs where id = v_run_id;
  if v_status is null then
    raise exception 'Payroll run % not found', v_run_id;
  end if;
  if v_status <> 'draft' then
    raise exception 'Cannot modify % while payroll run % is ''%'' (only draft runs are editable). Create a revision run for corrections instead.',
      tg_table_name, v_run_id, v_status;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_payroll_child_immutability() from public, anon, authenticated;

-- 3. Timesheet entry RPCs.
create or replace function public.record_timesheet_entry(
  p_payroll_run_id uuid,
  p_employee_id uuid,
  p_regular_hours numeric default 0,
  p_overtime_hours numeric default 0,
  p_holiday_hours numeric default 0,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
  v_new_id uuid;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;

  if my_role() = 'owner' then
    v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then
    v_authorized := true;
  elsif my_role() = 'location_manager' then
    v_authorized := exists (select 1 from employees e where e.id = p_employee_id and e.home_location_id = my_location() and e.entity_id = v_run.entity_id);
  end if;

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('timesheet_entries', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'employee_id', p_employee_id, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('timesheet_entries', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'employee_id', p_employee_id, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  insert into timesheet_entries (payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes)
  values (p_payroll_run_id, p_employee_id, coalesce(p_regular_hours, 0), coalesce(p_overtime_hours, 0), coalesce(p_holiday_hours, 0), p_notes)
  returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('timesheet_entries', v_new_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'employee_id', p_employee_id, 'request_id', v_request_id));

  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'id', v_new_id);
end;
$$;

create or replace function public.delete_timesheet_entry(p_entry_id uuid) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entry record;
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
begin
  select * into v_entry from timesheet_entries where id = p_entry_id;
  if v_entry.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Timesheet entry not found.', 'request_id', v_request_id);
  end if;

  select * into v_run from payroll_runs where id = v_entry.payroll_run_id for update;

  if my_role() = 'owner' then
    v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then
    v_authorized := true;
  elsif my_role() = 'location_manager' then
    v_authorized := exists (select 1 from employees e where e.id = v_entry.employee_id and e.home_location_id = my_location() and e.entity_id = v_run.entity_id);
  end if;

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value)
    values ('timesheet_entries', p_entry_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, old_value)
    values ('timesheet_entries', p_entry_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  delete from timesheet_entries where id = p_entry_id;

  insert into audit_log (table_name, record_id, changed_by, action, old_value)
  values ('timesheet_entries', p_entry_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', v_entry.payroll_run_id, 'employee_id', v_entry.employee_id, 'request_id', v_request_id));

  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

-- 4. Tips pool RPCs.
create or replace function public.record_tips_pool(
  p_payroll_run_id uuid,
  p_location_id uuid,
  p_total_amount numeric default 0,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
  v_new_id uuid;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;

  if my_role() = 'owner' then
    v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then
    v_authorized := true;
  elsif my_role() = 'location_manager' then
    v_authorized := p_location_id = my_location();
  end if;

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('tips_pools', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'location_id', p_location_id, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('tips_pools', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'location_id', p_location_id, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  insert into tips_pools (payroll_run_id, location_id, total_amount, notes)
  values (p_payroll_run_id, p_location_id, coalesce(p_total_amount, 0), p_notes)
  returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('tips_pools', v_new_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'location_id', p_location_id, 'request_id', v_request_id));

  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'id', v_new_id);
end;
$$;

create or replace function public.delete_tips_pool(p_pool_id uuid) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_pool record;
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
begin
  select * into v_pool from tips_pools where id = p_pool_id;
  if v_pool.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Tips pool not found.', 'request_id', v_request_id);
  end if;

  select * into v_run from payroll_runs where id = v_pool.payroll_run_id for update;

  if my_role() = 'owner' then
    v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then
    v_authorized := true;
  elsif my_role() = 'location_manager' then
    v_authorized := v_pool.location_id = my_location();
  end if;

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value)
    values ('tips_pools', p_pool_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, old_value)
    values ('tips_pools', p_pool_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  delete from tips_pools where id = p_pool_id;

  insert into audit_log (table_name, record_id, changed_by, action, old_value)
  values ('tips_pools', p_pool_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', v_pool.payroll_run_id, 'location_id', v_pool.location_id, 'request_id', v_request_id));

  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

-- 5. Payslip deduction RPCs (owner/entity_admin only, matching pre-existing deductions_access).
create or replace function public.record_payslip_deduction(
  p_payroll_run_id uuid,
  p_employee_id uuid,
  p_deduction_type text,
  p_amount numeric,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
  v_new_id uuid;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;

  if my_role() = 'owner' then
    v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then
    v_authorized := true;
  end if;

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('payslip_deductions', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'employee_id', p_employee_id, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('payslip_deductions', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'employee_id', p_employee_id, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  insert into payslip_deductions (payroll_run_id, employee_id, deduction_type, amount, notes)
  values (p_payroll_run_id, p_employee_id, p_deduction_type, p_amount, p_notes)
  returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('payslip_deductions', v_new_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'employee_id', p_employee_id, 'request_id', v_request_id));

  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'id', v_new_id);
end;
$$;

create or replace function public.delete_payslip_deduction(p_deduction_id uuid) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_ded record;
  v_run record;
  v_authorized boolean := false;
  v_request_id uuid := gen_random_uuid();
begin
  select * into v_ded from payslip_deductions where id = p_deduction_id;
  if v_ded.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Deduction not found.', 'request_id', v_request_id);
  end if;

  select * into v_run from payroll_runs where id = v_ded.payroll_run_id for update;

  if my_role() = 'owner' then
    v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then
    v_authorized := true;
  end if;

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value)
    values ('payslip_deductions', p_deduction_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;

  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, old_value)
    values ('payslip_deductions', p_deduction_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'request_id', v_request_id));
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;

  delete from payslip_deductions where id = p_deduction_id;

  insert into audit_log (table_name, record_id, changed_by, action, old_value)
  values ('payslip_deductions', p_deduction_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', v_ded.payroll_run_id, 'employee_id', v_ded.employee_id, 'request_id', v_request_id));

  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

-- 6. Lock down grants: revoke from public/anon, grant execute to authenticated only.
revoke all on function public.record_timesheet_entry(uuid, uuid, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.record_timesheet_entry(uuid, uuid, numeric, numeric, numeric, text) to authenticated;

revoke all on function public.delete_timesheet_entry(uuid) from public, anon;
grant execute on function public.delete_timesheet_entry(uuid) to authenticated;

revoke all on function public.record_tips_pool(uuid, uuid, numeric, text) from public, anon;
grant execute on function public.record_tips_pool(uuid, uuid, numeric, text) to authenticated;

revoke all on function public.delete_tips_pool(uuid) from public, anon;
grant execute on function public.delete_tips_pool(uuid) to authenticated;

revoke all on function public.record_payslip_deduction(uuid, uuid, text, numeric, text) from public, anon;
grant execute on function public.record_payslip_deduction(uuid, uuid, text, numeric, text) to authenticated;

revoke all on function public.delete_payslip_deduction(uuid) from public, anon;
grant execute on function public.delete_payslip_deduction(uuid) to authenticated;
;
