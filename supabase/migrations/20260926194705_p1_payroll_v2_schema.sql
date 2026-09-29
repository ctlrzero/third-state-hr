-- Payroll v2 — schema (see supabase/migrations/20260927090000_p1_payroll_v2_schema.sql)
alter table public.employees add column if not exists last_working_date date;

alter table public.leave_types
  add column if not exists payroll_treatment text not null default 'paid'
    check (payroll_treatment in ('paid', 'unpaid', 'tiered'));
update public.leave_types set payroll_treatment = 'unpaid'
 where name ilike 'unpaid%' or name ilike 'hajj%' or name ilike 'study%';
update public.leave_types set payroll_treatment = 'tiered' where name ilike 'sick%';

create table public.payroll_settings (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  effective_from date not null,
  pay_day smallint not null default 1 check (pay_day between 1 and 28),
  day_rate_basis text not null default 'calendar_days' check (day_rate_basis in ('calendar_days', 'fixed_30')),
  approval_mode text not null default 'two_step'
    check (approval_mode in ('two_step', 'owner_single_step', 'review_then_approve')),
  unpaid_leave_basis text not null default 'basic_and_allowances'
    check (unpaid_leave_basis in ('basic', 'basic_and_allowances')),
  overtime_hour_divisor numeric(6,2) not null default 240 check (overtime_hour_divisor > 0),
  overtime_multiplier numeric(4,2) not null default 1.25 check (overtime_multiplier >= 1),
  night_overtime_multiplier numeric(4,2) not null default 1.50 check (night_overtime_multiplier >= 1),
  holiday_multiplier numeric(4,2) not null default 1.50 check (holiday_multiplier >= 1),
  max_deduction_pct numeric(5,2) not null default 50 check (max_deduction_pct between 0 and 100),
  default_payment_method text not null default 'bank_transfer'
    check (default_payment_method in ('bank_transfer', 'cash', 'cheque', 'exchange_house', 'wps_agent')),
  payslip_note text,
  confirmed boolean not null default false,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (entity_id, effective_from)
);
comment on table public.payroll_settings is
  'Effective-dated payroll policy per company. confirmed=false means the owner has not reviewed the defaults yet. pay_day = day of the following month (WPS due date is the 1st, MR 340/2026).';

create table public.compensation_versions (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  effective_from date not null,
  pay_type text not null check (pay_type in ('monthly', 'hourly')),
  basic_monthly numeric(12,2) check (basic_monthly is null or basic_monthly >= 0),
  hourly_rate numeric(12,2) check (hourly_rate is null or hourly_rate >= 0),
  overtime_eligible boolean not null default true,
  reason text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (employee_id, effective_from),
  check ((pay_type = 'monthly' and basic_monthly is not null) or (pay_type = 'hourly' and hourly_rate is not null))
);
create index on public.compensation_versions (employee_id, effective_from desc);

insert into public.compensation_versions (employee_id, effective_from, pay_type, basic_monthly, hourly_rate, overtime_eligible, reason)
select c.employee_id, coalesce(e.join_date, date '2000-01-01'), c.pay_type,
       case when c.pay_type = 'monthly' then c.pay_rate end,
       case when c.pay_type = 'hourly' then c.pay_rate end,
       true, 'Migrated from employee_compensation'
  from public.employee_compensation c
  join public.employees e on e.id = c.employee_id
 where c.pay_rate is not null
on conflict do nothing;

create table public.compensation_components (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('earning', 'deduction')),
  code text not null check (code in ('housing', 'transport', 'food', 'phone', 'other_allowance',
                                     'accommodation_deduction', 'other_deduction')),
  label text not null,
  monthly_amount numeric(12,2) not null check (monthly_amount > 0),
  prorate boolean not null default true,
  effective_from date not null,
  effective_to date,
  reason text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);
create index on public.compensation_components (employee_id, effective_from);

create table public.payroll_periods (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  kind text not null default 'regular' check (kind in ('regular', 'off_cycle')),
  period_start date not null,
  period_end date not null,
  label text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (period_end >= period_start)
);
create unique index payroll_periods_one_regular_month
  on public.payroll_periods (entity_id, period_start) where kind = 'regular';

create table public.payroll_records (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id) on delete restrict,
  employee_id uuid not null references public.employees(id),
  record_status text not null default 'draft' check (record_status in ('draft', 'in_review', 'approved')),
  calc_version integer not null default 0,
  approved_version integer,
  gross numeric(12,2) not null default 0,
  deductions numeric(12,2) not null default 0,
  net numeric(12,2) not null default 0,
  attention jsonb not null default '[]'::jsonb,
  calculated_at timestamptz,
  calculated_by uuid references auth.users(id),
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  returned_reason text,
  published_at timestamptz,
  published_by uuid references auth.users(id),
  supersedes_record_id uuid references public.payroll_records(id),
  superseded_by_record_id uuid references public.payroll_records(id) deferrable initially deferred,
  correction_reason text,
  created_at timestamptz not null default now()
);
create unique index payroll_records_one_live
  on public.payroll_records (period_id, employee_id) where superseded_by_record_id is null;
create index on public.payroll_records (employee_id);

create table public.payroll_lines (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.payroll_records(id) on delete cascade,
  kind text not null check (kind in ('earning', 'deduction', 'info')),
  code text not null,
  label text not null,
  quantity numeric(12,4),
  rate numeric(12,4),
  amount numeric(12,2) not null default 0,
  source_type text not null,
  source_id uuid,
  explanation text not null,
  sort smallint not null default 0
);
create index on public.payroll_lines (record_id);
create unique index payroll_lines_one_per_source
  on public.payroll_lines (record_id, source_type, source_id, code) where source_id is not null;

create table public.payroll_hours (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  regular_hours numeric(7,2) not null default 0 check (regular_hours >= 0),
  overtime_hours numeric(7,2) not null default 0 check (overtime_hours >= 0),
  night_overtime_hours numeric(7,2) not null default 0 check (night_overtime_hours >= 0),
  holiday_hours numeric(7,2) not null default 0 check (holiday_hours >= 0),
  status text not null default 'pending' check (status in ('pending', 'confirmed')),
  source text not null default 'manual' check (source in ('manual', 'attendance')),
  notes text,
  entered_by uuid references auth.users(id),
  entered_at timestamptz not null default now(),
  confirmed_by uuid references auth.users(id),
  confirmed_at timestamptz,
  unique (period_id, employee_id)
);

create table public.payroll_adjustments (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  kind text not null check (kind in ('earning', 'deduction')),
  code text not null check (code in ('bonus', 'reimbursement', 'correction', 'commission', 'other_earning',
                                     'cash_shortage', 'uniform', 'damage', 'fine', 'other_deduction',
                                     'gratuity', 'leave_encashment', 'notice_pay')),
  amount numeric(12,2) not null check (amount > 0),
  reason text not null check (length(btrim(reason)) > 0),
  batch_id uuid,
  allocation text not null default 'individual' check (allocation in ('individual', 'per_employee', 'distributed')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references auth.users(id),
  void_reason text
);
create index on public.payroll_adjustments (period_id, employee_id);

create table public.tip_role_points (
  position_id uuid primary key references public.positions(id) on delete cascade,
  points numeric(6,2) not null check (points > 0),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table public.tip_pools (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  pool_start date not null,
  pool_end date not null,
  total_amount numeric(12,2) not null check (total_amount >= 0),
  settlement text not null check (settlement in ('payroll', 'cash_paid')),
  method text not null check (method in ('equal', 'hours', 'role_points', 'hours_points')),
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references auth.users(id),
  check (pool_end >= pool_start)
);
create unique index tip_pools_one_live
  on public.tip_pools (period_id, location_id, pool_start, pool_end, settlement) where voided_at is null;

create table public.tip_allocations (
  id uuid primary key default gen_random_uuid(),
  pool_id uuid not null references public.tip_pools(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  hours numeric(8,2),
  points numeric(6,2),
  weight numeric(14,4) not null,
  amount numeric(12,2) not null check (amount >= 0),
  unique (pool_id, employee_id)
);

create table public.salary_advances (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  employee_id uuid not null references public.employees(id),
  amount numeric(12,2) not null check (amount > 0),
  disbursed_on date not null,
  disbursement_method text not null default 'cash'
    check (disbursement_method in ('cash', 'bank_transfer', 'cheque', 'payroll')),
  repayment_start date not null,
  instalments integer not null check (instalments between 1 and 60),
  instalment_amount numeric(12,2) not null check (instalment_amount > 0),
  status text not null default 'active' check (status in ('active', 'settled', 'cancelled')),
  reason text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  cancelled_reason text
);

create table public.advance_repayments (
  id uuid primary key default gen_random_uuid(),
  advance_id uuid not null references public.salary_advances(id),
  record_id uuid not null references public.payroll_records(id),
  period_id uuid not null references public.payroll_periods(id),
  amount numeric(12,2) not null check (amount > 0),
  created_at timestamptz not null default now()
);
create unique index advance_repayments_one_per_record on public.advance_repayments (advance_id, record_id);

create table public.payroll_payments (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.payroll_records(id),
  amount numeric(12,2) not null check (amount > 0),
  paid_on date not null,
  method text not null check (method in ('bank_transfer', 'cash', 'cheque', 'exchange_house', 'wps_agent')),
  reference text,
  status text not null check (status in ('recorded', 'failed')),
  failure_reason text,
  batch_id uuid,
  idempotency_key text not null unique,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index on public.payroll_payments (record_id);

create table public.payroll_exports (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id),
  total_amount numeric(14,2) not null,
  employee_count integer not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  invalidated_at timestamptz,
  invalidated_reason text
);
create table public.payroll_export_items (
  export_id uuid not null references public.payroll_exports(id) on delete cascade,
  record_id uuid not null references public.payroll_records(id),
  amount numeric(12,2) not null,
  primary key (export_id, record_id)
);

create table public.payroll_permissions (
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_id uuid not null references public.entities(id) on delete cascade,
  preset text not null check (preset in ('payroll_admin', 'accountant')),
  can_single_step_approve boolean not null default false,
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default now(),
  primary key (user_id, entity_id)
);

do $$
declare t text;
begin
  foreach t in array array['payroll_settings','compensation_versions','compensation_components','payroll_periods',
    'payroll_records','payroll_lines','payroll_hours','payroll_adjustments','tip_role_points','tip_pools',
    'tip_allocations','salary_advances','advance_repayments','payroll_payments','payroll_exports',
    'payroll_export_items','payroll_permissions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
  end loop;
end $$;;
