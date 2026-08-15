-- HIGH FIX 1: run_payroll_calculation applied overtime/holiday/tip multipliers
-- automatically with no "owner reviews evidence and explicitly accepts" step,
-- contradicting BR-PAY-006 / BR-SCH-007 / D05 (manual review until formula approved).
-- HIGH FIX 2: it also did DELETE+INSERT into payslips with no guard against
-- recalculating an already-approved/paid run, so a rerun could silently destroy
-- a Published payslip -- contradicting BR-PAY-005 ("never overwrite Published").
--
-- Fix: add explicit per-run confirmation flags (default false / not approved).
-- Until an owner/entity_admin explicitly sets a flag true, the corresponding pay
-- component calculates to zero -- the underlying hours/tips evidence is still
-- visible in timesheet_entries/tips_pools for review, exactly as the design
-- intends ("show candidates as review input, apply nothing until approved").
-- Recalculation is blocked outright once the run leaves draft/in_review.

alter table public.payroll_runs
  add column if not exists overtime_holiday_pay_confirmed boolean not null default false,
  add column if not exists tips_distribution_confirmed boolean not null default false;

comment on column public.payroll_runs.overtime_holiday_pay_confirmed is
  'Owner/entity_admin has explicitly reviewed and approved applying overtime/holiday multipliers for this run (BR-PAY-006, D05). Until true, overtime_pay/holiday_pay calculate as 0.';
comment on column public.payroll_runs.tips_distribution_confirmed is
  'Owner/entity_admin has explicitly reviewed and approved the tip distribution for this run. Until true, tips_share calculates as 0.';

create or replace function public.run_payroll_calculation(p_payroll_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_entity_id uuid;
  v_status text;
  v_ot_confirmed boolean;
  v_tips_confirmed boolean;
  v_total_tips numeric;
  v_eligible_count int;
  v_tips_per_employee numeric;
  v_prior_snapshot jsonb;
begin
  select entity_id, status, overtime_holiday_pay_confirmed, tips_distribution_confirmed
    into v_entity_id, v_status, v_ot_confirmed, v_tips_confirmed
  from payroll_runs where id = p_payroll_run_id;

  if v_entity_id is null then
    raise exception 'Payroll run % not found', p_payroll_run_id;
  end if;

  -- Explicit authorization check: this function is SECURITY DEFINER and
  -- would otherwise bypass RLS entirely.
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Not authorized to run payroll for this entity';
  end if;

  -- HIGH FIX 2: never recalculate (and therefore never delete/overwrite) a
  -- payslip once the run has left draft/in_review. Corrections require a new
  -- payroll run (revision), not a silent recompute of a finalized one.
  if v_status not in ('draft', 'in_review') then
    raise exception 'Payroll run % is % -- recalculation is blocked once a run is approved or paid. Create a revision run for corrections instead.', p_payroll_run_id, v_status;
  end if;

  select coalesce(sum(total_amount), 0) into v_total_tips
  from tips_pools where payroll_run_id = p_payroll_run_id;

  select count(*) into v_eligible_count
  from timesheet_entries where payroll_run_id = p_payroll_run_id;

  v_tips_per_employee := case
    when v_eligible_count = 0 or not v_tips_confirmed then 0
    else v_total_tips / v_eligible_count
  end;

  -- Snapshot any existing payslips for this run to audit_log before recomputing,
  -- so an iterative draft recalculation still leaves a recoverable trail.
  select jsonb_agg(to_jsonb(p)) into v_prior_snapshot from payslips p where payroll_run_id = p_payroll_run_id;
  if v_prior_snapshot is not null then
    insert into audit_log(table_name, record_id, changed_by, action, old_value)
    values ('payslips', p_payroll_run_id, auth.uid(), 'recalculate_draft', v_prior_snapshot);
  end if;

  delete from payslips where payroll_run_id = p_payroll_run_id;

  insert into payslips (payroll_run_id, employee_id, base_pay, overtime_pay, holiday_pay, tips_share, total_deductions, net_pay)
  select
    p_payroll_run_id,
    t.employee_id,
    calc.base_pay,
    calc.overtime_pay,
    calc.holiday_pay,
    v_tips_per_employee,
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
    select employee_id, sum(amount) as total_deductions
    from payslip_deductions
    where payroll_run_id = p_payroll_run_id
    group by employee_id
  ) d on d.employee_id = t.employee_id
  where t.payroll_run_id = p_payroll_run_id;

  insert into audit_log(table_name, record_id, changed_by, action, new_value)
  values ('payroll_runs', p_payroll_run_id, auth.uid(), 'calculated',
    jsonb_build_object('overtime_holiday_pay_confirmed', v_ot_confirmed, 'tips_distribution_confirmed', v_tips_confirmed));
end;
$function$;

-- Belt-and-braces: also block status transitions that would let a run go back
-- to draft/in_review after being approved/paid and then get recalculated.
create or replace function public.prevent_payroll_run_status_regression()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if old.status in ('approved', 'paid') and new.status in ('draft', 'in_review') then
    raise exception 'Cannot move payroll run % from % back to % -- approved/paid runs are immutable; create a new run for corrections', old.id, old.status, new.status;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_prevent_payroll_run_status_regression on public.payroll_runs;
create trigger trg_prevent_payroll_run_status_regression
before update on public.payroll_runs
for each row execute function public.prevent_payroll_run_status_regression();

