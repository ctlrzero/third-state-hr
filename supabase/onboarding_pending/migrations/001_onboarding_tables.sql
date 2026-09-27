-- =====================================================================
-- Smart Employee Onboarding — full build (A–E)
-- Migration 001: tables and additive columns only.
-- Depends on: employees, positions, locations, entities, offers,
--             employee_documents, compensation_versions (all existing).
-- Nothing existing is dropped or renamed.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Additive columns on existing tables
-- ---------------------------------------------------------------------
alter table public.positions add column if not exists description text;
comment on column public.positions.description is
  'Job description / duties shown to the employee via get_my_job_description().';

alter table public.employees add column if not exists employee_number text;
alter table public.employees add column if not exists residential_address text;
alter table public.employees add column if not exists reporting_manager_employee_id uuid references public.employees(id);
-- Set when the employee confirms their weekly availability (onboarding portal).
alter table public.employees add column if not exists availability_confirmed_at timestamptz;
create unique index if not exists employees_number_per_entity
  on public.employees (entity_id, employee_number) where employee_number is not null;

-- ---------------------------------------------------------------------
-- Per-entity settings and employee numbering
-- ---------------------------------------------------------------------
create table public.onboarding_settings (
  entity_id uuid primary key references public.entities(id) on delete cascade,
  invitation_valid_days integer not null default 7 check (invitation_valid_days between 1 and 60),
  -- Decree-Law 33/2021 Art. 9: probation may not exceed six months.
  probation_months integer not null default 6 check (probation_months between 0 and 6),
  probation_review_days_before integer not null default 14 check (probation_review_days_before between 0 and 60),
  default_task_sla_days integer not null default 3 check (default_task_sla_days between 1 and 60),
  require_distinct_activation_approver boolean not null default true,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
comment on table public.onboarding_settings is
  'Company onboarding policy. Absent row = defaults (see _onb_settings()).';

create table public.employee_numbering (
  entity_id uuid primary key references public.entities(id) on delete cascade,
  prefix text not null default 'EMP-',
  next_value integer not null default 1 check (next_value > 0),
  pad_width integer not null default 4 check (pad_width between 1 and 10),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Templates (versioned; selection by position / employment type)
-- ---------------------------------------------------------------------
create table public.onboarding_templates (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  name text not null,
  description text,
  applies_to_employment_types public.employment_type[],
  applies_to_position_ids uuid[],
  version_number integer not null default 1,
  supersedes_template_id uuid references public.onboarding_templates(id),
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deactivated_at timestamptz
);
create unique index onboarding_templates_one_active_name
  on public.onboarding_templates (entity_id, lower(name)) where is_active;
create index onboarding_templates_entity_idx on public.onboarding_templates (entity_id);

create table public.onboarding_template_tasks (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.onboarding_templates(id) on delete cascade,
  item_key text not null check (item_key ~ '^[a-z0-9_]+$'),
  item_label text not null,
  description text,
  section text not null check (section in ('profile', 'documents', 'payment', 'acknowledgements', 'availability',
                                           'operations', 'employment', 'payroll', 'day_one', 'follow_up')),
  phase text not null default 'pre_activation' check (phase in ('pre_activation', 'day_one', 'initial_period')),
  kind text not null default 'manual' check (kind in ('manual', 'profile', 'document', 'acknowledgement',
                                                      'contract_acceptance', 'payment_details', 'compensation', 'availability')),
  owner_role text not null check (owner_role in ('employee', 'location_manager', 'hr', 'payroll', 'approver')),
  reviewer_role text check (reviewer_role in ('location_manager', 'hr', 'payroll')),
  doc_type public.document_type,
  policy_key text,
  is_required boolean not null default true,
  is_waivable boolean not null default true,
  is_statutory boolean not null default false,
  due_offset_days integer,
  depends_on text[] not null default '{}',
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (template_id, item_key),
  check (kind <> 'document' or doc_type is not null),
  check (kind <> 'acknowledgement' or policy_key is not null),
  check (not is_statutory or not is_waivable)
);
create index onboarding_template_tasks_template_idx on public.onboarding_template_tasks (template_id);

-- Policies / handbooks employees acknowledge (versioned content).
create table public.onboarding_policies (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id) on delete cascade,
  policy_key text not null check (policy_key ~ '^[a-z0-9_]+$'),
  version text not null,
  title text not null,
  body text not null,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (entity_id, policy_key, version)
);
create unique index onboarding_policies_one_active
  on public.onboarding_policies (entity_id, policy_key) where is_active;

-- ---------------------------------------------------------------------
-- Instances (one per employment commencement) and tasks
-- ---------------------------------------------------------------------
create table public.onboarding_instances (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  entity_id uuid not null references public.entities(id),
  home_location_id uuid references public.locations(id),
  position_id uuid references public.positions(id),
  reporting_manager_employee_id uuid references public.employees(id),
  employment_type public.employment_type,
  proposed_start_date date,
  template_id uuid references public.onboarding_templates(id),
  template_version integer,
  template_snapshot jsonb not null default '{}'::jsonb,
  source text not null check (source in ('offer', 'direct_hire', 'existing_employee')),
  offer_id uuid references public.offers(id),
  source_reason text,
  status text not null default 'initiated' check (status in (
    'initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked',
    'ready_for_activation', 'activated', 'day_one', 'in_progress', 'completed', 'cancelled', 'withdrawn')),
  row_version integer not null default 1,
  status_changed_at timestamptz not null default now(),
  activation_operation_id uuid,
  activated_at timestamptz,
  activated_by uuid references auth.users(id),
  activation_reason text,
  actual_start_date date,
  day_one_outcome text check (day_one_outcome in ('started', 'no_show', 'delayed')),
  day_one_recorded_at timestamptz,
  day_one_recorded_by uuid references auth.users(id),
  completed_at timestamptz,
  closed_by uuid references auth.users(id),
  closure_snapshot jsonb,
  ended_at timestamptz,
  ended_by uuid references auth.users(id),
  end_reason text,
  started_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index onboarding_instances_one_open_per_employee
  on public.onboarding_instances (employee_id) where status not in ('completed', 'cancelled', 'withdrawn');
create index onboarding_instances_entity_idx on public.onboarding_instances (entity_id, status);
create index onboarding_instances_location_idx on public.onboarding_instances (home_location_id);
create index onboarding_instances_offer_idx on public.onboarding_instances (offer_id);
comment on table public.onboarding_instances is
  'Onboarding lifecycle, separate from employees.employment_status. Status changes only through onboarding RPCs (row_version guards concurrent edits). Holds no pay data.';

create table public.onboarding_tasks (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid not null references public.onboarding_instances(id) on delete cascade,
  template_task_id uuid references public.onboarding_template_tasks(id),
  item_key text not null,
  item_label text not null,
  description text,
  section text not null,
  phase text not null,
  kind text not null,
  owner_role text not null,
  reviewer_role text,
  doc_type public.document_type,
  policy_key text,
  is_required boolean not null default true,
  is_waivable boolean not null default true,
  is_statutory boolean not null default false,
  status text not null default 'not_started' check (status in (
    'not_started', 'in_progress', 'submitted', 'changes_required', 'approved', 'waived', 'cancelled')),
  due_date date,
  evidence jsonb,
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_reason text,
  waived_by uuid references auth.users(id),
  waived_at timestamptz,
  waived_reason text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (instance_id, item_key)
);
create index onboarding_tasks_instance_idx on public.onboarding_tasks (instance_id, phase);
create index onboarding_tasks_due_idx on public.onboarding_tasks (due_date) where status not in ('approved', 'waived', 'cancelled');

create table public.onboarding_task_dependencies (
  task_id uuid not null references public.onboarding_tasks(id) on delete cascade,
  depends_on_task_id uuid not null references public.onboarding_tasks(id) on delete cascade,
  primary key (task_id, depends_on_task_id),
  check (task_id <> depends_on_task_id)
);

-- ---------------------------------------------------------------------
-- Sensitive: pay intended at activation (never on onboarding_instances,
-- which branch managers and the employee can read).
-- ---------------------------------------------------------------------
create table public.onboarding_pending_compensation (
  instance_id uuid primary key references public.onboarding_instances(id) on delete cascade,
  pay_type text not null check (pay_type in ('monthly', 'hourly')),
  basic_monthly numeric(12,2) check (basic_monthly is null or basic_monthly > 0),
  hourly_rate numeric(12,2) check (hourly_rate is null or hourly_rate > 0),
  overtime_eligible boolean not null default true,
  effective_from date,
  reason text,
  offer_amount numeric(12,2),
  variance_reason text,
  status text not null default 'pending_review' check (status in ('pending_review', 'approved', 'changes_required')),
  set_by uuid references auth.users(id),
  set_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_reason text,
  check ((pay_type = 'monthly' and basic_monthly is not null) or (pay_type = 'hourly' and hourly_rate is not null))
);

-- Sensitive: salary payment details (payroll roles and the employee only).
create table public.employee_payment_details (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  method text not null check (method in ('bank_transfer', 'exchange_house', 'wps_card', 'cash')),
  bank_name text,
  account_name text,
  iban text check (iban is null or iban ~ '^AE[0-9]{21}$'),
  routing_code text,
  status text not null default 'submitted' check (status in ('submitted', 'verified', 'rejected', 'superseded')),
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz not null default now(),
  verified_by uuid references auth.users(id),
  verified_at timestamptz,
  rejection_reason text,
  check (method not in ('bank_transfer') or iban is not null)
);
create unique index employee_payment_details_one_live
  on public.employee_payment_details (employee_id) where status in ('submitted', 'verified');

-- ---------------------------------------------------------------------
-- Invitations, section submissions, reviews, exceptions
-- ---------------------------------------------------------------------
create table public.onboarding_invitations (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid not null references public.onboarding_instances(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  sent_to_email text not null,
  access_grant_id uuid references public.access_grants(id),
  status text not null default 'issued' check (status in ('issued', 'accepted', 'expired', 'revoked')),
  issued_by uuid references auth.users(id),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  accepted_at timestamptz,
  revoked_by uuid references auth.users(id),
  revoked_at timestamptz,
  revoke_reason text,
  reissue_of uuid references public.onboarding_invitations(id)
);
create unique index onboarding_invitations_one_live
  on public.onboarding_invitations (instance_id) where status = 'issued';

create table public.onboarding_section_submissions (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid not null references public.onboarding_instances(id) on delete cascade,
  section text not null,
  version integer not null,
  status text not null default 'submitted' check (status in ('submitted', 'approved', 'changes_required', 'rejected')),
  snapshot jsonb not null default '{}'::jsonb,
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz not null default now(),
  unique (instance_id, section, version)
);

create table public.onboarding_reviews (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid not null references public.onboarding_instances(id) on delete cascade,
  section text not null,
  submission_id uuid references public.onboarding_section_submissions(id),
  task_id uuid references public.onboarding_tasks(id),
  reviewer_id uuid not null references auth.users(id),
  reviewer_role text not null,
  decision text not null check (decision in ('approved', 'changes_required', 'rejected')),
  reason text,
  before_state jsonb,
  after_state jsonb,
  created_at timestamptz not null default now(),
  check (decision = 'approved' or length(btrim(coalesce(reason, ''))) > 0)
);
create index onboarding_reviews_instance_idx on public.onboarding_reviews (instance_id);

create table public.onboarding_exceptions (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid not null references public.onboarding_instances(id) on delete cascade,
  exception_type text not null check (exception_type in (
    'candidate_withdrew', 'duplicate_identity', 'start_date_change', 'setup_change', 'invitation_problem',
    'cannot_complete_digitally', 'document_problem', 'compensation_variance', 'reviewer_unavailable',
    'no_show', 'delayed_start', 'activation_retry', 'probation_not_confirmed', 'other')),
  is_blocking boolean not null default true,
  description text not null,
  owner_role text not null check (owner_role in ('location_manager', 'hr', 'payroll', 'approver')),
  due_date date,
  status text not null default 'open' check (status in ('open', 'resolved', 'cancelled')),
  resolution text,
  raised_by uuid references auth.users(id),
  raised_at timestamptz not null default now(),
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz
);
create index onboarding_exceptions_open_idx on public.onboarding_exceptions (instance_id) where status = 'open';

-- ---------------------------------------------------------------------
-- Acknowledgements, contract acceptance, probation
-- ---------------------------------------------------------------------
create table public.employee_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  onboarding_instance_id uuid references public.onboarding_instances(id),
  policy_id uuid not null references public.onboarding_policies(id),
  policy_key text not null,
  policy_version text not null,
  acknowledged_by uuid not null references auth.users(id),
  acknowledged_at timestamptz not null default now(),
  unique (employee_id, policy_id)
);

create table public.employee_contract_acceptances (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  onboarding_instance_id uuid not null references public.onboarding_instances(id),
  document_id uuid not null references public.employee_documents(id),
  document_version integer not null,
  accepted_by uuid not null references auth.users(id),
  accepted_at timestamptz not null default now()
);
-- One acceptance per instance per contract document version.
create unique index employee_contract_acceptances_one_per_doc
  on public.employee_contract_acceptances (onboarding_instance_id, document_id);

create table public.employee_probation_periods (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  onboarding_instance_id uuid references public.onboarding_instances(id),
  start_date date not null,
  end_date date not null,
  review_due_date date not null,
  status text not null default 'active' check (status in ('active', 'confirmed', 'extended', 'not_confirmed')),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  decision_effective_date date,
  decision_reason text,
  previous_period_id uuid references public.employee_probation_periods(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date >= start_date)
);
create unique index employee_probation_periods_one_active
  on public.employee_probation_periods (employee_id) where status = 'active';
-- One probation start per onboarding instance (activation retries never duplicate it).
create unique index employee_probation_periods_one_initial_per_instance
  on public.employee_probation_periods (onboarding_instance_id) where previous_period_id is null and onboarding_instance_id is not null;

create table public.employee_probation_reviews (
  id uuid primary key default gen_random_uuid(),
  probation_period_id uuid not null references public.employee_probation_periods(id) on delete cascade,
  reviewer_id uuid not null references auth.users(id),
  reviewer_role text not null,
  recommendation text not null check (recommendation in ('confirm', 'extend', 'not_confirm')),
  comments text not null check (length(btrim(comments)) > 0),
  ratings jsonb,
  created_at timestamptz not null default now()
);

commit;
