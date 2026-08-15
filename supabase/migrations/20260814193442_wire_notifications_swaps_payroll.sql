
create or replace function public.request_shift_swap(p_shift_id uuid, p_notes text default null) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_shift record;
  v_swap_id uuid;
  v_manager_id uuid;
begin
  select id, employee_id, shift_date, status, entity_id, location_id into v_shift
    from public.shifts where id = p_shift_id and employee_id = my_employee_id();

  if v_shift.id is null then raise exception 'Shift not found or not assigned to you'; end if;
  if not is_active_employee(my_employee_id()) then raise exception 'Inactive employees cannot request shift swaps'; end if;
  if v_shift.status = 'cancelled' then raise exception 'Cannot request a swap for a cancelled shift'; end if;
  if v_shift.shift_date < current_date then raise exception 'Cannot request a swap for a shift that has already passed'; end if;
  if exists (select 1 from public.shift_swap_requests where shift_id = p_shift_id and status in ('open', 'claimed')) then
    raise exception 'There is already an open swap request for this shift';
  end if;

  insert into public.shift_swap_requests (shift_id, requested_by, status, notes)
  values (p_shift_id, my_employee_id(), 'open', p_notes) returning id into v_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shift_swap_requests', v_swap_id, auth.uid(), 'swap_requested', jsonb_build_object('shift_id', p_shift_id), v_shift.entity_id, v_shift.location_id, my_employee_id());

  for v_manager_id in
    select id from profiles where role = 'location_manager' and location_id = v_shift.location_id
  loop
    perform public.create_notification(
      v_shift.entity_id, v_manager_id, null, 'swap_requested', 'New shift swap request',
      format('A swap request was opened for the shift on %s.', v_shift.shift_date),
      'shift_swap_requests', v_swap_id, 'normal', 'swap_requested:' || v_swap_id::text || ':' || v_manager_id::text
    );
  end loop;

  return v_swap_id;
end;
$$;

create or replace function public.claim_shift_swap(p_swap_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_swap record;
  v_shift record;
begin
  select id, shift_id, requested_by, claimed_by, status into v_swap from public.shift_swap_requests where id = p_swap_id;

  if v_swap.id is null then raise exception 'Swap request % not found', p_swap_id; end if;
  if v_swap.status <> 'open' or v_swap.claimed_by is not null then raise exception 'This swap request is no longer open'; end if;
  if v_swap.requested_by = my_employee_id() then raise exception 'You cannot claim your own swap request'; end if;
  if not is_active_employee(my_employee_id()) then raise exception 'Inactive employees cannot claim shift swaps'; end if;

  select id, location_id, status, entity_id into v_shift from public.shifts where id = v_swap.shift_id;

  if v_shift.status = 'cancelled' then raise exception 'Cannot claim a swap for a cancelled shift'; end if;
  if v_shift.location_id <> my_home_location() then raise exception 'You can only claim shift swaps at your own location'; end if;

  update public.shift_swap_requests set claimed_by = my_employee_id(), status = 'claimed' where id = p_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_claimed', jsonb_build_object('shift_id', v_swap.shift_id), v_shift.entity_id, v_shift.location_id, my_employee_id());

  perform public.create_notification(
    v_shift.entity_id, null, v_swap.requested_by, 'swap_claimed', 'Your shift swap was claimed',
    'Someone has claimed your open shift swap request.', 'shift_swap_requests', p_swap_id, 'normal',
    'swap_claimed:' || p_swap_id::text
  );
end;
$$;

create or replace function public.cancel_shift_swap_request(p_swap_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_swap record;
begin
  select ssr.id, ssr.requested_by, ssr.claimed_by, ssr.status, s.entity_id, s.location_id into v_swap
    from public.shift_swap_requests ssr
    join public.shifts s on s.id = ssr.shift_id
    where ssr.id = p_swap_id and ssr.requested_by = my_employee_id();

  if v_swap.id is null then raise exception 'Swap request not found or not yours to cancel'; end if;
  if v_swap.status not in ('open', 'claimed') then raise exception 'This swap request has already been decided'; end if;

  update public.shift_swap_requests set status = 'cancelled', resolved_by = auth.uid(), resolved_at = now()
    where id = p_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_cancelled', '{}'::jsonb, v_swap.entity_id, v_swap.location_id, my_employee_id());

  if v_swap.claimed_by is not null then
    perform public.create_notification(
      v_swap.entity_id, null, v_swap.claimed_by, 'swap_cancelled', 'A shift swap you claimed was cancelled',
      'The requester cancelled this shift swap before it was approved.', 'shift_swap_requests', p_swap_id, 'normal',
      'swap_cancelled:' || p_swap_id::text
    );
  end if;
end;
$$;

create or replace function public.approve_shift_swap(p_swap_id uuid, p_action text) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_shift_id uuid;
  v_requested_by uuid;
  v_claimed_by uuid;
  v_entity_id uuid;
  v_location_id uuid;
begin
  select ss.shift_id, ss.requested_by, ss.claimed_by, s.entity_id, s.location_id
    into v_shift_id, v_requested_by, v_claimed_by, v_entity_id, v_location_id
  from shift_swap_requests ss
  join shifts s on s.id = ss.shift_id
  where ss.id = p_swap_id;

  if v_shift_id is null then
    raise exception 'Swap request % not found', p_swap_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then
    raise exception 'Not authorized to decide this swap request';
  end if;

  if p_action = 'approve' then
    if v_claimed_by is null then
      raise exception 'This swap has not been claimed by anyone yet';
    end if;
    update shifts set employee_id = v_claimed_by where id = v_shift_id;
    update shift_swap_requests set status = 'approved', resolved_by = auth.uid(), resolved_at = now() where id = p_swap_id;

    perform public.create_notification(v_entity_id, null, v_requested_by, 'swap_approved', 'Shift swap approved',
      'Your shift swap request has been approved.', 'shift_swap_requests', p_swap_id, 'normal', 'swap_decided:' || p_swap_id::text || ':requester');
    perform public.create_notification(v_entity_id, null, v_claimed_by, 'swap_approved', 'Shift swap approved',
      'The shift swap you claimed has been approved.', 'shift_swap_requests', p_swap_id, 'normal', 'swap_decided:' || p_swap_id::text || ':claimant');
  elsif p_action = 'reject' then
    update shift_swap_requests set status = 'rejected', resolved_by = auth.uid(), resolved_at = now() where id = p_swap_id;

    perform public.create_notification(v_entity_id, null, v_requested_by, 'swap_rejected', 'Shift swap rejected',
      'Your shift swap request was rejected.', 'shift_swap_requests', p_swap_id, 'normal', 'swap_decided:' || p_swap_id::text || ':requester');
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$$;

-- Payroll: notify each employee in the run once payslips are (re)calculated. Message
-- intentionally carries no pay figures at all -- just "ready", matching "never expose
-- salary/bank" -- the actual figures stay behind the existing Payslip self-select RLS.
create or replace function public.run_payroll_calculation(p_payroll_run_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_status text;
  v_ot_confirmed boolean;
  v_tips_confirmed boolean;
  v_total_tips numeric;
  v_eligible_count int;
  v_tips_per_employee numeric;
  v_prior_snapshot jsonb;
  v_period_start date;
  v_period_end date;
  v_emp_id uuid;
begin
  select entity_id, status, overtime_holiday_pay_confirmed, tips_distribution_confirmed, period_start, period_end
    into v_entity_id, v_status, v_ot_confirmed, v_tips_confirmed, v_period_start, v_period_end
  from payroll_runs where id = p_payroll_run_id;

  if v_entity_id is null then raise exception 'Payroll run % not found', p_payroll_run_id; end if;
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Not authorized to run payroll for this entity';
  end if;
  if v_status not in ('draft', 'in_review') then
    raise exception 'Payroll run % is % -- recalculation is blocked once a run is approved or paid. Create a revision run for corrections instead.', p_payroll_run_id, v_status;
  end if;

  select coalesce(sum(total_amount), 0) into v_total_tips from tips_pools where payroll_run_id = p_payroll_run_id;
  select count(*) into v_eligible_count from timesheet_entries where payroll_run_id = p_payroll_run_id;

  v_tips_per_employee := case when v_eligible_count = 0 or not v_tips_confirmed then 0 else v_total_tips / v_eligible_count end;

  select jsonb_agg(to_jsonb(p)) into v_prior_snapshot from payslips p where payroll_run_id = p_payroll_run_id;
  if v_prior_snapshot is not null then
    insert into audit_log(table_name, record_id, changed_by, action, old_value, entity_id)
    values ('payslips', p_payroll_run_id, auth.uid(), 'recalculate_draft', v_prior_snapshot, v_entity_id);
  end if;

  delete from payslips where payroll_run_id = p_payroll_run_id;

  insert into payslips (payroll_run_id, employee_id, base_pay, overtime_pay, holiday_pay, tips_share, total_deductions, net_pay)
  select p_payroll_run_id, t.employee_id, calc.base_pay, calc.overtime_pay, calc.holiday_pay, v_tips_per_employee,
    coalesce(d.total_deductions, 0),
    calc.base_pay + calc.overtime_pay + calc.holiday_pay + v_tips_per_employee - coalesce(d.total_deductions, 0)
  from timesheet_entries t
  join employee_compensation c on c.employee_id = t.employee_id
  cross join lateral (
    select
      case when c.pay_type = 'hourly' then t.regular_hours * coalesce(c.pay_rate, 0) else coalesce(c.pay_rate, 0) end as base_pay,
      case when c.pay_type = 'hourly' and v_ot_confirmed then t.overtime_hours * coalesce(c.pay_rate, 0) * c.overtime_multiplier else 0 end as overtime_pay,
      case when c.pay_type = 'hourly' and v_ot_confirmed then t.holiday_hours * coalesce(c.pay_rate, 0) * c.holiday_multiplier else 0 end as holiday_pay
  ) calc
  left join (
    select employee_id, sum(amount) as total_deductions from payslip_deductions where payroll_run_id = p_payroll_run_id group by employee_id
  ) d on d.employee_id = t.employee_id
  where t.payroll_run_id = p_payroll_run_id;

  insert into audit_log(table_name, record_id, changed_by, action, new_value, entity_id)
  values ('payroll_runs', p_payroll_run_id, auth.uid(), 'calculated',
    jsonb_build_object('overtime_holiday_pay_confirmed', v_ot_confirmed, 'tips_distribution_confirmed', v_tips_confirmed), v_entity_id);

  for v_emp_id in select employee_id from payslips where payroll_run_id = p_payroll_run_id
  loop
    perform public.create_notification(
      v_entity_id, null, v_emp_id, 'payslip_available', 'Payslip ready',
      format('Your payslip for %s to %s is ready to view.', v_period_start, v_period_end),
      'payslips', p_payroll_run_id, 'normal',
      'payslip_available:' || p_payroll_run_id::text || ':' || v_emp_id::text
    );
  end loop;
end;
$$;

revoke all on function public.request_shift_swap(uuid, text) from public, anon;
grant execute on function public.request_shift_swap(uuid, text) to authenticated;
revoke all on function public.claim_shift_swap(uuid) from public, anon;
grant execute on function public.claim_shift_swap(uuid) to authenticated;
revoke all on function public.cancel_shift_swap_request(uuid) from public, anon;
grant execute on function public.cancel_shift_swap_request(uuid) to authenticated;
revoke all on function public.approve_shift_swap(uuid, text) from public, anon;
grant execute on function public.approve_shift_swap(uuid, text) to authenticated;
revoke all on function public.run_payroll_calculation(uuid) from public, anon;
grant execute on function public.run_payroll_calculation(uuid) to authenticated;

