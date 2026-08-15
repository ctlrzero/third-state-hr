-- ============================================================================
-- F&B HR System — Payroll & Tips Distribution Module
-- Adds: employee_compensation, payroll_runs, timesheet_entries, tips_pools,
--       payslip_deductions, payslips, run_payroll_calculation(), payroll_run_totals
-- Tip distribution rule implemented: 'equal' (hours/role-weighted reserved for later)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Harden existing views to respect the querying user's RLS, not the view
-- owner's (Postgres views default to owner-privilege row security pre-PG15
-- unless security_invoker is set — this closes that gap on compliance_alerts).
-- ----------------------------------------------------------------------------
alter view compliance_alerts set (security_invoker = on);

-- ----------------------------------------------------------------------------
-- EMPLOYEE COMPENSATION — split from `employees` on purpose: pay data is
-- restricted to owner/entity_admin only, never location_manager.
-- ----------------------------------------------------------------------------
create table employee_compensation (
  employee_id uuid primary key references employees(id) on delete cascade,
  pay_type text not null default 'hourly' check (pay_type in ('hourly', 'monthly')),
  pay_rate numeric(10,2),
  overtime_multiplier numeric(4,2) not null default 1.5,
  holiday_multiplier numeric(4,2) not null default 2.0,
  updated_at timestamptz default now()
);

create or replace function seed_employee_compensation()
returns trigger as $$
begin
  insert into employee_compensation (employee_id) values (new.id);
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_seed_employee_compensation
  after insert on employees
  for each row execute function seed_employee_compensation();

create trigger trg_compensation_updated_at
  before update on employee_compensation
  for each row execute function set_updated_at();

-- ----------------------------------------------------------------------------
-- PAYROLL RUNS (one per entity per period)
-- ----------------------------------------------------------------------------
create table payroll_runs (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid references entities(id) on delete cascade not null,
  period_start date not null,
  period_end date not null,
  status text not null default 'draft' check (status in ('draft', 'in_review', 'approved', 'paid')),
  tip_distribution_rule text not null default 'equal' check (tip_distribution_rule in ('equal', 'hours_weighted', 'role_weighted')),
  created_by uuid references auth.users(id),
  created_at timestamptz default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  unique (entity_id, period_start, period_end)
);

-- ----------------------------------------------------------------------------
-- TIMESHEET ENTRIES — manual hours entry for this foundation build.
-- Once the Scheduling/Attendance module ships, this becomes the aggregation
-- target for attendance_logs instead of manager-entered hours.
-- ----------------------------------------------------------------------------
create table timesheet_entries (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid references payroll_runs(id) on delete cascade not null,
  employee_id uuid references employees(id) not null,
  regular_hours numeric(6,2) not null default 0,
  overtime_hours numeric(6,2) not null default 0,
  holiday_hours numeric(6,2) not null default 0,
  notes text,
  unique (payroll_run_id, employee_id)
);

-- ----------------------------------------------------------------------------
-- TIPS POOLS — one row per location per payroll run
-- ----------------------------------------------------------------------------
create table tips_pools (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid references payroll_runs(id) on delete cascade not null,
  location_id uuid references locations(id) not null,
  total_amount numeric(10,2) not null default 0,
  notes text,
  updated_at timestamptz default now(),
  unique (payroll_run_id, location_id)
);

create trigger trg_tips_pools_updated_at
  before update on tips_pools
  for each row execute function set_updated_at();

-- ----------------------------------------------------------------------------
-- DEDUCTIONS (uniform cost, cash shortages, advances, etc.)
-- ----------------------------------------------------------------------------
create table payslip_deductions (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid references payroll_runs(id) on delete cascade not null,
  employee_id uuid references employees(id) not null,
  deduction_type text not null check (deduction_type in ('uniform', 'cash_shortage', 'advance', 'other')),
  amount numeric(10,2) not null,
  notes text,
  created_at timestamptz default now()
);

-- ----------------------------------------------------------------------------
-- PAYSLIPS — written only by run_payroll_calculation(), never directly
-- ----------------------------------------------------------------------------
create table payslips (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid references payroll_runs(id) on delete cascade not null,
  employee_id uuid references employees(id) not null,
  base_pay numeric(10,2) not null default 0,
  overtime_pay numeric(10,2) not null default 0,
  holiday_pay numeric(10,2) not null default 0,
  tips_share numeric(10,2) not null default 0,
  total_deductions numeric(10,2) not null default 0,
  net_pay numeric(10,2) not null default 0,
  generated_at timestamptz default now(),
  unique (payroll_run_id, employee_id)
);

-- ----------------------------------------------------------------------------
-- CALCULATION ENGINE
-- Recomputes every payslip for a run from timesheets + tips + deductions.
-- Re-runnable any time before approval (idempotent — clears & re-inserts).
-- ----------------------------------------------------------------------------
create or replace function run_payroll_calculation(p_payroll_run_id uuid)
returns void as $$
declare
  v_entity_id uuid;
  v_total_tips numeric;
  v_eligible_count int;
  v_tips_per_employee numeric;
begin
  select entity_id into v_entity_id from payroll_runs where id = p_payroll_run_id;

  if v_entity_id is null then
    raise exception 'Payroll run % not found', p_payroll_run_id;
  end if;

  -- Explicit authorization check: this function is SECURITY DEFINER and
  -- would otherwise bypass RLS entirely.
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Not authorized to run payroll for this entity';
  end if;

  select coalesce(sum(total_amount), 0) into v_total_tips
  from tips_pools where payroll_run_id = p_payroll_run_id;

  select count(*) into v_eligible_count
  from timesheet_entries where payroll_run_id = p_payroll_run_id;

  v_tips_per_employee := case when v_eligible_count = 0 then 0 else v_total_tips / v_eligible_count end;

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
      case when c.pay_type = 'hourly' then t.overtime_hours * coalesce(c.pay_rate, 0) * c.overtime_multiplier else 0 end as overtime_pay,
      case when c.pay_type = 'hourly' then t.holiday_hours * coalesce(c.pay_rate, 0) * c.holiday_multiplier else 0 end as holiday_pay
  ) calc
  left join (
    select employee_id, sum(amount) as total_deductions
    from payslip_deductions
    where payroll_run_id = p_payroll_run_id
    group by employee_id
  ) d on d.employee_id = t.employee_id
  where t.payroll_run_id = p_payroll_run_id;
end;
$$ language plpgsql security definer;

grant execute on function run_payroll_calculation(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- ROLLUP VIEW for the "Finance reviews the consolidated run" step
-- ----------------------------------------------------------------------------
create or replace view payroll_run_totals
with (security_invoker = on) as
select
  pr.id as payroll_run_id,
  pr.entity_id,
  pr.period_start,
  pr.period_end,
  pr.status,
  count(ps.id) as employee_count,
  coalesce(sum(ps.base_pay), 0) as total_base_pay,
  coalesce(sum(ps.overtime_pay), 0) as total_overtime_pay,
  coalesce(sum(ps.holiday_pay), 0) as total_holiday_pay,
  coalesce(sum(ps.tips_share), 0) as total_tips,
  coalesce(sum(ps.total_deductions), 0) as total_deductions,
  coalesce(sum(ps.net_pay), 0) as total_net_pay
from payroll_runs pr
left join payslips ps on ps.payroll_run_id = pr.id
group by pr.id;

-- ----------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------
alter table employee_compensation enable row level security;
alter table payroll_runs enable row level security;
alter table timesheet_entries enable row level security;
alter table tips_pools enable row level security;
alter table payslip_deductions enable row level security;
alter table payslips enable row level security;

-- employee_compensation: owner + entity_admin only (never location_manager)
create policy "comp_access" on employee_compensation for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from employees e where e.id = employee_compensation.employee_id and e.entity_id = my_entity()
    ))
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from employees e where e.id = employee_compensation.employee_id and e.entity_id = my_entity()
    ))
  );

-- payroll_runs: owner/entity_admin full control; location_manager can view runs in their entity
create policy "payroll_runs_select" on payroll_runs for select
  using (
    my_role() = 'owner'
    or (my_role() in ('entity_admin', 'location_manager') and payroll_runs.entity_id = my_entity())
  );
create policy "payroll_runs_modify" on payroll_runs for insert
  with check (my_role() = 'owner' or (my_role() = 'entity_admin' and payroll_runs.entity_id = my_entity()));
create policy "payroll_runs_update" on payroll_runs for update
  using (my_role() = 'owner' or (my_role() = 'entity_admin' and payroll_runs.entity_id = my_entity()))
  with check (my_role() = 'owner' or (my_role() = 'entity_admin' and payroll_runs.entity_id = my_entity()));

-- timesheet_entries: owner/entity_admin (entity-wide), location_manager (their location's employees only)
create policy "timesheet_select" on timesheet_entries for select
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()
    ))
    or (my_role() = 'location_manager' and exists (
      select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()
    ))
  );
create policy "timesheet_modify" on timesheet_entries for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()
    ))
    or (my_role() = 'location_manager' and exists (
      select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()
    ))
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()
    ))
    or (my_role() = 'location_manager' and exists (
      select 1 from employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()
    ))
  );

-- tips_pools: owner/entity_admin (entity-wide), location_manager (their own location only)
create policy "tips_select" on tips_pools for select
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.entity_id = my_entity()
    ))
    or (my_role() = 'location_manager' and tips_pools.location_id = my_location())
  );
create policy "tips_modify" on tips_pools for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.entity_id = my_entity()
    ))
    or (my_role() = 'location_manager' and tips_pools.location_id = my_location())
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.entity_id = my_entity()
    ))
    or (my_role() = 'location_manager' and tips_pools.location_id = my_location())
  );

-- payslip_deductions: owner/entity_admin only
create policy "deductions_access" on payslip_deductions for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.entity_id = my_entity()
    ))
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.entity_id = my_entity()
    ))
  );

-- payslips: read-only via RLS for owner/entity_admin; all writes go through
-- run_payroll_calculation() (SECURITY DEFINER), never direct client inserts.
create policy "payslips_select" on payslips for select
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (
      select 1 from payroll_runs pr where pr.id = payslips.payroll_run_id and pr.entity_id = my_entity()
    ))
  );

