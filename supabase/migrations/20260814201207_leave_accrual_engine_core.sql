
-- Phase 2.9b: idempotent leave accrual engine, gated behind an explicitly
-- approved policy. Configuring a policy never activates it — is_approved
-- starts (and resets to) false on every configuration change; a separate,
-- owner-only approval step is required before run_leave_accrual() will do
-- anything for that leave type. There is no scheduler/cron here — running
-- accrual for a period is always a deliberate, manual action by an
-- owner/entity_admin, exactly like run_payroll_calculation.

create table public.leave_accrual_policies (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  leave_type_id uuid not null unique references public.leave_types(id),
  frequency text not null check (frequency in ('monthly', 'annual')),
  days_per_period numeric not null check (days_per_period > 0),
  rounding text not null default 'none' check (rounding in ('none', 'nearest_half_day', 'nearest_day')),
  max_balance_days numeric check (max_balance_days is null or max_balance_days > 0),
  carry_forward_cap_days numeric check (carry_forward_cap_days is null or carry_forward_cap_days >= 0),
  probation_days int not null default 0 check (probation_days >= 0),
  policy_start_date date not null,
  is_approved boolean not null default false,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.leave_accrual_policies enable row level security;
create policy leave_accrual_policies_select on public.leave_accrual_policies
  for select to authenticated
  using (my_role() = 'owner' or (my_role() = 'entity_admin' and entity_id = my_entity()));
revoke all on public.leave_accrual_policies from authenticated, anon, public;
grant select on public.leave_accrual_policies to authenticated;

-- Ledger of applied accrual periods — the idempotency backstop: a unique
-- constraint, not just an application-level check, so re-running the same
-- period can never double-credit an employee even under concurrent calls.
create table public.leave_accrual_runs (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null references public.leave_accrual_policies(id),
  employee_id uuid not null references public.employees(id),
  leave_type_id uuid not null references public.leave_types(id),
  period_key text not null,
  days_accrued numeric not null,
  balance_before numeric not null,
  balance_after numeric not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (employee_id, leave_type_id, period_key)
);

alter table public.leave_accrual_runs enable row level security;
create policy leave_accrual_runs_select on public.leave_accrual_runs
  for select to authenticated
  using (
    employee_id = my_employee_id()
    or my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_accrual_runs.employee_id and e.entity_id = my_entity()))
  );
revoke all on public.leave_accrual_runs from authenticated, anon, public;
grant select on public.leave_accrual_runs to authenticated;

create or replace function public.configure_leave_accrual_policy(
  p_leave_type_id uuid, p_frequency text, p_days_per_period numeric, p_rounding text,
  p_max_balance_days numeric, p_carry_forward_cap_days numeric, p_probation_days int, p_policy_start_date date
) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_id uuid;
begin
  select entity_id into v_entity_id from leave_types where id = p_leave_type_id;
  if v_entity_id is null then raise exception 'Leave type % not found', p_leave_type_id; end if;

  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Not authorized to configure accrual for this leave type';
  end if;
  if p_frequency not in ('monthly', 'annual') then raise exception 'frequency must be monthly or annual'; end if;
  if p_days_per_period <= 0 then raise exception 'days_per_period must be positive'; end if;
  if coalesce(p_rounding, 'none') not in ('none', 'nearest_half_day', 'nearest_day') then raise exception 'invalid rounding mode'; end if;

  insert into leave_accrual_policies (
    entity_id, leave_type_id, frequency, days_per_period, rounding, max_balance_days,
    carry_forward_cap_days, probation_days, policy_start_date, is_approved, created_by
  ) values (
    v_entity_id, p_leave_type_id, p_frequency, p_days_per_period, coalesce(p_rounding, 'none'), p_max_balance_days,
    p_carry_forward_cap_days, coalesce(p_probation_days, 0), p_policy_start_date, false, auth.uid()
  )
  on conflict (leave_type_id) do update set
    frequency = excluded.frequency, days_per_period = excluded.days_per_period, rounding = excluded.rounding,
    max_balance_days = excluded.max_balance_days, carry_forward_cap_days = excluded.carry_forward_cap_days,
    probation_days = excluded.probation_days, policy_start_date = excluded.policy_start_date,
    -- Any change to an existing policy requires re-approval — never silently
    -- keep an old approval alive against new terms.
    is_approved = false, approved_by = null, approved_at = null, updated_at = now()
  returning id into v_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
  values ('leave_accrual_policies', v_id, auth.uid(), 'leave_accrual_policy_configured',
    jsonb_build_object('leave_type_id', p_leave_type_id, 'frequency', p_frequency, 'days_per_period', p_days_per_period,
      'rounding', coalesce(p_rounding, 'none'), 'max_balance_days', p_max_balance_days,
      'carry_forward_cap_days', p_carry_forward_cap_days, 'probation_days', coalesce(p_probation_days, 0),
      'policy_start_date', p_policy_start_date),
    v_entity_id);

  return v_id;
end;
$$;

create or replace function public.approve_leave_accrual_policy(p_policy_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
begin
  select * into v_row from leave_accrual_policies where id = p_policy_id;
  if v_row.id is null then raise exception 'Accrual policy % not found', p_policy_id; end if;

  -- Deliberately owner-only, a stricter bar than entity_admin (who can
  -- configure) — this is the step that actually activates a process that
  -- will later move every employee's leave balance.
  if my_role() <> 'owner' then raise exception 'Only an Owner may approve an accrual policy'; end if;
  if v_row.is_approved then raise exception 'This policy is already approved'; end if;

  update leave_accrual_policies set is_approved = true, approved_by = auth.uid(), approved_at = now(), updated_at = now()
    where id = p_policy_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
  values ('leave_accrual_policies', p_policy_id, auth.uid(), 'leave_accrual_policy_approved',
    jsonb_build_object('leave_type_id', v_row.leave_type_id), v_row.entity_id);
end;
$$;

create or replace function public.run_leave_accrual(p_leave_type_id uuid, p_period_key text) returns int
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_policy record;
  v_emp record;
  v_raw_days numeric;
  v_rounded_days numeric;
  v_balance_before numeric;
  v_balance_after numeric;
  v_credited int := 0;
begin
  select * into v_policy from leave_accrual_policies where leave_type_id = p_leave_type_id;
  if v_policy.id is null then raise exception 'No accrual policy configured for leave type %', p_leave_type_id; end if;

  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_policy.entity_id = my_entity())) then
    raise exception 'Not authorized to run accrual for this entity';
  end if;

  -- The hard gate: an unapproved (or since-edited-and-reset) policy can
  -- never be run, regardless of who calls this or how.
  if not v_policy.is_approved then
    raise exception 'This accrual policy has not been approved by an Owner — run_leave_accrual is blocked until it is';
  end if;
  if p_period_key is null or length(trim(p_period_key)) = 0 then raise exception 'A period key is required'; end if;
  if current_date < v_policy.policy_start_date then raise exception 'Policy is not yet effective (starts %)', v_policy.policy_start_date; end if;

  v_raw_days := v_policy.days_per_period;
  v_rounded_days := case v_policy.rounding
    when 'nearest_half_day' then round(v_raw_days * 2) / 2
    when 'nearest_day' then round(v_raw_days)
    else v_raw_days
  end;

  for v_emp in
    select e.id, e.join_date, lb.balance_days
    from employees e
    join leave_balances lb on lb.employee_id = e.id and lb.leave_type_id = p_leave_type_id
    where e.entity_id = v_policy.entity_id
      and e.employment_status = 'active'
      and (e.join_date is null or e.join_date + v_policy.probation_days <= current_date)
  loop
    v_balance_before := coalesce(v_emp.balance_days, 0);

    -- Carry-forward cap: only meaningful at an annual boundary — apply it to
    -- the pre-accrual balance before adding this period's days.
    if v_policy.frequency = 'annual' and v_policy.carry_forward_cap_days is not null and v_balance_before > v_policy.carry_forward_cap_days then
      v_balance_before := v_policy.carry_forward_cap_days;
    end if;

    v_balance_after := v_balance_before + v_rounded_days;
    if v_policy.max_balance_days is not null and v_balance_after > v_policy.max_balance_days then
      v_balance_after := v_policy.max_balance_days;
    end if;

    begin
      insert into leave_accrual_runs (policy_id, employee_id, leave_type_id, period_key, days_accrued, balance_before, balance_after, created_by)
      values (v_policy.id, v_emp.id, p_leave_type_id, p_period_key, v_balance_after - v_balance_before, v_balance_before, v_balance_after, auth.uid());
    exception when unique_violation then
      -- Already credited for this employee/leave type/period — idempotent
      -- no-op, move on to the next employee.
      continue;
    end;

    update leave_balances set balance_days = v_balance_after, updated_at = now()
      where employee_id = v_emp.id and leave_type_id = p_leave_type_id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
    values ('leave_balances', v_emp.id, auth.uid(), 'leave_accrual_applied',
      jsonb_build_object('leave_type_id', p_leave_type_id, 'period_key', p_period_key, 'days_accrued', v_balance_after - v_balance_before,
        'balance_before', v_balance_before, 'balance_after', v_balance_after),
      v_policy.entity_id, v_emp.id);

    v_credited := v_credited + 1;
  end loop;

  return v_credited;
end;
$$;

revoke all on function public.configure_leave_accrual_policy(uuid, text, numeric, text, numeric, numeric, int, date) from public, anon;
grant execute on function public.configure_leave_accrual_policy(uuid, text, numeric, text, numeric, numeric, int, date) to authenticated;

revoke all on function public.approve_leave_accrual_policy(uuid) from public, anon;
grant execute on function public.approve_leave_accrual_policy(uuid) to authenticated;

revoke all on function public.run_leave_accrual(uuid, text) from public, anon;
grant execute on function public.run_leave_accrual(uuid, text) to authenticated;

