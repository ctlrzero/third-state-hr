
create or replace function public.record_timesheet_entry(
  p_payroll_run_id uuid, p_employee_id uuid,
  p_regular_hours numeric default 0, p_overtime_hours numeric default 0,
  p_holiday_hours numeric default 0, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_run record; v_authorized boolean := false; v_request_id uuid := gen_random_uuid(); v_new_id uuid;
  v_emp_location uuid;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;
  select home_location_id into v_emp_location from employees where id = p_employee_id;
  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  elsif my_role() = 'location_manager' then
    v_authorized := exists (select 1 from employees e where e.id = p_employee_id and e.home_location_id = my_location() and e.entity_id = v_run.entity_id);
  end if;
  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'timesheet_entries', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;
  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'timesheet_entries', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;
  insert into timesheet_entries (payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes)
  values (p_payroll_run_id, p_employee_id, coalesce(p_regular_hours, 0), coalesce(p_overtime_hours, 0), coalesce(p_holiday_hours, 0), p_notes)
  returning id into v_new_id;
  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('timesheet_entries', v_new_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'employee_id', p_employee_id, 'request_id', v_request_id),
    v_run.entity_id, v_emp_location, p_employee_id);
  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'id', v_new_id);
end;
$$;

create or replace function public.delete_timesheet_entry(p_entry_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entry record; v_run record; v_authorized boolean := false; v_request_id uuid := gen_random_uuid();
  v_emp_location uuid;
begin
  select * into v_entry from timesheet_entries where id = p_entry_id;
  if v_entry.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Timesheet entry not found.', 'request_id', v_request_id);
  end if;
  select * into v_run from payroll_runs where id = v_entry.payroll_run_id for update;
  select home_location_id into v_emp_location from employees where id = v_entry.employee_id;
  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  elsif my_role() = 'location_manager' then
    v_authorized := exists (select 1 from employees e where e.id = v_entry.employee_id and e.home_location_id = my_location() and e.entity_id = v_run.entity_id);
  end if;
  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
    values ('payroll_runs', v_entry.payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'timesheet_entries', 'entry_id', p_entry_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, v_entry.employee_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;
  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
    values ('payroll_runs', v_entry.payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'timesheet_entries', 'entry_id', p_entry_id, 'request_id', v_request_id),
      v_run.entity_id, v_emp_location, v_entry.employee_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;
  delete from timesheet_entries where id = p_entry_id;
  insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
  values ('timesheet_entries', p_entry_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', v_entry.payroll_run_id, 'employee_id', v_entry.employee_id, 'request_id', v_request_id),
    v_run.entity_id, v_emp_location, v_entry.employee_id);
  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

create or replace function public.record_tips_pool(
  p_payroll_run_id uuid, p_location_id uuid, p_total_amount numeric default 0, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_run record; v_authorized boolean := false; v_request_id uuid := gen_random_uuid(); v_new_id uuid;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;
  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  elsif my_role() = 'location_manager' then v_authorized := p_location_id = my_location();
  end if;
  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'tips_pools', 'location_id', p_location_id, 'request_id', v_request_id),
      v_run.entity_id, p_location_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;
  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'tips_pools', 'location_id', p_location_id, 'request_id', v_request_id),
      v_run.entity_id, p_location_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;
  insert into tips_pools (payroll_run_id, location_id, total_amount, notes)
  values (p_payroll_run_id, p_location_id, coalesce(p_total_amount, 0), p_notes)
  returning id into v_new_id;
  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('tips_pools', v_new_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'location_id', p_location_id, 'request_id', v_request_id),
    v_run.entity_id, p_location_id);
  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'id', v_new_id);
end;
$$;

create or replace function public.delete_tips_pool(p_pool_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_pool record; v_run record; v_authorized boolean := false; v_request_id uuid := gen_random_uuid();
begin
  select * into v_pool from tips_pools where id = p_pool_id;
  if v_pool.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Tips pool not found.', 'request_id', v_request_id);
  end if;
  select * into v_run from payroll_runs where id = v_pool.payroll_run_id for update;
  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  elsif my_role() = 'location_manager' then v_authorized := v_pool.location_id = my_location();
  end if;
  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id)
    values ('payroll_runs', v_pool.payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'tips_pools', 'pool_id', p_pool_id, 'request_id', v_request_id),
      v_run.entity_id, v_pool.location_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;
  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id)
    values ('payroll_runs', v_pool.payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'tips_pools', 'pool_id', p_pool_id, 'request_id', v_request_id),
      v_run.entity_id, v_pool.location_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;
  delete from tips_pools where id = p_pool_id;
  insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id)
  values ('tips_pools', p_pool_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', v_pool.payroll_run_id, 'location_id', v_pool.location_id, 'request_id', v_request_id),
    v_run.entity_id, v_pool.location_id);
  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

create or replace function public.record_payslip_deduction(
  p_payroll_run_id uuid, p_employee_id uuid, p_deduction_type text, p_amount numeric, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_run record; v_authorized boolean := false; v_request_id uuid := gen_random_uuid(); v_new_id uuid;
begin
  select * into v_run from payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Payroll run not found.', 'request_id', v_request_id);
  end if;
  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  end if;
  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'payslip_deductions', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;
  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
    values ('payroll_runs', p_payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'payslip_deductions', 'employee_id', p_employee_id, 'request_id', v_request_id),
      v_run.entity_id, p_employee_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;
  insert into payslip_deductions (payroll_run_id, employee_id, deduction_type, amount, notes)
  values (p_payroll_run_id, p_employee_id, p_deduction_type, p_amount, p_notes)
  returning id into v_new_id;
  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('payslip_deductions', v_new_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', p_payroll_run_id, 'employee_id', p_employee_id, 'request_id', v_request_id),
    v_run.entity_id, p_employee_id);
  return jsonb_build_object('ok', true, 'request_id', v_request_id, 'id', v_new_id);
end;
$$;

create or replace function public.delete_payslip_deduction(p_deduction_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_ded record; v_run record; v_authorized boolean := false; v_request_id uuid := gen_random_uuid();
begin
  select * into v_ded from payslip_deductions where id = p_deduction_id;
  if v_ded.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Deduction not found.', 'request_id', v_request_id);
  end if;
  select * into v_run from payroll_runs where id = v_ded.payroll_run_id for update;
  if my_role() = 'owner' then v_authorized := true;
  elsif my_role() = 'entity_admin' and v_run.entity_id = my_entity() then v_authorized := true;
  end if;
  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, employee_id)
    values ('payroll_runs', v_ded.payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'not_authorized', 'child_table', 'payslip_deductions', 'deduction_id', p_deduction_id, 'request_id', v_request_id),
      v_run.entity_id, v_ded.employee_id);
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'You are not authorized to modify this payroll run.', 'request_id', v_request_id);
  end if;
  if v_run.status <> 'draft' then
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, employee_id)
    values ('payroll_runs', v_ded.payroll_run_id, auth.uid(), 'payroll_change_rejected',
      jsonb_build_object('reason', 'run_locked', 'run_status', v_run.status, 'child_table', 'payslip_deductions', 'deduction_id', p_deduction_id, 'request_id', v_request_id),
      v_run.entity_id, v_ded.employee_id);
    return jsonb_build_object('ok', false, 'code', 'PAYROLL_RUN_LOCKED', 'message', 'This payroll run is locked and cannot be changed.', 'request_id', v_request_id);
  end if;
  delete from payslip_deductions where id = p_deduction_id;
  insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, employee_id)
  values ('payslip_deductions', p_deduction_id, auth.uid(), 'payroll_change_succeeded',
    jsonb_build_object('payroll_run_id', v_ded.payroll_run_id, 'employee_id', v_ded.employee_id, 'request_id', v_request_id),
    v_run.entity_id, v_ded.employee_id);
  return jsonb_build_object('ok', true, 'request_id', v_request_id);
end;
$$;

create or replace function public.create_payroll_revision(p_source_run_id uuid) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_source record;
  v_new_id uuid;
begin
  select * into v_source from public.payroll_runs where id = p_source_run_id;
  if v_source.id is null then raise exception 'Payroll run % not found', p_source_run_id; end if;
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_source.entity_id = my_entity())) then
    raise exception 'Not authorized to create a revision of this payroll run';
  end if;
  if v_source.status not in ('approved', 'paid') then
    raise exception 'Only an approved or paid run can be revised (current status: %). Edit the draft directly instead.', v_source.status;
  end if;
  insert into public.payroll_runs (entity_id, period_start, period_end, status, tip_distribution_rule, created_by, revises_payroll_run_id)
  values (v_source.entity_id, v_source.period_start, v_source.period_end, 'draft', v_source.tip_distribution_rule, auth.uid(), p_source_run_id)
  returning id into v_new_id;
  insert into public.timesheet_entries (payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes)
    select v_new_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes from public.timesheet_entries where payroll_run_id = p_source_run_id;
  insert into public.tips_pools (payroll_run_id, location_id, total_amount, notes)
    select v_new_id, location_id, total_amount, notes from public.tips_pools where payroll_run_id = p_source_run_id;
  insert into public.payslip_deductions (payroll_run_id, employee_id, deduction_type, amount, notes)
    select v_new_id, employee_id, deduction_type, amount, notes from public.payslip_deductions where payroll_run_id = p_source_run_id;
  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
    values ('payroll_runs', v_new_id, auth.uid(), 'payroll_revision_created', jsonb_build_object('revises_payroll_run_id', p_source_run_id), v_source.entity_id);
  return v_new_id;
end;
$$;
