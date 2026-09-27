-- Validation: migrations 001-010 + tests in ONE transaction. Always rolls back.
-- Paste the whole file into the Supabase SQL editor and run. Expected: an error
-- starting 'ONBOARDING_TESTS n passed / n total'. Any other error = a bug; nothing is kept either way.
begin;
-- ===== migrations/001_onboarding_tables.sql
-- =====================================================================
-- Smart Employee Onboarding — full build (A–E)
-- Migration 001: tables and additive columns only.
-- Depends on: employees, positions, locations, entities, offers,
--             employee_documents, compensation_versions (all existing).
-- Nothing existing is dropped or renamed.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Additive columns on existing tables
-- ---------------------------------------------------------------------
alter table public.positions add column if not exists description text;
comment on column public.positions.description is
  'Job description / duties shown to the employee via get_my_job_description().';

alter table public.employees add column if not exists employee_number text;
alter table public.employees add column if not exists residential_address text;
alter table public.employees add column if not exists reporting_manager_employee_id uuid references public.employees(id);
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
                                                      'contract_acceptance', 'payment_details', 'compensation')),
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

-- ===== migrations/002_onboarding_core.sql
-- =====================================================================
-- Migration 002: shared core — scope checks, audit, state machine,
-- task generation, derived task status and the readiness engine.
-- All internal helpers (_onb_*) are revoked from API roles; only the
-- public RPCs in 003–007 call them.
-- Depends on: 001, payroll v2 (payroll_can), employee_missing_key_documents.
-- =====================================================================


-- ------------------------------------------------------------ settings
create or replace function public._onb_settings(p_entity_id uuid)
returns public.onboarding_settings
language plpgsql stable security definer set search_path to '' as $$
declare s public.onboarding_settings;
begin
  select * into s from public.onboarding_settings where entity_id = p_entity_id;
  if s.entity_id is null then
    s.entity_id := p_entity_id;
    s.invitation_valid_days := 7;
    s.probation_months := 6;
    s.probation_review_days_before := 14;
    s.default_task_sla_days := 3;
    s.require_distinct_activation_approver := true;
  end if;
  return s;
end;
$$;

-- --------------------------------------------------------------- scope
-- Capabilities on one instance:
--   view      see the instance (owner; entity admin own entity; branch manager own branch; payroll reviewers)
--   manage    HR / entity admin actions (owner; entity admin own entity)
--   operate   branch operations (branch manager own branch) or manage
--   payroll   payroll-readiness review (payroll_can(entity, 'approve'))
--   approve   final activation (owner; entity admin own entity)
create or replace function public._onb_can(p_instance_id uuid, p_cap text)
returns boolean
language plpgsql stable security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  v_role public.user_role := public.my_role();
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.id is null or v_role is null or not public.is_active_user() then return false; end if;
  if p_cap in ('manage', 'approve') then
    return v_role = 'owner' or (v_role = 'entity_admin' and i.entity_id = public.my_entity());
  elsif p_cap = 'operate' then
    return v_role = 'owner' or (v_role = 'entity_admin' and i.entity_id = public.my_entity())
        or (v_role = 'location_manager' and i.home_location_id = public.my_location());
  elsif p_cap = 'payroll' then
    return public.payroll_can(i.entity_id, 'approve');
  elsif p_cap = 'view' then
    return v_role = 'owner' or (v_role = 'entity_admin' and i.entity_id = public.my_entity())
        or (v_role = 'location_manager' and i.home_location_id = public.my_location())
        or public.payroll_can(i.entity_id, 'approve');
  end if;
  return false;
end;
$$;

create or replace function public._onb_require(p_instance_id uuid, p_cap text)
returns void language plpgsql stable security definer set search_path to '' as $$
begin
  if not public._onb_can(p_instance_id, p_cap) then
    raise exception 'You do not have permission to do this on this onboarding (%)', p_cap using errcode = '42501';
  end if;
end;
$$;

create or replace function public._onb_is_self(p_instance_id uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.onboarding_instances i
                  where i.id = p_instance_id and i.employee_id = public.my_employee_id() and public.is_active_user());
$$;

-- Can the caller act as this task's owner role?
create or replace function public._onb_can_own(p_instance_id uuid, p_owner_role text)
returns boolean language sql stable security definer set search_path to '' as $$
  select case p_owner_role
    when 'employee' then public._onb_is_self(p_instance_id) or public._onb_can(p_instance_id, 'manage')
    when 'location_manager' then public._onb_can(p_instance_id, 'operate')
    when 'hr' then public._onb_can(p_instance_id, 'manage')
    when 'payroll' then public._onb_can(p_instance_id, 'payroll')
    when 'approver' then public._onb_can(p_instance_id, 'approve')
    else false end;
$$;

create or replace function public._onb_can_review(p_instance_id uuid, p_reviewer_role text)
returns boolean language sql stable security definer set search_path to '' as $$
  select case p_reviewer_role
    when 'location_manager' then public._onb_can(p_instance_id, 'operate')
    when 'hr' then public._onb_can(p_instance_id, 'manage')
    when 'payroll' then public._onb_can(p_instance_id, 'payroll')
    else false end;
$$;

-- --------------------------------------------------------------- audit
-- Every onboarding audit row carries the transaction's operation id
-- (set once per call via _onb_op()), so one activation or review can be
-- traced across every table it touched.
create or replace function public._onb_op()
returns uuid language plpgsql security definer set search_path to '' as $$
declare v text := current_setting('app.onboarding_operation_id', true);
begin
  if v is null or v = '' then
    v := gen_random_uuid()::text;
    perform set_config('app.onboarding_operation_id', v, true);
  end if;
  return v::uuid;
end;
$$;

create or replace function public._onb_audit(p_instance_id uuid, p_table text, p_record_id uuid, p_action text,
                                              p_old jsonb, p_new jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values (p_table, p_record_id, auth.uid(), p_action, p_old,
          coalesce(p_new, '{}'::jsonb) || jsonb_build_object('operation_id', public._onb_op(), 'onboarding_instance_id', p_instance_id),
          i.entity_id, i.home_location_id, i.employee_id);
end;
$$;

-- ------------------------------------------------------- state machine
create or replace function public._onb_transition_allowed(p_from text, p_to text)
returns boolean language sql immutable set search_path to '' as $$
  select case
    when p_from = p_to then false
    when p_from in ('completed', 'cancelled', 'withdrawn') then false
    when p_to in ('cancelled', 'withdrawn') then p_from in ('initiated', 'awaiting_employee', 'under_review',
                                                           'changes_required', 'blocked', 'ready_for_activation')
    when p_from in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation')
      then p_to in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation', 'activated')
           and (p_to <> 'activated' or p_from = 'ready_for_activation')
    when p_from = 'activated' then p_to in ('day_one', 'in_progress')
    when p_from = 'day_one' then p_to in ('in_progress', 'completed')
    when p_from = 'in_progress' then p_to = 'completed'
    else false end;
$$;

create or replace function public._onb_set_status(p_instance_id uuid, p_to text, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status = p_to then return; end if;
  if not public._onb_transition_allowed(i.status, p_to) then
    raise exception 'Onboarding cannot move from % to %', i.status, p_to using errcode = '22023';
  end if;
  update public.onboarding_instances
     set status = p_to, status_changed_at = now(), row_version = row_version + 1, updated_at = now()
   where id = p_instance_id;
  perform public._onb_audit(p_instance_id, 'onboarding_instances', p_instance_id, 'onboarding_status_changed',
    jsonb_build_object('status', i.status), jsonb_build_object('status', p_to, 'reason', p_reason));
end;
$$;

create or replace function public._onb_touch(p_instance_id uuid)
returns void language sql security definer set search_path to '' as $$
  update public.onboarding_instances set row_version = row_version + 1, updated_at = now() where id = p_instance_id;
$$;

-- ---------------------------------------------------- task generation
-- Creates the instance's tasks for one phase from its template snapshot.
-- Idempotent (unique instance_id + item_key). Pre-activation due dates
-- count from the onboarding start; day-one / initial-period tasks from
-- the employee's start date.
create or replace function public._onb_generate_tasks(p_instance_id uuid, p_phase text)
returns integer language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  s public.onboarding_settings;
  t jsonb;
  v_anchor date;
  v_n integer := 0;
  v_id uuid;
  d text;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  s := public._onb_settings(i.entity_id);
  v_anchor := case when p_phase = 'pre_activation' then (i.started_at at time zone 'Asia/Dubai')::date
                   else coalesce(i.actual_start_date, i.proposed_start_date, (now() at time zone 'Asia/Dubai')::date) end;
  for t in select * from jsonb_array_elements(coalesce(i.template_snapshot -> 'tasks', '[]'::jsonb)) loop
    continue when t ->> 'phase' <> p_phase;
    insert into public.onboarding_tasks (instance_id, template_task_id, item_key, item_label, description, section, phase,
      kind, owner_role, reviewer_role, doc_type, policy_key, is_required, is_waivable, is_statutory, due_date, sort_order)
    values (i.id, nullif(t ->> 'id', '')::uuid, t ->> 'item_key', t ->> 'item_label', t ->> 'description', t ->> 'section',
      t ->> 'phase', t ->> 'kind', t ->> 'owner_role', nullif(t ->> 'reviewer_role', ''),
      nullif(t ->> 'doc_type', '')::public.document_type, nullif(t ->> 'policy_key', ''),
      coalesce((t ->> 'is_required')::boolean, true), coalesce((t ->> 'is_waivable')::boolean, true),
      coalesce((t ->> 'is_statutory')::boolean, false),
      v_anchor + coalesce(nullif(t ->> 'due_offset_days', '')::integer, s.default_task_sla_days),
      coalesce((t ->> 'sort_order')::integer, 0))
    on conflict (instance_id, item_key) do nothing
    returning id into v_id;
    if v_id is not null then v_n := v_n + 1; end if;
  end loop;
  -- Dependencies by item_key (only between tasks that exist).
  insert into public.onboarding_task_dependencies (task_id, depends_on_task_id)
  select ot.id, dep.id
    from jsonb_array_elements(coalesce(i.template_snapshot -> 'tasks', '[]'::jsonb)) t2
    cross join lateral jsonb_array_elements_text(coalesce(t2 -> 'depends_on', '[]'::jsonb)) k(key)
    join public.onboarding_tasks ot on ot.instance_id = i.id and ot.item_key = t2 ->> 'item_key'
    join public.onboarding_tasks dep on dep.instance_id = i.id and dep.item_key = k.key
   where t2 ->> 'phase' = p_phase
  on conflict do nothing;
  return v_n;
end;
$$;

-- ---------------------------------------------- derived task statuses
-- Tasks backed by authoritative records follow those records; nobody
-- can mark a document "done" without the document itself.
create or replace function public._onb_sync_derived(p_instance_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  t record;
  v_new text;
  v_doc record;
  v_pay record;
  v_comp record;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  select * into e from public.employees where id = i.employee_id;
  for t in select * from public.onboarding_tasks where instance_id = i.id
             and kind in ('document', 'acknowledgement', 'contract_acceptance', 'payment_details', 'compensation')
             and status not in ('waived', 'cancelled')
  loop
    v_new := t.status;
    if t.kind = 'document' then
      if t.doc_type = 'visa' and lower(btrim(coalesce(e.nationality, ''))) in ('uae', 'emirati', 'united arab emirates') then
        v_new := 'approved';  -- visa not required for UAE nationals (same rule as employee_missing_key_documents)
      else
        select d.review_status, d.is_current, d.expiry_date into v_doc
          from public.employee_documents d
         where d.employee_id = e.id and d.doc_type = t.doc_type and d.upload_confirmed
           and d.review_status in ('approved', 'pending_review', 'rejected') and (d.is_current or d.review_status <> 'approved')
         order by (d.review_status = 'approved' and d.is_current) desc, d.submitted_at desc limit 1;
        v_new := case
          when v_doc.review_status = 'approved' and v_doc.is_current and (v_doc.expiry_date is null or v_doc.expiry_date >= v_today) then 'approved'
          when v_doc.review_status = 'approved' then 'changes_required'  -- expired
          when v_doc.review_status = 'pending_review' then 'submitted'
          when v_doc.review_status = 'rejected' then 'changes_required'
          else case when t.status = 'in_progress' then 'in_progress' else 'not_started' end end;
      end if;
    elsif t.kind = 'acknowledgement' then
      v_new := case when exists (select 1 from public.employee_acknowledgements a
                                   join public.onboarding_policies p on p.id = a.policy_id
                                  where a.employee_id = e.id and p.entity_id = i.entity_id and p.policy_key = t.policy_key and p.is_active)
                    then 'approved' else 'not_started' end;
    elsif t.kind = 'contract_acceptance' then
      v_new := case when exists (
                      select 1 from public.employee_contract_acceptances a
                        join public.employee_documents d on d.id = a.document_id
                       where a.onboarding_instance_id = i.id and d.is_current and d.review_status = 'approved')
                    then 'approved' else 'not_started' end;
    elsif t.kind = 'payment_details' then
      select status into v_pay from public.employee_payment_details
       where employee_id = e.id order by submitted_at desc limit 1;
      v_new := case v_pay.status when 'verified' then 'approved' when 'submitted' then 'submitted'
                                 when 'rejected' then 'changes_required' else 'not_started' end;
    elsif t.kind = 'compensation' then
      select status into v_comp from public.onboarding_pending_compensation where instance_id = i.id;
      v_new := case v_comp.status when 'approved' then 'approved' when 'pending_review' then 'submitted'
                                  when 'changes_required' then 'changes_required' else 'not_started' end;
    end if;
    if v_new is distinct from t.status then
      update public.onboarding_tasks
         set status = v_new, updated_at = now(),
             reviewed_at = case when v_new = 'approved' then coalesce(reviewed_at, now()) else reviewed_at end
       where id = t.id;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------- readiness engine
-- Server-derived. The client never sends "ready". p_audience = 'full'
-- (HR/approver/payroll) or 'operations' (branch manager: no pay/bank
-- detail in messages) or 'employee'.
create or replace function public._onb_readiness(p_instance_id uuid, p_audience text default 'full')
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  b jsonb := '[]'::jsonb;
  w jsonb := '[]'::jsonb;
  t record;
  x record;
  v_total integer;
  v_done integer;
  v_missing text[];
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_inv record;
  v_comp record;
  v_next text;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  select * into e from public.employees where id = i.employee_id;
  perform public._onb_sync_derived(p_instance_id);

  -- Setup completeness
  if i.home_location_id is null then b := b || jsonb_build_object('code', 'no_branch', 'owner_role', 'hr', 'message', 'Home branch is not set.'); end if;
  if i.position_id is null then b := b || jsonb_build_object('code', 'no_position', 'owner_role', 'hr', 'message', 'Job / position is not set.'); end if;
  if i.reporting_manager_employee_id is null then b := b || jsonb_build_object('code', 'no_manager', 'owner_role', 'hr', 'message', 'Reporting manager is not set.'); end if;
  if i.employment_type is null then b := b || jsonb_build_object('code', 'no_employment_type', 'owner_role', 'hr', 'message', 'Employment type is not set.'); end if;
  if i.proposed_start_date is null then
    b := b || jsonb_build_object('code', 'no_start_date', 'owner_role', 'hr', 'message', 'Start date is not set.');
  elsif i.proposed_start_date < v_today - 30 then
    b := b || jsonb_build_object('code', 'start_date_invalid', 'owner_role', 'hr', 'message', 'Start date is more than 30 days in the past; confirm or change it.');
  end if;

  -- Duplicate identity inside the same company (count only; nothing from other companies)
  if exists (select 1 from public.employees d
              where d.entity_id = e.entity_id and d.id <> e.id and d.employment_status <> 'inactive'
                and ((e.email is not null and lower(btrim(d.email)) = lower(btrim(e.email)))
                     or (e.phone is not null and regexp_replace(d.phone, '\D', '', 'g') = regexp_replace(e.phone, '\D', '', 'g')))) then
    b := b || jsonb_build_object('code', 'duplicate_identity', 'owner_role', 'hr',
      'message', 'Another current employee has the same email or phone. Resolve the duplicate first.');
  end if;

  -- Mandatory pre-activation tasks
  for t in select * from public.onboarding_tasks where instance_id = i.id and phase = 'pre_activation'
             and is_required and status not in ('approved', 'waived', 'cancelled') order by sort_order
  loop
    b := b || jsonb_build_object('code', 'task_' || t.status, 'task_id', t.id, 'owner_role', t.owner_role,
      'message', case
        when p_audience = 'operations' and t.section in ('payment', 'payroll') then 'A payroll item is outstanding.'
        when t.status = 'changes_required' then format('%s: changes required.', t.item_label)
        when t.status = 'submitted' then format('%s: awaiting review.', t.item_label)
        else format('%s: not done yet.', t.item_label) end,
      'due_date', t.due_date);
  end loop;

  -- Statutory key documents (same gate set_employee_status enforces)
  v_missing := public.employee_missing_key_documents(e.id);
  if cardinality(v_missing) > 0 then
    b := b || jsonb_build_object('code', 'key_documents', 'owner_role', 'hr',
      'message', 'Approved, unexpired key documents missing: ' || array_to_string(v_missing, ', '));
  end if;

  -- Compensation (payroll review) — always required before activation
  select * into v_comp from public.onboarding_pending_compensation where instance_id = i.id;
  if v_comp.instance_id is null then
    b := b || jsonb_build_object('code', 'no_compensation', 'owner_role', 'hr', 'message', 'Pay for this employee has not been entered.');
  elsif v_comp.status <> 'approved' then
    b := b || jsonb_build_object('code', 'compensation_' || v_comp.status, 'owner_role', 'payroll',
      'message', case when v_comp.status = 'changes_required' then 'Payroll asked for changes to the pay.' else 'Pay is awaiting payroll review.' end);
  end if;

  -- Contract acceptance by the employee (always required)
  if not exists (select 1 from public.employee_contract_acceptances a join public.employee_documents d on d.id = a.document_id
                  where a.onboarding_instance_id = i.id and d.is_current and d.review_status = 'approved') then
    b := b || jsonb_build_object('code', 'contract_not_accepted', 'owner_role', 'employee',
      'message', 'The employee has not accepted the current approved contract.');
  end if;

  -- Open blocking exceptions
  for x in select * from public.onboarding_exceptions where instance_id = i.id and status = 'open' loop
    if x.is_blocking then
      b := b || jsonb_build_object('code', 'exception', 'exception_id', x.id, 'owner_role', x.owner_role,
        'message', format('%s: %s', initcap(replace(x.exception_type, '_', ' ')), x.description), 'due_date', x.due_date);
    else
      w := w || jsonb_build_object('code', 'exception', 'exception_id', x.id, 'message', x.description);
    end if;
  end loop;

  -- Invitation / login
  select * into v_inv from public.onboarding_invitations where instance_id = i.id order by issued_at desc limit 1;
  if e.auth_user_id is null then
    if v_inv.id is null then
      w := w || jsonb_build_object('code', 'not_invited', 'message', 'The employee has not been invited to the portal yet.');
    elsif v_inv.status = 'issued' and v_inv.expires_at < now() then
      b := b || jsonb_build_object('code', 'invitation_expired', 'owner_role', 'hr', 'message', 'The portal invitation has expired; reissue it.');
    end if;
  end if;

  -- Warnings: optional and post-start tasks, start-date risk
  select count(*) into v_total from public.onboarding_tasks where instance_id = i.id and phase = 'pre_activation' and not is_required
     and status not in ('approved', 'waived', 'cancelled');
  if v_total > 0 then w := w || jsonb_build_object('code', 'optional_tasks', 'message', format('%s optional task(s) not done.', v_total)); end if;
  if i.proposed_start_date is not null and i.proposed_start_date <= v_today + 3 and jsonb_array_length(b) > 0
     and i.status not in ('activated', 'day_one', 'in_progress', 'completed') then
    w := w || jsonb_build_object('code', 'start_date_risk', 'message',
      format('Starts on %s with %s blocking item(s) outstanding.', to_char(i.proposed_start_date, 'DD Mon'), jsonb_array_length(b)));
  end if;

  select count(*) filter (where is_required), count(*) filter (where is_required and status in ('approved', 'waived', 'cancelled'))
    into v_total, v_done
    from public.onboarding_tasks where instance_id = i.id and phase = 'pre_activation';

  v_next := case
    when jsonb_array_length(b) = 0 and i.status in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation')
      then 'Ready: an owner or entity admin can approve and activate.'
    when jsonb_array_length(b) > 0 then (b -> 0 ->> 'message')
    else null end;

  return jsonb_build_object(
    'ready', jsonb_array_length(b) = 0,
    'blockers', b,
    'warnings', w,
    'blocking_count', jsonb_array_length(b),
    'required_total', v_total,
    'required_done', v_done,
    'percent', case when v_total = 0 then 100 else round(100.0 * v_done / v_total) end,
    'next_action', v_next,
    'computed_at', now());
end;
$$;

-- Re-derives the pre-activation status from authoritative records after
-- every relevant change. Post-activation statuses are never touched here.
create or replace function public._onb_recompute(p_instance_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  r jsonb;
  v_to text;
  v_employee_open integer;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.status not in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation') then
    return null;
  end if;
  select * into e from public.employees where id = i.employee_id;
  r := public._onb_readiness(p_instance_id, 'full');
  select count(*) into v_employee_open from public.onboarding_tasks
   where instance_id = i.id and phase = 'pre_activation' and is_required and owner_role = 'employee'
     and status in ('not_started', 'in_progress');
  v_to := case
    when (r ->> 'ready')::boolean then 'ready_for_activation'
    when exists (select 1 from public.onboarding_tasks where instance_id = i.id and status = 'changes_required') then 'changes_required'
    when exists (select 1 from public.onboarding_exceptions where instance_id = i.id and status = 'open' and is_blocking)
      or exists (select 1 from jsonb_array_elements(r -> 'blockers') bl where bl ->> 'code' in ('duplicate_identity', 'invitation_expired', 'start_date_invalid'))
      then 'blocked'
    when v_employee_open > 0 and (e.auth_user_id is not null or exists (select 1 from public.onboarding_invitations v
                                                                            where v.instance_id = i.id and v.status in ('issued', 'accepted')))
      then 'awaiting_employee'
    when v_employee_open > 0 then 'initiated'
    else 'under_review' end;
  if v_to <> i.status then
    perform public._onb_set_status(p_instance_id, v_to, 'Recalculated from onboarding records');
  end if;
  return r;
end;
$$;

-- Internal helpers are not part of the API.
do $$
declare f text;
begin
  foreach f in array array['_onb_settings(uuid)', '_onb_can(uuid, text)', '_onb_require(uuid, text)', '_onb_is_self(uuid)',
    '_onb_can_own(uuid, text)', '_onb_can_review(uuid, text)', '_onb_op()', '_onb_audit(uuid, text, uuid, text, jsonb, jsonb)',
    '_onb_transition_allowed(text, text)', '_onb_set_status(uuid, text, text)', '_onb_touch(uuid)',
    '_onb_generate_tasks(uuid, text)', '_onb_sync_derived(uuid)', '_onb_readiness(uuid, text)', '_onb_recompute(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- ===== migrations/003_onboarding_build_a_lifecycle.sql
-- =====================================================================
-- Migration 003 — Build A: lifecycle foundation.
-- Templates, numbering, settings, policies, the three entry paths
-- (accepted offer, direct hire, existing pre-boarding employee), setup
-- changes, cancel / withdraw, dashboard and workspace reads.
-- Depends on: 001, 002.
-- =====================================================================


-- ------------------------------------------------------------ settings
create or replace function public.set_onboarding_settings(p_entity_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare cur public.onboarding_settings;
begin
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  cur := public._onb_settings(p_entity_id);
  insert into public.onboarding_settings (entity_id, invitation_valid_days, probation_months, probation_review_days_before,
    default_task_sla_days, require_distinct_activation_approver, updated_by, updated_at)
  values (p_entity_id,
    coalesce((p ->> 'invitation_valid_days')::int, cur.invitation_valid_days),
    coalesce((p ->> 'probation_months')::int, cur.probation_months),
    coalesce((p ->> 'probation_review_days_before')::int, cur.probation_review_days_before),
    coalesce((p ->> 'default_task_sla_days')::int, cur.default_task_sla_days),
    coalesce((p ->> 'require_distinct_activation_approver')::boolean, cur.require_distinct_activation_approver),
    auth.uid(), now())
  on conflict (entity_id) do update set
    invitation_valid_days = excluded.invitation_valid_days, probation_months = excluded.probation_months,
    probation_review_days_before = excluded.probation_review_days_before, default_task_sla_days = excluded.default_task_sla_days,
    require_distinct_activation_approver = excluded.require_distinct_activation_approver,
    updated_by = excluded.updated_by, updated_at = now();
  if coalesce((p ->> 'require_distinct_activation_approver')::boolean, true) = false and public.my_role() <> 'owner' then
    raise exception 'Only the owner can allow self-activation' using errcode = '42501';
  end if;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id)
  values ('onboarding_settings', p_entity_id, auth.uid(), 'onboarding_settings_saved', to_jsonb(cur), p, p_entity_id);
  return to_jsonb(public._onb_settings(p_entity_id));
end;
$$;

create or replace function public.set_employee_numbering(p_entity_id uuid, p_prefix text, p_next_value integer, p_pad_width integer)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  insert into public.employee_numbering (entity_id, prefix, next_value, pad_width)
  values (p_entity_id, coalesce(p_prefix, 'EMP-'), coalesce(p_next_value, 1), coalesce(p_pad_width, 4))
  on conflict (entity_id) do update set prefix = excluded.prefix, next_value = excluded.next_value,
    pad_width = excluded.pad_width, updated_at = now();
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
  values ('employee_numbering', p_entity_id, auth.uid(), 'employee_numbering_set',
    jsonb_build_object('prefix', p_prefix, 'next_value', p_next_value, 'pad_width', p_pad_width), p_entity_id);
end;
$$;

-- Next number, gap-free under concurrency (row lock). Skips numbers
-- already used (e.g. entered manually before numbering was set up).
create or replace function public._onb_next_employee_number(p_entity_id uuid)
returns text language plpgsql security definer set search_path to '' as $$
declare n public.employee_numbering; v text;
begin
  insert into public.employee_numbering (entity_id, prefix)
  values (p_entity_id, coalesce((select nullif(code, '') || '-' from public.entities where id = p_entity_id), 'EMP-'))
  on conflict (entity_id) do nothing;
  select * into n from public.employee_numbering where entity_id = p_entity_id for update;
  loop
    v := n.prefix || lpad(n.next_value::text, n.pad_width, '0');
    n.next_value := n.next_value + 1;
    exit when not exists (select 1 from public.employees where entity_id = p_entity_id and employee_number = v);
  end loop;
  update public.employee_numbering set next_value = n.next_value, updated_at = now() where entity_id = p_entity_id;
  return v;
end;
$$;

-- ------------------------------------------------------------ templates
create or replace function public._onb_validate_tasks(p_tasks jsonb)
returns void language plpgsql immutable set search_path to '' as $$
declare t jsonb; k text; keys text[] := '{}';
begin
  if p_tasks is null or jsonb_typeof(p_tasks) <> 'array' or jsonb_array_length(p_tasks) = 0 then
    raise exception 'A template needs at least one task' using errcode = '22023';
  end if;
  for t in select * from jsonb_array_elements(p_tasks) loop
    if coalesce(t ->> 'item_key', '') !~ '^[a-z0-9_]+$' then
      raise exception 'Task key "%" must be lowercase letters, digits and _', t ->> 'item_key' using errcode = '22023';
    end if;
    if (t ->> 'item_key') = any(keys) then
      raise exception 'Duplicate task key %', t ->> 'item_key' using errcode = '22023';
    end if;
    keys := keys || (t ->> 'item_key');
  end loop;
  for t in select * from jsonb_array_elements(p_tasks) loop
    for k in select * from jsonb_array_elements_text(coalesce(t -> 'depends_on', '[]'::jsonb)) loop
      if not k = any(keys) then
        raise exception 'Task % depends on unknown task %', t ->> 'item_key', k using errcode = '22023';
      end if;
    end loop;
  end loop;
end;
$$;

create or replace function public._onb_insert_template_tasks(p_template_id uuid, p_tasks jsonb)
returns integer language plpgsql security definer set search_path to '' as $$
declare t jsonb; n integer := 0;
begin
  for t in select * from jsonb_array_elements(p_tasks) loop
    insert into public.onboarding_template_tasks (template_id, item_key, item_label, description, section, phase, kind,
      owner_role, reviewer_role, doc_type, policy_key, is_required, is_waivable, is_statutory, due_offset_days, depends_on, sort_order)
    values (p_template_id, t ->> 'item_key', t ->> 'item_label', t ->> 'description', t ->> 'section',
      coalesce(t ->> 'phase', 'pre_activation'), coalesce(t ->> 'kind', 'manual'), t ->> 'owner_role', nullif(t ->> 'reviewer_role', ''),
      nullif(t ->> 'doc_type', '')::public.document_type, nullif(t ->> 'policy_key', ''),
      coalesce((t ->> 'is_required')::boolean, true),
      coalesce((t ->> 'is_waivable')::boolean, not coalesce((t ->> 'is_statutory')::boolean, false)),
      coalesce((t ->> 'is_statutory')::boolean, false),
      nullif(t ->> 'due_offset_days', '')::integer,
      coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(t -> 'depends_on', '[]'::jsonb)) x), '{}'),
      coalesce((t ->> 'sort_order')::integer, n));
    n := n + 1;
  end loop;
  -- Dependency cycles are rejected.
  if exists (
    with recursive g(k, path) as (
      select item_key, array[item_key] from public.onboarding_template_tasks where template_id = p_template_id
      union all
      select d, g.path || d from g
        join public.onboarding_template_tasks tt on tt.template_id = p_template_id and tt.item_key = g.k
        cross join lateral unnest(tt.depends_on) d
       where not d = any(g.path[2:]) and cardinality(g.path) < 50)
    select 1 from g where cardinality(path) > 1 and path[1] = path[cardinality(path)]) then
    raise exception 'Task dependencies form a loop' using errcode = '22023';
  end if;
  return n;
end;
$$;

create or replace function public.create_onboarding_template(p_entity_id uuid, p_name text, p_description text, p_tasks jsonb,
  p_employment_types public.employment_type[] default null, p_position_ids uuid[] default null)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_id uuid; v_n integer;
begin
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized to manage onboarding templates for this company' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'Template name is required' using errcode = '22023'; end if;
  perform public._onb_validate_tasks(p_tasks);
  if p_position_ids is not null and exists (select 1 from unnest(p_position_ids) pid
       where not exists (select 1 from public.positions p where p.id = pid and p.entity_id = p_entity_id)) then
    raise exception 'A position belongs to another company' using errcode = '22023';
  end if;
  insert into public.onboarding_templates (entity_id, name, description, applies_to_employment_types, applies_to_position_ids, created_by)
  values (p_entity_id, btrim(p_name), nullif(btrim(coalesce(p_description, '')), ''), p_employment_types, p_position_ids, auth.uid())
  returning id into v_id;
  v_n := public._onb_insert_template_tasks(v_id, p_tasks);
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
  values ('onboarding_templates', v_id, auth.uid(), 'onboarding_template_created',
    jsonb_build_object('name', p_name, 'task_count', v_n, 'employment_types', p_employment_types, 'positions', p_position_ids), p_entity_id);
  return v_id;
end;
$$;

-- New version; instances already started keep the snapshot they began with.
create or replace function public.replace_onboarding_template(p_template_id uuid, p_name text, p_description text, p_tasks jsonb,
  p_employment_types public.employment_type[] default null, p_position_ids uuid[] default null)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_old public.onboarding_templates; v_new uuid; v_n integer;
begin
  select * into v_old from public.onboarding_templates where id = p_template_id for update;
  if v_old.id is null then raise exception 'Template not found' using errcode = 'P0002'; end if;
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and v_old.entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not v_old.is_active then raise exception 'This template version is no longer active' using errcode = '22023'; end if;
  update public.onboarding_templates set is_active = false, deactivated_at = now(), updated_at = now() where id = p_template_id;
  insert into public.onboarding_templates (entity_id, name, description, applies_to_employment_types, applies_to_position_ids,
    version_number, supersedes_template_id, created_by)
  values (v_old.entity_id, coalesce(nullif(btrim(coalesce(p_name, '')), ''), v_old.name),
    coalesce(nullif(btrim(coalesce(p_description, '')), ''), v_old.description),
    coalesce(p_employment_types, v_old.applies_to_employment_types), coalesce(p_position_ids, v_old.applies_to_position_ids),
    v_old.version_number + 1, p_template_id, auth.uid())
  returning id into v_new;
  if p_tasks is null then
    insert into public.onboarding_template_tasks (template_id, item_key, item_label, description, section, phase, kind, owner_role,
      reviewer_role, doc_type, policy_key, is_required, is_waivable, is_statutory, due_offset_days, depends_on, sort_order)
    select v_new, item_key, item_label, description, section, phase, kind, owner_role, reviewer_role, doc_type, policy_key,
           is_required, is_waivable, is_statutory, due_offset_days, depends_on, sort_order
      from public.onboarding_template_tasks where template_id = p_template_id;
    get diagnostics v_n = row_count;
  else
    perform public._onb_validate_tasks(p_tasks);
    v_n := public._onb_insert_template_tasks(v_new, p_tasks);
  end if;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id)
  values ('onboarding_templates', v_new, auth.uid(), 'onboarding_template_replaced', jsonb_build_object('supersedes', p_template_id),
    jsonb_build_object('version_number', v_old.version_number + 1, 'task_count', v_n), v_old.entity_id);
  return v_new;
end;
$$;

create or replace function public.deactivate_onboarding_template(p_template_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare v_old public.onboarding_templates;
begin
  select * into v_old from public.onboarding_templates where id = p_template_id;
  if v_old.id is null then raise exception 'Template not found' using errcode = 'P0002'; end if;
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and v_old.entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not v_old.is_active then raise exception 'This template is already inactive' using errcode = '22023'; end if;
  update public.onboarding_templates set is_active = false, deactivated_at = now(), updated_at = now() where id = p_template_id;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, entity_id)
  values ('onboarding_templates', p_template_id, auth.uid(), 'onboarding_template_deactivated', jsonb_build_object('name', v_old.name), v_old.entity_id);
end;
$$;

-- A ready-to-use UAE café template (and the two policies it asks staff
-- to acknowledge). Safe to call once per company; returns the id.
create or replace function public.seed_default_onboarding_template(p_entity_id uuid)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_id uuid;
begin
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select id into v_id from public.onboarding_templates where entity_id = p_entity_id and is_active and lower(name) = 'standard onboarding';
  if v_id is not null then return v_id; end if;
  insert into public.onboarding_policies (entity_id, policy_key, version, title, body, created_by) values
    (p_entity_id, 'employee_handbook', '1', 'Employee handbook', 'Replace this text with your employee handbook before inviting staff.', auth.uid()),
    (p_entity_id, 'privacy_notice', '1', 'Employee privacy notice', 'Replace this text with your employee privacy notice before inviting staff.', auth.uid()),
    (p_entity_id, 'food_safety_sop', '1', 'Food safety and hygiene SOP', 'Replace this text with your food safety SOP.', auth.uid())
  on conflict do nothing;
  v_id := public.create_onboarding_template(p_entity_id, 'Standard onboarding', 'UAE café default: pre-boarding, activation, day one and first month', $json$[
    {"item_key":"personal_details","item_label":"Personal and contact details","section":"profile","kind":"profile","owner_role":"employee","reviewer_role":"hr","due_offset_days":3,"sort_order":1},
    {"item_key":"emergency_contact","item_label":"Address and emergency contact","section":"profile","kind":"profile","owner_role":"employee","reviewer_role":"hr","due_offset_days":3,"sort_order":2},
    {"item_key":"passport","item_label":"Passport","section":"documents","kind":"document","doc_type":"passport","owner_role":"employee","reviewer_role":"hr","is_statutory":true,"due_offset_days":5,"sort_order":3},
    {"item_key":"visa","item_label":"UAE residence visa","section":"documents","kind":"document","doc_type":"visa","owner_role":"employee","reviewer_role":"hr","is_statutory":true,"due_offset_days":5,"sort_order":4},
    {"item_key":"emirates_id","item_label":"Emirates ID","section":"documents","kind":"document","doc_type":"emirates_id","owner_role":"employee","reviewer_role":"hr","is_statutory":true,"due_offset_days":5,"sort_order":5},
    {"item_key":"health_card","item_label":"Health / occupational health card","section":"documents","kind":"document","doc_type":"health_card","owner_role":"employee","reviewer_role":"hr","is_required":false,"due_offset_days":14,"sort_order":6},
    {"item_key":"payment_details","item_label":"Salary payment details","section":"payment","kind":"payment_details","owner_role":"employee","reviewer_role":"payroll","due_offset_days":5,"sort_order":7},
    {"item_key":"handbook_ack","item_label":"Read and accept the employee handbook","section":"acknowledgements","kind":"acknowledgement","policy_key":"employee_handbook","owner_role":"employee","due_offset_days":5,"sort_order":8},
    {"item_key":"privacy_ack","item_label":"Read the employee privacy notice","section":"acknowledgements","kind":"acknowledgement","policy_key":"privacy_notice","owner_role":"employee","due_offset_days":5,"sort_order":9},
    {"item_key":"contract_upload","item_label":"Upload the signed-off employment contract","section":"employment","kind":"document","doc_type":"contract","owner_role":"hr","is_statutory":true,"due_offset_days":3,"sort_order":10},
    {"item_key":"contract_acceptance","item_label":"Accept the employment contract","section":"employment","kind":"contract_acceptance","owner_role":"employee","is_statutory":true,"depends_on":["contract_upload"],"due_offset_days":6,"sort_order":11},
    {"item_key":"compensation","item_label":"Enter pay for payroll review","section":"payroll","kind":"compensation","owner_role":"hr","reviewer_role":"payroll","is_statutory":true,"due_offset_days":5,"sort_order":12},
    {"item_key":"operations_setup","item_label":"Confirm branch, first schedule, uniform and access","section":"operations","kind":"manual","owner_role":"location_manager","due_offset_days":7,"sort_order":13},
    {"item_key":"arrival","item_label":"Confirm arrival on day one","section":"day_one","phase":"day_one","kind":"manual","owner_role":"location_manager","due_offset_days":0,"sort_order":20},
    {"item_key":"induction","item_label":"Branch tour, role briefing and safety induction","section":"day_one","phase":"day_one","kind":"manual","owner_role":"location_manager","due_offset_days":0,"sort_order":21},
    {"item_key":"uniform_handover","item_label":"Uniform, equipment and access handed over","section":"day_one","phase":"day_one","kind":"manual","owner_role":"location_manager","due_offset_days":1,"sort_order":22},
    {"item_key":"food_safety_ack","item_label":"Read and accept the food safety SOP","section":"acknowledgements","phase":"day_one","kind":"acknowledgement","policy_key":"food_safety_sop","owner_role":"employee","due_offset_days":3,"sort_order":23},
    {"item_key":"checkin_day7","item_label":"Day-7 check-in with the employee","section":"follow_up","phase":"initial_period","kind":"manual","owner_role":"location_manager","due_offset_days":7,"sort_order":30},
    {"item_key":"review_day30","item_label":"Day-30 role-readiness review","section":"follow_up","phase":"initial_period","kind":"manual","owner_role":"location_manager","due_offset_days":30,"sort_order":31}
  ]$json$::jsonb);
  return v_id;
end;
$$;

create or replace function public.upsert_onboarding_policy(p_entity_id uuid, p_policy_key text, p_version text, p_title text, p_body text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_id uuid;
begin
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null or nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'Title and text are required' using errcode = '22023';
  end if;
  -- A new version replaces the active one; staff must acknowledge it again.
  update public.onboarding_policies set is_active = false where entity_id = p_entity_id and policy_key = p_policy_key and is_active
     and version <> p_version;
  insert into public.onboarding_policies (entity_id, policy_key, version, title, body, created_by)
  values (p_entity_id, p_policy_key, p_version, btrim(p_title), p_body, auth.uid())
  on conflict (entity_id, policy_key, version) do update set title = excluded.title, body = excluded.body, is_active = true
  returning id into v_id;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
  values ('onboarding_policies', v_id, auth.uid(), 'onboarding_policy_saved', jsonb_build_object('policy_key', p_policy_key, 'version', p_version), p_entity_id);
  return v_id;
end;
$$;

-- ------------------------------------------------------ instance start
-- Most specific active template: position match, then employment type,
-- then the company default (no filters).
create or replace function public._onb_pick_template(p_entity_id uuid, p_position_id uuid, p_type public.employment_type)
returns uuid language sql stable security definer set search_path to '' as $$
  select id from public.onboarding_templates t
   where t.entity_id = p_entity_id and t.is_active
     and (t.applies_to_position_ids is null or p_position_id = any(t.applies_to_position_ids))
     and (t.applies_to_employment_types is null or p_type = any(t.applies_to_employment_types))
   order by (t.applies_to_position_ids is not null) desc, (t.applies_to_employment_types is not null) desc, t.created_at desc
   limit 1;
$$;

create or replace function public._onb_duplicate_count(p_entity_id uuid, p_email text, p_phone text, p_exclude uuid)
returns integer language sql stable security definer set search_path to '' as $$
  select count(*)::integer from public.employees e
   where e.entity_id = p_entity_id and e.employment_status <> 'inactive' and e.id is distinct from p_exclude
     and ((nullif(btrim(p_email), '') is not null and lower(btrim(e.email)) = lower(btrim(p_email)))
       or (length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 7
           and regexp_replace(coalesce(e.phone, ''), '\D', '', 'g') = regexp_replace(p_phone, '\D', '', 'g')));
$$;

create or replace function public._onb_create_instance(p_employee_id uuid, p_source text, p_offer_id uuid, p_reason text,
  p_manager uuid, p_start_date date)
returns uuid language plpgsql security definer set search_path to '' as $$
declare
  e public.employees;
  v_template uuid;
  v_tpl public.onboarding_templates;
  v_snapshot jsonb;
  v_id uuid;
  v_n integer;
  v_offer numeric;
begin
  select * into e from public.employees where id = p_employee_id for update;
  if exists (select 1 from public.onboarding_instances where employee_id = e.id and status not in ('completed', 'cancelled', 'withdrawn')) then
    raise exception 'This employee already has an open onboarding' using errcode = '23505';
  end if;
  v_template := public._onb_pick_template(e.entity_id, e.position_id, coalesce(e.employment_type, 'full_time'));
  if v_template is null then
    raise exception 'No active onboarding template for this company. Create one (or call seed_default_onboarding_template) first.'
      using errcode = '22023';
  end if;
  select * into v_tpl from public.onboarding_templates where id = v_template;
  select jsonb_build_object('template_id', v_tpl.id, 'name', v_tpl.name, 'version', v_tpl.version_number,
           'tasks', coalesce(jsonb_agg(to_jsonb(tt) - 'created_at' - 'template_id' order by tt.sort_order), '[]'::jsonb))
    into v_snapshot from public.onboarding_template_tasks tt where tt.template_id = v_template;

  if e.employee_number is null then
    update public.employees set employee_number = public._onb_next_employee_number(e.entity_id) where id = e.id;
  end if;
  if p_manager is not null then
    if not exists (select 1 from public.employees m where m.id = p_manager and m.entity_id = e.entity_id and m.employment_status = 'active') then
      raise exception 'Reporting manager must be an active employee of the same company' using errcode = '22023';
    end if;
    update public.employees set reporting_manager_employee_id = p_manager where id = e.id;
  end if;

  insert into public.onboarding_instances (employee_id, entity_id, home_location_id, position_id, reporting_manager_employee_id,
    employment_type, proposed_start_date, template_id, template_version, template_snapshot, source, offer_id, source_reason, created_by)
  values (e.id, e.entity_id, e.home_location_id, e.position_id, coalesce(p_manager, e.reporting_manager_employee_id),
    coalesce(e.employment_type, 'full_time'), coalesce(p_start_date, e.join_date), v_template, v_tpl.version_number, v_snapshot,
    p_source, p_offer_id, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid())
  returning id into v_id;
  v_n := public._onb_generate_tasks(v_id, 'pre_activation');

  -- Carry the accepted offer amount so payroll can compare (never applied automatically).
  if p_offer_id is not null then
    select proposed_salary_amount into v_offer from public.offers where id = p_offer_id;
  end if;

  perform public._onb_audit(v_id, 'onboarding_instances', v_id, 'onboarding_started', null,
    jsonb_build_object('source', p_source, 'offer_id', p_offer_id, 'employee_id', e.id, 'template_id', v_template,
                       'template_version', v_tpl.version_number, 'task_count', v_n, 'reason', p_reason, 'offer_amount', v_offer));
  perform public._onb_recompute(v_id);
  return v_id;
end;
$$;

create or replace function public.start_onboarding_from_offer(p_offer_id uuid, p_reporting_manager_employee_id uuid default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_entity uuid; v_email text; v_phone text; v_status text; v_converted uuid; v_position uuid;
  v_emp uuid; v_inst uuid;
begin
  select jr.entity_id, c.contact_email, c.contact_phone, o.status, o.converted_employee_id, o.position_id
    into v_entity, v_email, v_phone, v_status, v_converted, v_position
    from public.offers o
    join public.job_applications ja on ja.id = o.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    join public.candidates c on c.id = ja.candidate_id
   where o.id = p_offer_id
   for update of o;
  if v_entity is null then raise exception 'Offer not found' using errcode = 'P0002'; end if;
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and v_entity = public.my_entity())) then
    raise exception 'Not authorized to start onboarding for this offer' using errcode = '42501';
  end if;
  if v_status <> 'accepted' then
    raise exception 'The offer must be accepted before onboarding starts (it is %)', v_status using errcode = '22023';
  end if;
  -- Idempotent retry: an already-converted offer returns its onboarding.
  if v_converted is not null then
    select id into v_inst from public.onboarding_instances where offer_id = p_offer_id order by created_at desc limit 1;
    if v_inst is not null then
      return jsonb_build_object('ok', true, 'already_started', true, 'employee_id', v_converted, 'onboarding_instance_id', v_inst);
    end if;
    raise exception 'This offer was converted outside onboarding; use start_onboarding_for_employee() for employee %', v_converted
      using errcode = '22023';
  end if;
  if public._onb_duplicate_count(v_entity, v_email, v_phone, null) > 0 then
    raise exception 'A current employee with this email or phone already exists in this company. Resolve the duplicate first.'
      using errcode = '23505';
  end if;
  if public._onb_pick_template(v_entity, v_position, 'full_time') is null
     and not exists (select 1 from public.onboarding_templates where entity_id = v_entity and is_active) then
    raise exception 'No active onboarding template for this company. Create one first.' using errcode = '22023';
  end if;
  -- Reuse the existing conversion unchanged.
  v_emp := public.convert_offer_to_employee(p_offer_id);
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('offers', p_offer_id, auth.uid(), 'offer_converted_to_employee',
    jsonb_build_object('employee_id', v_emp, 'operation_id', public._onb_op()), v_entity, v_emp);
  v_inst := public._onb_create_instance(v_emp, 'offer', p_offer_id, null, p_reporting_manager_employee_id, null);
  return jsonb_build_object('ok', true, 'already_started', false, 'employee_id', v_emp, 'onboarding_instance_id', v_inst,
    'task_count', (select count(*) from public.onboarding_tasks where instance_id = v_inst));
end;
$$;

create or replace function public.start_onboarding_direct_hire(p_entity_id uuid, p_full_name text, p_email text, p_phone text,
  p_gender text, p_home_location_id uuid, p_position_id uuid, p_employment_type text, p_start_date date,
  p_reporting_manager_employee_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_emp uuid; v_inst uuid;
begin
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized to start a direct hire for this company' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_full_name, '')), '') is null then raise exception 'Full name is required' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required for a direct hire' using errcode = '22023'; end if;
  if p_home_location_id is not null and not exists (select 1 from public.locations where id = p_home_location_id and entity_id = p_entity_id) then
    raise exception 'Branch belongs to another company' using errcode = '22023';
  end if;
  if p_position_id is not null and not exists (select 1 from public.positions where id = p_position_id and entity_id = p_entity_id) then
    raise exception 'Position belongs to another company' using errcode = '22023';
  end if;
  if p_employment_type is not null and not exists (select 1 from pg_catalog.pg_enum en join pg_catalog.pg_type ty on ty.oid = en.enumtypid
                                                    where ty.typname = 'employment_type' and en.enumlabel = p_employment_type) then
    raise exception 'Unknown employment type %', p_employment_type using errcode = '22023';
  end if;
  if public._onb_duplicate_count(p_entity_id, p_email, p_phone, null) > 0 then
    raise exception 'A current employee with this email or phone already exists in this company. Resolve the duplicate first.'
      using errcode = '23505';
  end if;
  insert into public.employees (entity_id, home_location_id, position_id, full_name, email, phone, gender, employment_type,
                                join_date, employment_status)
  values (p_entity_id, p_home_location_id, p_position_id, btrim(p_full_name), nullif(lower(btrim(coalesce(p_email, ''))), ''),
          nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_gender, '')), ''),
          coalesce(p_employment_type, 'full_time')::public.employment_type, p_start_date, 'pre_boarding')
  returning id into v_emp;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employees', v_emp, auth.uid(), 'direct_hire_employee_created',
    jsonb_build_object('full_name', p_full_name, 'reason', p_reason, 'operation_id', public._onb_op()), p_entity_id, p_home_location_id, v_emp);
  v_inst := public._onb_create_instance(v_emp, 'direct_hire', null, p_reason, p_reporting_manager_employee_id, p_start_date);
  return jsonb_build_object('ok', true, 'employee_id', v_emp, 'onboarding_instance_id', v_inst,
    'task_count', (select count(*) from public.onboarding_tasks where instance_id = v_inst));
end;
$$;

-- Existing pre-boarding employee (created before onboarding existed, or
-- converted outside it): start the same lifecycle, never a second record.
create or replace function public.start_onboarding_for_employee(p_employee_id uuid, p_reporting_manager_employee_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare e public.employees; v_inst uuid;
begin
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  if not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if e.employment_status not in ('candidate', 'pre_boarding') then
    raise exception 'Only candidate or pre-boarding employees can start onboarding (this one is %)', e.employment_status using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if e.employment_status = 'candidate' then
    update public.employees set employment_status = 'pre_boarding', updated_at = now() where id = e.id;
  end if;
  v_inst := public._onb_create_instance(e.id, 'existing_employee', null, p_reason, p_reporting_manager_employee_id, e.join_date);
  return jsonb_build_object('ok', true, 'employee_id', e.id, 'onboarding_instance_id', v_inst);
end;
$$;

-- ----------------------------------------------------- setup changes
-- Branch, job, manager, employment type and start date before
-- activation. Updates the employee master too (single source of truth).
create or replace function public.update_onboarding_setup(p_instance_id uuid, p jsonb, p_reason text, p_expected_version integer)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  v_before jsonb;
  v_loc uuid; v_pos uuid; v_mgr uuid; v_type public.employment_type; v_start date;
begin
  perform public._onb_require(p_instance_id, 'manage');
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status not in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation') then
    raise exception 'Setup can only change before activation' using errcode = '22023';
  end if;
  if p_expected_version is distinct from i.row_version then
    raise exception 'This onboarding changed since you opened it; reload and try again' using errcode = '40001';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  v_loc := coalesce(nullif(p ->> 'home_location_id', '')::uuid, i.home_location_id);
  v_pos := coalesce(nullif(p ->> 'position_id', '')::uuid, i.position_id);
  v_mgr := coalesce(nullif(p ->> 'reporting_manager_employee_id', '')::uuid, i.reporting_manager_employee_id);
  v_type := coalesce(nullif(p ->> 'employment_type', '')::public.employment_type, i.employment_type);
  v_start := coalesce(nullif(p ->> 'proposed_start_date', '')::date, i.proposed_start_date);
  if v_loc is not null and not exists (select 1 from public.locations where id = v_loc and entity_id = i.entity_id) then
    raise exception 'Branch belongs to another company' using errcode = '22023';
  end if;
  if v_pos is not null and not exists (select 1 from public.positions where id = v_pos and entity_id = i.entity_id) then
    raise exception 'Position belongs to another company' using errcode = '22023';
  end if;
  if v_mgr is not null and not exists (select 1 from public.employees where id = v_mgr and entity_id = i.entity_id and employment_status = 'active') then
    raise exception 'Reporting manager must be an active employee of the same company' using errcode = '22023';
  end if;
  v_before := jsonb_build_object('home_location_id', i.home_location_id, 'position_id', i.position_id,
    'reporting_manager_employee_id', i.reporting_manager_employee_id, 'employment_type', i.employment_type,
    'proposed_start_date', i.proposed_start_date);
  update public.onboarding_instances set home_location_id = v_loc, position_id = v_pos, reporting_manager_employee_id = v_mgr,
    employment_type = v_type, proposed_start_date = v_start, row_version = row_version + 1, updated_at = now()
   where id = i.id;
  update public.employees set home_location_id = v_loc, position_id = v_pos, reporting_manager_employee_id = v_mgr,
    employment_type = v_type, join_date = v_start, updated_at = now() where id = i.employee_id;
  -- Pending pay effective date follows a changed start date.
  update public.onboarding_pending_compensation set effective_from = v_start
   where instance_id = i.id and effective_from is not distinct from i.proposed_start_date;
  perform public._onb_audit(i.id, 'onboarding_instances', i.id, 'onboarding_setup_changed', v_before,
    jsonb_build_object('home_location_id', v_loc, 'position_id', v_pos, 'reporting_manager_employee_id', v_mgr,
                       'employment_type', v_type, 'proposed_start_date', v_start, 'reason', p_reason));
  return public._onb_recompute(i.id);
end;
$$;

-- ------------------------------------------------- cancel / withdraw
create or replace function public._onb_end(p_instance_id uuid, p_status text, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances;
begin
  perform public._onb_require(p_instance_id, 'manage');
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status in ('cancelled', 'withdrawn') then
    return jsonb_build_object('ok', true, 'already', true, 'status', i.status);
  end if;
  perform public._onb_set_status(i.id, p_status, p_reason);
  update public.onboarding_instances set ended_at = now(), ended_by = auth.uid(), end_reason = btrim(p_reason) where id = i.id;
  update public.onboarding_tasks set status = 'cancelled', updated_at = now()
   where instance_id = i.id and status not in ('approved', 'waived', 'cancelled');
  update public.onboarding_invitations set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoke_reason = p_reason
   where instance_id = i.id and status = 'issued';
  -- The employee record is kept (history) and made inactive; logins and grants are revoked by set_employee_status.
  perform public.set_employee_status(i.employee_id, 'inactive', 'Onboarding ' || p_status || ': ' || btrim(p_reason));
  if p_status = 'withdrawn' and i.offer_id is not null then
    update public.candidates c set status = 'withdrawn', updated_at = now()
      from public.job_applications ja, public.offers o
     where o.id = i.offer_id and ja.id = o.application_id and c.id = ja.candidate_id;
  end if;
  return jsonb_build_object('ok', true, 'already', false, 'status', p_status);
end;
$$;

create or replace function public.cancel_onboarding(p_instance_id uuid, p_reason text)
returns jsonb language sql security definer set search_path to '' as $$ select public._onb_end(p_instance_id, 'cancelled', p_reason); $$;

create or replace function public.withdraw_onboarding(p_instance_id uuid, p_reason text)
returns jsonb language sql security definer set search_path to '' as $$ select public._onb_end(p_instance_id, 'withdrawn', p_reason); $$;

-- ----------------------------------------------------------- reads
-- Dashboard rows for the caller's scope. p_tab: new, awaiting_employee,
-- under_review, blocked, ready, starting_soon, in_progress, completed,
-- cancelled, all.
create or replace function public.list_onboarding(p_entity_id uuid, p_tab text default 'all')
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_role public.user_role := public.my_role();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  -- Payroll approvers (e.g. a payroll_admin staff login) see the company list for pay / bank reviews.
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())
          or public.payroll_can(p_entity_id, 'approve')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(row order by (row ->> 'proposed_start_date') nulls last)
      from (
        select jsonb_build_object(
          'onboarding_instance_id', i.id, 'employee_id', e.id, 'name', e.full_name, 'employee_number', e.employee_number,
          'branch', l.name, 'position', p.title, 'status', i.status, 'source', i.source,
          'proposed_start_date', i.proposed_start_date, 'days_in_stage', (v_today - (i.status_changed_at at time zone 'Asia/Dubai')::date),
          'row_version', i.row_version,
          'blocking_count', (select count(*) from public.onboarding_tasks t where t.instance_id = i.id and t.phase = 'pre_activation'
                               and t.is_required and t.status not in ('approved', 'waived', 'cancelled'))
                            + (select count(*) from public.onboarding_exceptions x where x.instance_id = i.id and x.status = 'open' and x.is_blocking),
          'overdue_tasks', (select count(*) from public.onboarding_tasks t where t.instance_id = i.id and t.due_date < v_today
                              and t.status not in ('approved', 'waived', 'cancelled')),
          'next_due', (select min(t.due_date) from public.onboarding_tasks t where t.instance_id = i.id
                         and t.status not in ('approved', 'waived', 'cancelled')),
          'last_activity', i.updated_at) as row
          from public.onboarding_instances i
          join public.employees e on e.id = i.employee_id
          left join public.locations l on l.id = i.home_location_id
          left join public.positions p on p.id = i.position_id
         where i.entity_id = p_entity_id
           and (v_role <> 'location_manager' or i.home_location_id = public.my_location())
           and case p_tab
                 when 'new' then i.status = 'initiated'
                 when 'awaiting_employee' then i.status = 'awaiting_employee'
                 when 'under_review' then i.status in ('under_review', 'changes_required')
                 when 'blocked' then i.status = 'blocked'
                 when 'ready' then i.status = 'ready_for_activation'
                 when 'starting_soon' then i.proposed_start_date between v_today and v_today + 14
                                        and i.status not in ('completed', 'cancelled', 'withdrawn')
                 when 'in_progress' then i.status in ('activated', 'day_one', 'in_progress')
                 when 'completed' then i.status = 'completed'
                 when 'cancelled' then i.status in ('cancelled', 'withdrawn')
                 else true end) q), '[]'::jsonb);
end;
$$;

-- Full workspace for one onboarding. Pay and bank details only for
-- payroll-authorised viewers; branch managers get operational fields.
create or replace function public.get_onboarding_workspace(p_instance_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  v_pay boolean;
  v_hr boolean;
  v_aud text;
begin
  perform public._onb_require(p_instance_id, 'view');
  v_pay := public._onb_can(p_instance_id, 'payroll');
  v_hr := public._onb_can(p_instance_id, 'manage');
  v_aud := case when v_hr or v_pay then 'full' else 'operations' end;
  select * into i from public.onboarding_instances where id = p_instance_id;
  select * into e from public.employees where id = i.employee_id;
  return jsonb_build_object(
    'instance', to_jsonb(i) - 'template_snapshot' - 'closure_snapshot',
    'template', jsonb_build_object('id', i.template_id, 'name', i.template_snapshot ->> 'name', 'version', i.template_version),
    'employee', jsonb_build_object('id', e.id, 'name', e.full_name, 'employee_number', e.employee_number,
      'email', case when v_hr then e.email end, 'phone', e.phone, 'employment_status', e.employment_status,
      'has_login', e.auth_user_id is not null, 'nationality', case when v_hr then e.nationality end),
    'permissions', jsonb_build_object('manage', v_hr, 'payroll', v_pay, 'approve', public._onb_can(p_instance_id, 'approve'),
                                      'operate', public._onb_can(p_instance_id, 'operate')),
    'readiness', public._onb_readiness(p_instance_id, v_aud),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'item_key', t.item_key, 'item_label', t.item_label,
        'section', t.section, 'phase', t.phase, 'kind', t.kind, 'owner_role', t.owner_role, 'reviewer_role', t.reviewer_role,
        'status', t.status, 'is_required', t.is_required, 'is_waivable', t.is_waivable, 'due_date', t.due_date,
        'review_reason', t.review_reason, 'waived_reason', t.waived_reason,
        'depends_on', (select jsonb_agg(d.depends_on_task_id) from public.onboarding_task_dependencies d where d.task_id = t.id))
        order by t.phase, t.sort_order)
      from public.onboarding_tasks t where t.instance_id = i.id
       and (v_aud = 'full' or t.section not in ('payment', 'payroll'))), '[]'::jsonb),
    'sections', coalesce((select jsonb_agg(to_jsonb(s) - 'snapshot' order by s.submitted_at desc)
      from public.onboarding_section_submissions s where s.instance_id = i.id
       and (v_aud = 'full' or s.section not in ('payment', 'payroll', 'documents', 'employment'))), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('section', r.section, 'decision', r.decision, 'reason', r.reason,
        'reviewer_role', r.reviewer_role, 'at', r.created_at) order by r.created_at desc)
      from public.onboarding_reviews r where r.instance_id = i.id
       and (v_aud = 'full' or r.section not in ('payment', 'payroll', 'documents', 'employment'))), '[]'::jsonb),
    'exceptions', coalesce((select jsonb_agg(to_jsonb(x) order by x.raised_at desc)
      from public.onboarding_exceptions x where x.instance_id = i.id), '[]'::jsonb),
    'invitation', (select jsonb_build_object('status', case when v.status = 'issued' and v.expires_at < now() then 'expired' else v.status end,
        'sent_to', case when v_hr then v.sent_to_email end, 'issued_at', v.issued_at, 'expires_at', v.expires_at, 'accepted_at', v.accepted_at)
      from public.onboarding_invitations v where v.instance_id = i.id order by v.issued_at desc limit 1),
    'compensation', case when v_hr or v_pay then (select to_jsonb(c) from public.onboarding_pending_compensation c where c.instance_id = i.id) end,
    'payment_details', case when v_pay then (select to_jsonb(pd) from public.employee_payment_details pd
                                               where pd.employee_id = e.id order by pd.submitted_at desc limit 1)
                            when v_hr then (select jsonb_build_object('method', pd.method, 'status', pd.status,
                                               'iban_last4', right(pd.iban, 4), 'submitted_at', pd.submitted_at)
                                              from public.employee_payment_details pd where pd.employee_id = e.id order by pd.submitted_at desc limit 1) end,
    'contract', case when v_hr then (select jsonb_build_object('accepted_at', a.accepted_at, 'document_id', a.document_id, 'document_version', a.document_version)
                                       from public.employee_contract_acceptances a where a.onboarding_instance_id = i.id order by a.accepted_at desc limit 1) end,
    'probation', (select jsonb_agg(to_jsonb(pp) order by pp.start_date) from public.employee_probation_periods pp where pp.employee_id = e.id),
    'timeline', coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'at', a.changed_at, 'by', pr.full_name)
                                          order by a.changed_at desc)
      from (select * from public.audit_log al where al.employee_id = e.id
              and (al.new_value ->> 'onboarding_instance_id' = i.id::text or al.table_name in ('employees', 'employee_documents'))
              and al.changed_at >= i.created_at
            order by al.changed_at desc limit 60) a
      left join public.profiles pr on pr.id = a.changed_by), '[]'::jsonb));
end;
$$;

create or replace function public.calculate_onboarding_readiness(p_instance_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if public._onb_can(p_instance_id, 'manage') or public._onb_can(p_instance_id, 'payroll') then
    return public._onb_readiness(p_instance_id, 'full');
  elsif public._onb_can(p_instance_id, 'operate') then
    return public._onb_readiness(p_instance_id, 'operations');
  elsif public._onb_is_self(p_instance_id) then
    return public._onb_readiness(p_instance_id, 'employee');
  end if;
  raise exception 'Not authorized' using errcode = '42501';
end;
$$;

-- ---------------------------------------------------------- grants
do $$
declare f text;
begin
  foreach f in array array['_onb_next_employee_number(uuid)', '_onb_validate_tasks(jsonb)', '_onb_insert_template_tasks(uuid, jsonb)',
    '_onb_pick_template(uuid, uuid, public.employment_type)', '_onb_duplicate_count(uuid, text, text, uuid)',
    '_onb_create_instance(uuid, text, uuid, text, uuid, date)', '_onb_end(uuid, text, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['set_onboarding_settings(uuid, jsonb)', 'set_employee_numbering(uuid, text, integer, integer)',
    'create_onboarding_template(uuid, text, text, jsonb, public.employment_type[], uuid[])',
    'replace_onboarding_template(uuid, text, text, jsonb, public.employment_type[], uuid[])',
    'deactivate_onboarding_template(uuid)', 'seed_default_onboarding_template(uuid)',
    'upsert_onboarding_policy(uuid, text, text, text, text)',
    'start_onboarding_from_offer(uuid, uuid)',
    'start_onboarding_direct_hire(uuid, text, text, text, text, uuid, uuid, text, date, uuid, text)',
    'start_onboarding_for_employee(uuid, uuid, text)', 'update_onboarding_setup(uuid, jsonb, text, integer)',
    'cancel_onboarding(uuid, text)', 'withdraw_onboarding(uuid, text)', 'list_onboarding(uuid, text)',
    'get_onboarding_workspace(uuid)', 'calculate_onboarding_readiness(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ===== migrations/004_onboarding_build_b_preboarding.sql
-- =====================================================================
-- Migration 004 — Build B: employee pre-boarding.
-- Invitations (issue / reissue / expiry), the employee portal read,
-- save-and-resume profile, self document upload, payment details,
-- acknowledgements, contract acceptance, section submission and task
-- completion. Every self-service path resolves the employee from
-- auth.uid() — no client-supplied employee id.
-- Depends on: 001–003, admin_grant_access, confirm_document_upload.
-- =====================================================================


-- --------------------------------------------------------- invitations
-- Records the invitation and creates the pending staff access grant (the
-- grant links the login to this employee when they sign up). Sending the
-- email is done by the app through the existing invite-user Edge Function.
create or replace function public.issue_onboarding_invitation(p_instance_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  s public.onboarding_settings;
  v_existing public.onboarding_invitations;
  v_grant uuid;
  v_id uuid;
begin
  perform public._onb_require(p_instance_id, 'manage');
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status not in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation') then
    raise exception 'Invitations are only issued before activation' using errcode = '22023';
  end if;
  select * into e from public.employees where id = i.employee_id;
  if nullif(btrim(coalesce(e.email, '')), '') is null then
    raise exception 'Add the employee''s email before inviting them' using errcode = '22023';
  end if;
  select * into v_existing from public.onboarding_invitations where instance_id = i.id and status = 'issued';
  if v_existing.id is not null and v_existing.expires_at > now() then
    return jsonb_build_object('ok', true, 'already_issued', true, 'invitation_id', v_existing.id, 'email', v_existing.sent_to_email,
      'expires_at', v_existing.expires_at, 'send_email', false);
  end if;
  if v_existing.id is not null then
    update public.onboarding_invitations set status = 'expired' where id = v_existing.id;
  end if;
  s := public._onb_settings(i.entity_id);
  v_grant := public.admin_grant_access(e.email, 'staff', i.entity_id, i.home_location_id, e.id);
  insert into public.onboarding_invitations (instance_id, employee_id, sent_to_email, access_grant_id, issued_by, expires_at, reissue_of)
  values (i.id, e.id, lower(btrim(e.email)), v_grant, auth.uid(), now() + make_interval(days => s.invitation_valid_days), v_existing.id)
  returning id into v_id;
  -- An existing login is linked immediately by admin_grant_access.
  if (select auth_user_id from public.employees where id = e.id) is not null then
    update public.onboarding_invitations set status = 'accepted', accepted_at = now() where id = v_id;
  end if;
  perform public._onb_audit(i.id, 'onboarding_invitations', v_id, 'onboarding_invitation_issued', null,
    jsonb_build_object('email', lower(btrim(e.email)), 'expires_at', now() + make_interval(days => s.invitation_valid_days)));
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'already_issued', false, 'invitation_id', v_id, 'email', lower(btrim(e.email)),
    'expires_at', now() + make_interval(days => s.invitation_valid_days),
    'send_email', (select auth_user_id from public.employees where id = e.id) is null);
end;
$$;

-- Revoke and reissue — optionally to a corrected address. Same employee,
-- same onboarding, never a second record.
create or replace function public.reissue_onboarding_invitation(p_instance_id uuid, p_reason text, p_new_email text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  v_old public.onboarding_invitations;
  v_email text := nullif(lower(btrim(coalesce(p_new_email, ''))), '');
begin
  perform public._onb_require(p_instance_id, 'manage');
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  select * into e from public.employees where id = i.employee_id;
  if e.auth_user_id is not null and v_email is not null and v_email <> lower(coalesce(e.email, '')) then
    raise exception 'The employee already has a login; change the email from their account instead' using errcode = '22023';
  end if;
  if v_email is not null and v_email <> lower(coalesce(e.email, '')) then
    if public._onb_duplicate_count(e.entity_id, v_email, null, e.id) > 0 then
      raise exception 'Another current employee uses this email' using errcode = '23505';
    end if;
    update public.employees set email = v_email, updated_at = now() where id = e.id;
  end if;
  select * into v_old from public.onboarding_invitations where instance_id = i.id and status = 'issued';
  if v_old.id is not null then
    update public.onboarding_invitations set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoke_reason = btrim(p_reason)
     where id = v_old.id;
    update public.access_grants set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
           revoke_reason = 'Onboarding invitation reissued: ' || btrim(p_reason), updated_at = now()
     where id = v_old.access_grant_id and status = 'pending';
  end if;
  perform public._onb_audit(i.id, 'onboarding_invitations', coalesce(v_old.id, i.id), 'onboarding_invitation_revoked', null,
    jsonb_build_object('reason', p_reason, 'new_email', v_email));
  return public.issue_onboarding_invitation(p_instance_id);
end;
$$;

-- ------------------------------------------------------- portal (self)
create or replace function public._onb_my_open_instance()
returns public.onboarding_instances language sql stable security definer set search_path to '' as $$
  select i.* from public.onboarding_instances i
   where i.employee_id = public.my_employee_id() and public.is_active_user()
     and i.status not in ('completed', 'cancelled', 'withdrawn')
   order by i.created_at desc limit 1;
$$;

create or replace function public.get_my_onboarding()
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
begin
  i := public._onb_my_open_instance();
  if i.id is null then return jsonb_build_object('ok', true, 'onboarding', null); end if;
  select * into e from public.employees where id = i.employee_id;
  -- First sign-in marks the invitation accepted.
  update public.onboarding_invitations set status = 'accepted', accepted_at = now()
   where instance_id = i.id and status = 'issued';
  if found then
    perform public._onb_audit(i.id, 'onboarding_invitations', i.id, 'onboarding_invitation_accepted', null, null);
  end if;
  perform public._onb_recompute(i.id);
  select * into i from public.onboarding_instances where id = i.id;
  return jsonb_build_object('ok', true, 'onboarding', jsonb_build_object(
    'id', i.id, 'status', i.status, 'row_version', i.row_version, 'proposed_start_date', i.proposed_start_date,
    'actual_start_date', i.actual_start_date,
    'company', (select name from public.entities where id = i.entity_id),
    'branch', (select jsonb_build_object('name', l.name, 'address', l.address) from public.locations l where l.id = i.home_location_id),
    'position', (select jsonb_build_object('title', p.title, 'department', p.department, 'description', p.description)
                   from public.positions p where p.id = i.position_id),
    'manager', (select jsonb_build_object('name', m.full_name, 'phone', m.phone) from public.employees m where m.id = i.reporting_manager_employee_id),
    'profile', jsonb_build_object('full_name', e.full_name, 'preferred_name', e.preferred_name, 'email', e.email, 'phone', e.phone,
      'dob', e.dob, 'gender', e.gender, 'nationality', e.nationality, 'residential_address', e.residential_address,
      'emergency_contact_name', e.emergency_contact_name, 'emergency_contact_phone', e.emergency_contact_phone,
      'employee_number', e.employee_number),
    'readiness', public._onb_readiness(i.id, 'employee'),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'item_key', t.item_key, 'item_label', t.item_label,
        'description', t.description, 'section', t.section, 'phase', t.phase, 'kind', t.kind, 'doc_type', t.doc_type,
        'policy_key', t.policy_key, 'status', t.status, 'is_required', t.is_required, 'due_date', t.due_date,
        'mine', t.owner_role = 'employee', 'review_reason', case when t.status = 'changes_required' then t.review_reason end)
        order by t.phase, t.sort_order)
      from public.onboarding_tasks t where t.instance_id = i.id
       and (t.owner_role = 'employee' or t.phase <> 'pre_activation' or t.section in ('operations'))), '[]'::jsonb),
    'sections', coalesce((select jsonb_object_agg(s.section, s.status) from (
        select distinct on (section) section, status from public.onboarding_section_submissions
         where instance_id = i.id order by section, version desc) s), '{}'::jsonb),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'review_status', d.review_status,
        'is_current', d.is_current, 'expiry_date', d.expiry_date, 'rejection_reason', d.rejection_reason, 'submitted_at', d.submitted_at)
        order by d.submitted_at desc)
      from public.employee_documents d where d.employee_id = e.id and d.upload_confirmed and d.review_status <> 'archived'), '[]'::jsonb),
    'payment_details', (select jsonb_build_object('method', pd.method, 'bank_name', pd.bank_name, 'account_name', pd.account_name,
        'iban_last4', right(pd.iban, 4), 'status', pd.status, 'rejection_reason', pd.rejection_reason)
      from public.employee_payment_details pd where pd.employee_id = e.id order by pd.submitted_at desc limit 1),
    'policies', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'policy_key', p.policy_key, 'title', p.title, 'version', p.version,
        'body', p.body, 'acknowledged_at', (select a.acknowledged_at from public.employee_acknowledgements a
                                             where a.employee_id = e.id and a.policy_id = p.id)))
      from public.onboarding_policies p
     where p.entity_id = i.entity_id and p.is_active
       and p.policy_key in (select t.policy_key from public.onboarding_tasks t where t.instance_id = i.id and t.policy_key is not null)), '[]'::jsonb),
    'contract', (select jsonb_build_object('document_id', d.id, 'version', d.version_number, 'approved', d.review_status = 'approved',
        'accepted_at', (select a.accepted_at from public.employee_contract_acceptances a
                         where a.onboarding_instance_id = i.id and a.document_id = d.id))
      from public.employee_documents d where d.employee_id = e.id and d.doc_type = 'contract' and d.is_current
       and d.review_status = 'approved' order by d.version_number desc limit 1)));
end;
$$;

-- Save and resume. Whitelisted fields only; locked while the profile
-- section is under review or approved.
create or replace function public.save_my_onboarding_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  v_locked boolean;
  k text;
  v_allowed text[] := array['preferred_name', 'phone', 'dob', 'gender', 'nationality', 'residential_address',
                            'emergency_contact_name', 'emergency_contact_phone'];
begin
  i := public._onb_my_open_instance();
  if i.id is null then raise exception 'No open onboarding for your account' using errcode = 'P0002'; end if;
  if i.status in ('activated', 'day_one', 'in_progress') then
    raise exception 'After activation, use My Profile to request changes' using errcode = '22023';
  end if;
  for k in select jsonb_object_keys(p) loop
    if not k = any(v_allowed) then raise exception 'Field % cannot be edited here', k using errcode = '22023'; end if;
  end loop;
  select exists (select 1 from public.onboarding_tasks where instance_id = i.id and section = 'profile'
                  and status in ('submitted', 'approved')) into v_locked;
  if v_locked then
    raise exception 'Your details are with HR for review. You can edit them if changes are requested.' using errcode = '22023';
  end if;
  if p ? 'dob' and nullif(p ->> 'dob', '')::date > (now() at time zone 'Asia/Dubai')::date - interval '15 years' then
    raise exception 'Date of birth looks wrong (minimum working age is 15)' using errcode = '22023';
  end if;
  select * into e from public.employees where id = i.employee_id for update;
  update public.employees set
    preferred_name = case when p ? 'preferred_name' then nullif(btrim(p ->> 'preferred_name'), '') else preferred_name end,
    phone = case when p ? 'phone' then nullif(btrim(p ->> 'phone'), '') else phone end,
    dob = case when p ? 'dob' then nullif(p ->> 'dob', '')::date else dob end,
    gender = case when p ? 'gender' then nullif(btrim(p ->> 'gender'), '') else gender end,
    nationality = case when p ? 'nationality' then nullif(btrim(p ->> 'nationality'), '') else nationality end,
    residential_address = case when p ? 'residential_address' then nullif(btrim(p ->> 'residential_address'), '') else residential_address end,
    emergency_contact_name = case when p ? 'emergency_contact_name' then nullif(btrim(p ->> 'emergency_contact_name'), '') else emergency_contact_name end,
    emergency_contact_phone = case when p ? 'emergency_contact_phone' then nullif(btrim(p ->> 'emergency_contact_phone'), '') else emergency_contact_phone end,
    updated_at = now()
  where id = e.id;
  update public.onboarding_tasks set status = 'in_progress', updated_at = now()
   where instance_id = i.id and section = 'profile' and status in ('not_started', 'changes_required');
  perform public._onb_audit(i.id, 'employees', e.id, 'onboarding_profile_saved', null, jsonb_build_object('fields', p));
  return jsonb_build_object('ok', true);
end;
$$;

-- Self upload for a pre-boarding employee: same server-derived path and
-- review lifecycle as stage_document_upload; confirm with the existing
-- confirm_document_upload() after the file is stored.
create or replace function public.stage_my_onboarding_document(p_doc_type public.document_type, p_file_extension text,
  p_expiry_date date default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  v_new uuid := gen_random_uuid();
  v_path text;
  v_current uuid;
begin
  i := public._onb_my_open_instance();
  if i.id is null then raise exception 'No open onboarding for your account' using errcode = 'P0002'; end if;
  if p_file_extension is null or lower(p_file_extension) not in ('pdf', 'jpg', 'jpeg', 'png') then
    raise exception 'Only PDF, JPG and PNG files are accepted' using errcode = '22023';
  end if;
  if p_doc_type in ('contract', 'offer_letter', 'compensation_document') then
    raise exception 'HR provides this document' using errcode = '42501';
  end if;
  if not exists (select 1 from public.onboarding_tasks where instance_id = i.id and kind = 'document' and doc_type = p_doc_type
                  and owner_role = 'employee' and status not in ('approved', 'waived', 'cancelled')) then
    raise exception 'This document is not requested (or is already approved)' using errcode = '22023';
  end if;
  if p_doc_type in ('passport', 'visa', 'emirates_id', 'labor_card', 'health_card') and p_expiry_date is null then
    raise exception 'Enter the expiry date shown on the document' using errcode = '22023';
  end if;
  if exists (select 1 from public.employee_documents where employee_id = i.employee_id and doc_type = p_doc_type
              and review_status = 'pending_review' and upload_confirmed) then
    raise exception 'This document is already waiting for review' using errcode = '22023';
  end if;
  -- An expired approved copy is renewed (superseded); otherwise it is a first upload.
  select id into v_current from public.employee_documents where employee_id = i.employee_id and doc_type = p_doc_type
     and is_current and review_status = 'approved';
  v_path := format('%s/%s/%s/1/%s.%s', i.entity_id, i.employee_id, v_new, v_new, lower(p_file_extension));
  insert into public.employee_documents (id, employee_id, doc_type, storage_path, expiry_date, notes, review_status, version_number,
    supersedes_document_id, is_current, submitted_by, submitted_at, upload_confirmed)
  values (v_new, i.employee_id, p_doc_type, v_path, p_expiry_date, p_notes, 'pending_review', 1, v_current, false, auth.uid(), now(), false);
  update public.onboarding_tasks set status = 'in_progress', updated_at = now()
   where instance_id = i.id and kind = 'document' and doc_type = p_doc_type and status in ('not_started', 'changes_required');
  perform public._onb_audit(i.id, 'employee_documents', v_new, 'document_upload_staged', null,
    jsonb_build_object('doc_type', p_doc_type, 'source', 'onboarding_portal'));
  return jsonb_build_object('id', v_new, 'storage_path', v_path);
end;
$$;

-- Salary payment details. IBAN format: AE + 21 digits (UAE IBAN).
create or replace function public.save_my_payment_details(p_method text, p_bank_name text, p_account_name text, p_iban text,
  p_routing_code text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  v_iban text := nullif(upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g')), '');
  v_id uuid;
begin
  i := public._onb_my_open_instance();
  if i.id is null then raise exception 'No open onboarding for your account' using errcode = 'P0002'; end if;
  if p_method = 'bank_transfer' and (v_iban is null or v_iban !~ '^AE[0-9]{21}$') then
    raise exception 'Enter a UAE IBAN: AE followed by 21 digits' using errcode = '22023';
  end if;
  if exists (select 1 from public.employee_payment_details where employee_id = i.employee_id and status = 'verified') then
    raise exception 'Your payment details are already verified. Ask payroll to change them.' using errcode = '22023';
  end if;
  update public.employee_payment_details set status = 'superseded' where employee_id = i.employee_id and status = 'submitted';
  insert into public.employee_payment_details (employee_id, method, bank_name, account_name, iban, routing_code, submitted_by)
  values (i.employee_id, p_method, nullif(btrim(coalesce(p_bank_name, '')), ''), nullif(btrim(coalesce(p_account_name, '')), ''),
          v_iban, nullif(btrim(coalesce(p_routing_code, '')), ''), auth.uid())
  returning id into v_id;
  perform public._onb_audit(i.id, 'employee_payment_details', v_id, 'payment_details_submitted', null,
    jsonb_build_object('method', p_method, 'iban_last4', right(v_iban, 4)));
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.acknowledge_onboarding_policy(p_policy_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  pol public.onboarding_policies;
  v_id uuid;
  v_emp uuid := public.my_employee_id();
begin
  if v_emp is null then raise exception 'No employee record for this login' using errcode = '42501'; end if;
  select * into pol from public.onboarding_policies where id = p_policy_id;
  if pol.id is null or not pol.is_active or pol.entity_id <> public.payroll_employee_entity(v_emp) then
    raise exception 'Policy not found' using errcode = 'P0002';
  end if;
  select * into i from public.onboarding_instances where employee_id = v_emp and status not in ('cancelled', 'withdrawn')
   order by created_at desc limit 1;
  insert into public.employee_acknowledgements (employee_id, onboarding_instance_id, policy_id, policy_key, policy_version, acknowledged_by)
  values (v_emp, i.id, pol.id, pol.policy_key, pol.version, auth.uid())
  on conflict (employee_id, policy_id) do nothing
  returning id into v_id;
  if v_id is not null and i.id is not null then
    perform public._onb_audit(i.id, 'employee_acknowledgements', v_id, 'policy_acknowledged', null,
      jsonb_build_object('policy_key', pol.policy_key, 'version', pol.version));
    perform public._onb_sync_derived(i.id);  -- also completes post-activation acknowledgement tasks
    perform public._onb_recompute(i.id);
  end if;
  return jsonb_build_object('ok', true, 'already', v_id is null);
end;
$$;

-- The employee's own acceptance of the current HR-approved contract.
-- Idempotent; a newer contract version needs a new acceptance.
create or replace function public.accept_employment_contract(p_onboarding_instance_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  d public.employee_documents;
  v_id uuid;
begin
  select * into i from public.onboarding_instances where id = p_onboarding_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  if not public._onb_is_self(i.id) then raise exception 'Only the employee can accept their contract' using errcode = '42501'; end if;
  select * into d from public.employee_documents where employee_id = i.employee_id and doc_type = 'contract' and is_current
     and review_status = 'approved' order by version_number desc limit 1;
  if d.id is null then raise exception 'Your contract has not been approved by HR yet' using errcode = '22023'; end if;
  insert into public.employee_contract_acceptances (employee_id, onboarding_instance_id, document_id, document_version, accepted_by)
  values (i.employee_id, i.id, d.id, d.version_number, auth.uid())
  on conflict (onboarding_instance_id, document_id) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.employee_contract_acceptances where onboarding_instance_id = i.id and document_id = d.id;
    return jsonb_build_object('ok', true, 'already_accepted', true, 'acceptance_id', v_id);
  end if;
  perform public._onb_audit(i.id, 'employee_contract_acceptances', v_id, 'contract_accepted', null,
    jsonb_build_object('document_id', d.id, 'document_version', d.version_number));
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'already_accepted', false, 'acceptance_id', v_id);
end;
$$;

create or replace function public.get_my_contract()
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_emp uuid := public.my_employee_id(); d public.employee_documents;
begin
  if v_emp is null then raise exception 'No employee record for this login' using errcode = '42501'; end if;
  select * into d from public.employee_documents where employee_id = v_emp and doc_type = 'contract' and is_current
     and review_status = 'approved' order by version_number desc limit 1;
  if d.id is null then return jsonb_build_object('ok', true, 'contract', null); end if;
  -- Logged here: log_document_access() only accepts active employees.
  insert into public.audit_log (table_name, record_id, changed_by, action, entity_id, employee_id)
  values ('employee_documents', d.id, auth.uid(), 'preview', public.payroll_employee_entity(v_emp), v_emp);
  return jsonb_build_object('ok', true, 'contract', jsonb_build_object('document_id', d.id, 'version', d.version_number,
    'expiry_date', d.expiry_date, 'reviewed_at', d.reviewed_at, 'storage_path', d.storage_path,
    'accepted_at', (select max(a.accepted_at) from public.employee_contract_acceptances a where a.document_id = d.id)));
end;
$$;

create or replace function public.get_my_job_description()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_emp uuid := public.my_employee_id(); p public.positions;
begin
  if v_emp is null then raise exception 'No employee record for this login' using errcode = '42501'; end if;
  select pos.* into p from public.employees e join public.positions pos on pos.id = e.position_id where e.id = v_emp;
  if p.id is null then return jsonb_build_object('ok', true, 'position', null); end if;
  return jsonb_build_object('ok', true, 'position', jsonb_build_object('position_id', p.id, 'title', p.title,
    'department', p.department, 'description', p.description));
end;
$$;

-- ------------------------------------------------ section submission
-- The employee (or a section's owner) submits a whole section for review.
-- Sections without a reviewer (acknowledgements) complete on submit.
create or replace function public.submit_onboarding_section(p_instance_id uuid, p_section text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  t record;
  v_missing text[] := '{}';
  v_version integer;
  v_id uuid;
  v_reviewer boolean;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  if i.status not in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation',
                      'activated', 'day_one', 'in_progress') then
    raise exception 'This onboarding is closed' using errcode = '22023';
  end if;
  if not exists (select 1 from public.onboarding_tasks where instance_id = i.id and section = p_section) then
    raise exception 'Unknown section %', p_section using errcode = '22023';
  end if;
  if not exists (select 1 from public.onboarding_tasks where instance_id = i.id and section = p_section
                  and public._onb_can_own(i.id, owner_role)) then
    raise exception 'You cannot submit this section' using errcode = '42501';
  end if;
  perform public._onb_sync_derived(i.id);
  select * into e from public.employees where id = i.employee_id;

  for t in select * from public.onboarding_tasks where instance_id = i.id and section = p_section and is_required
             and status not in ('approved', 'waived', 'cancelled', 'submitted') loop
    if t.kind = 'profile' then
      if t.item_key = 'personal_details' and (e.phone is null or e.dob is null or e.nationality is null or e.gender is null) then
        v_missing := v_missing || 'phone, date of birth, gender and nationality';
      elsif t.item_key = 'emergency_contact' and (e.emergency_contact_name is null or e.emergency_contact_phone is null or e.residential_address is null) then
        v_missing := v_missing || 'address and emergency contact';
      end if;
    elsif t.kind = 'document' then
      v_missing := v_missing || (t.item_label || ' (upload it first)');
    elsif t.kind in ('acknowledgement', 'payment_details', 'contract_acceptance') then
      v_missing := v_missing || t.item_label;
    end if;
  end loop;
  if cardinality(v_missing) > 0 then
    raise exception 'Complete these first: %', array_to_string(v_missing, '; ') using errcode = '22023';
  end if;

  select coalesce(max(version), 0) + 1 into v_version from public.onboarding_section_submissions where instance_id = i.id and section = p_section;
  v_reviewer := exists (select 1 from public.onboarding_tasks where instance_id = i.id and section = p_section
                         and reviewer_role is not null and kind in ('manual', 'profile'));
  insert into public.onboarding_section_submissions (instance_id, section, version, status, snapshot, submitted_by)
  values (i.id, p_section, v_version, case when v_reviewer then 'submitted' else 'approved' end,
    case when p_section = 'profile' then jsonb_build_object('phone', e.phone, 'dob', e.dob, 'gender', e.gender,
      'nationality', e.nationality, 'residential_address', e.residential_address,
      'emergency_contact_name', e.emergency_contact_name, 'emergency_contact_phone', e.emergency_contact_phone)
    else '{}'::jsonb end, auth.uid())
  returning id into v_id;
  update public.onboarding_tasks
     set status = case when reviewer_role is null then 'approved' else 'submitted' end,
         submitted_by = auth.uid(), submitted_at = now(), updated_at = now()
   where instance_id = i.id and section = p_section and kind in ('manual', 'profile')
     and status in ('not_started', 'in_progress', 'changes_required');
  perform public._onb_audit(i.id, 'onboarding_section_submissions', v_id, 'onboarding_section_submitted', null,
    jsonb_build_object('section', p_section, 'version', v_version));
  perform public._onb_touch(i.id);
  return coalesce(public._onb_recompute(i.id), public._onb_readiness(i.id, 'employee'));
end;
$$;

-- A single task, by its owner role. Dependencies must be complete.
-- Reviewed tasks go to "submitted"; unreviewed ones complete.
create or replace function public.complete_onboarding_task(p_task_id uuid, p_evidence jsonb default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  t public.onboarding_tasks;
  i public.onboarding_instances;
  v_blocking text;
  v_new text;
begin
  select * into t from public.onboarding_tasks where id = p_task_id for update;
  if t.id is null then raise exception 'Task not found' using errcode = 'P0002'; end if;
  select * into i from public.onboarding_instances where id = t.instance_id;
  if i.status in ('completed', 'cancelled', 'withdrawn') then raise exception 'This onboarding is closed' using errcode = '22023'; end if;
  if t.kind <> 'manual' then
    raise exception 'This task completes itself from its record (document, acknowledgement, payment or pay)' using errcode = '22023';
  end if;
  if not public._onb_can_own(i.id, t.owner_role) then
    raise exception 'This task belongs to the % role', replace(t.owner_role, '_', ' ') using errcode = '42501';
  end if;
  if t.status in ('approved', 'waived', 'cancelled') then
    return jsonb_build_object('ok', true, 'already', true, 'status', t.status);
  end if;
  select string_agg(d.item_label, ', ') into v_blocking
    from public.onboarding_task_dependencies x join public.onboarding_tasks d on d.id = x.depends_on_task_id
   where x.task_id = t.id and d.status not in ('approved', 'waived', 'cancelled');
  if v_blocking is not null then raise exception 'Complete these first: %', v_blocking using errcode = '22023'; end if;
  if t.phase <> 'pre_activation' and i.status not in ('activated', 'day_one', 'in_progress') then
    raise exception 'This task opens after activation' using errcode = '22023';
  end if;
  v_new := case when t.reviewer_role is null then 'approved' else 'submitted' end;
  update public.onboarding_tasks set status = v_new, evidence = p_evidence, submitted_by = auth.uid(), submitted_at = now(),
         reviewed_by = case when v_new = 'approved' then auth.uid() end, reviewed_at = case when v_new = 'approved' then now() end,
         updated_at = now()
   where id = t.id;
  perform public._onb_audit(i.id, 'onboarding_tasks', t.id, 'onboarding_task_completed', jsonb_build_object('status', t.status),
    jsonb_build_object('status', v_new, 'evidence', p_evidence));
  perform public._onb_touch(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'already', false, 'status', v_new);
end;
$$;

do $$
declare f text;
begin
  execute 'revoke all on function public._onb_my_open_instance() from public, anon, authenticated';
  foreach f in array array['issue_onboarding_invitation(uuid)', 'reissue_onboarding_invitation(uuid, text, text)',
    'get_my_onboarding()', 'save_my_onboarding_profile(jsonb)',
    'stage_my_onboarding_document(public.document_type, text, date, text)',
    'save_my_payment_details(text, text, text, text, text)', 'acknowledge_onboarding_policy(uuid)',
    'accept_employment_contract(uuid)', 'get_my_contract()', 'get_my_job_description()',
    'submit_onboarding_section(uuid, text)', 'complete_onboarding_task(uuid, jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ===== migrations/005_onboarding_build_c_reviews.sql
-- =====================================================================
-- Migration 005 — Build C: reviews, pay, payment verification,
-- exceptions and the dashboard summary.
-- Maker-checker everywhere: the person who submitted or set something
-- never approves it (the owner is the only exception, as elsewhere).
-- Documents keep their existing review path (approve_document /
-- reject_document); their tasks follow automatically (_onb_sync_derived).
-- Depends on: 001–004.
-- =====================================================================


-- --------------------------------------------------- section reviews
create or replace function public.review_onboarding_section(p_instance_id uuid, p_section text, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  s public.onboarding_section_submissions;
  v_role text;
  v_review uuid;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  if p_decision not in ('approved', 'changes_required', 'rejected') then
    raise exception 'Decision must be approved, changes_required or rejected' using errcode = '22023';
  end if;
  if p_decision <> 'approved' and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Tell the employee what to change' using errcode = '22023';
  end if;
  select * into s from public.onboarding_section_submissions where instance_id = i.id and section = p_section
   order by version desc limit 1 for update;
  if s.id is null or s.status <> 'submitted' then
    raise exception 'Nothing in this section is waiting for review' using errcode = '22023';
  end if;
  select t.reviewer_role into v_role from public.onboarding_tasks t
   where t.instance_id = i.id and t.section = p_section and t.status = 'submitted' and t.reviewer_role is not null
     and public._onb_can_review(i.id, t.reviewer_role) limit 1;
  if v_role is null then raise exception 'You cannot review this section' using errcode = '42501'; end if;
  if s.submitted_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You submitted this section; someone else must review it' using errcode = '42501';
  end if;

  update public.onboarding_section_submissions set status = p_decision where id = s.id;
  update public.onboarding_tasks
     set status = case when p_decision = 'approved' then 'approved' else 'changes_required' end,
         reviewed_by = auth.uid(), reviewed_at = now(), review_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now()
   where instance_id = i.id and section = p_section and status = 'submitted' and kind in ('manual', 'profile');
  insert into public.onboarding_reviews (instance_id, section, submission_id, reviewer_id, reviewer_role, decision, reason, before_state)
  values (i.id, p_section, s.id, auth.uid(), v_role, p_decision, nullif(btrim(coalesce(p_reason, '')), ''), s.snapshot)
  returning id into v_review;
  perform public._onb_audit(i.id, 'onboarding_reviews', v_review,
    case when p_decision = 'approved' then 'onboarding_section_approved' else 'onboarding_changes_required' end,
    null, jsonb_build_object('section', p_section, 'version', s.version, 'reason', p_reason));
  if p_decision <> 'approved' then
    perform public.create_notification(i.entity_id, null, i.employee_id, 'onboarding_changes_required',
      'Changes needed on your onboarding', coalesce(p_reason, 'Please review and resubmit.'), 'onboarding_instance', i.id, 'high',
      format('onb:%s:changes:%s:%s', i.id, p_section, s.version));
  end if;
  perform public._onb_touch(i.id);
  return coalesce(public._onb_recompute(i.id), public._onb_readiness(i.id, 'full'));
end;
$$;

-- A single reviewed manual task (e.g. uniform issued, reviewed by the LM).
create or replace function public.review_onboarding_task(p_task_id uuid, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.onboarding_tasks; v_review uuid;
begin
  select * into t from public.onboarding_tasks where id = p_task_id for update;
  if t.id is null then raise exception 'Task not found' using errcode = 'P0002'; end if;
  if t.status <> 'submitted' or t.kind not in ('manual', 'profile') then
    raise exception 'This task is not waiting for review here' using errcode = '22023';
  end if;
  if p_decision not in ('approved', 'changes_required') then raise exception 'Decision must be approved or changes_required' using errcode = '22023'; end if;
  if p_decision = 'changes_required' and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  if not public._onb_can_review(t.instance_id, t.reviewer_role) then raise exception 'You cannot review this task' using errcode = '42501'; end if;
  if t.submitted_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You completed this task; someone else must review it' using errcode = '42501';
  end if;
  update public.onboarding_tasks set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(),
         review_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now() where id = t.id;
  insert into public.onboarding_reviews (instance_id, section, task_id, reviewer_id, reviewer_role, decision, reason, before_state)
  values (t.instance_id, t.section, t.id, auth.uid(), t.reviewer_role, p_decision, nullif(btrim(coalesce(p_reason, '')), ''), t.evidence)
  returning id into v_review;
  perform public._onb_audit(t.instance_id, 'onboarding_tasks', t.id, 'onboarding_task_reviewed', jsonb_build_object('status', t.status),
    jsonb_build_object('status', p_decision, 'reason', p_reason));
  perform public._onb_touch(t.instance_id);
  perform public._onb_recompute(t.instance_id);
  return jsonb_build_object('ok', true, 'status', p_decision);
end;
$$;

-- Waive an optional/non-statutory task. Statutory items can never be waived.
create or replace function public.waive_onboarding_task(p_task_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.onboarding_tasks;
begin
  select * into t from public.onboarding_tasks where id = p_task_id for update;
  if t.id is null then raise exception 'Task not found' using errcode = 'P0002'; end if;
  perform public._onb_require(t.instance_id, 'manage');
  if t.is_statutory or not t.is_waivable then raise exception 'This item is required by law or policy and cannot be waived' using errcode = '22023'; end if;
  if t.kind in ('compensation', 'contract_acceptance') then raise exception 'Pay and contract acceptance cannot be waived' using errcode = '22023'; end if;
  if t.kind = 'document' and t.doc_type in ('passport', 'visa', 'emirates_id', 'contract') then
    raise exception 'Key documents cannot be waived' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if t.status in ('approved', 'waived', 'cancelled') then return jsonb_build_object('ok', true, 'already', true); end if;
  update public.onboarding_tasks set status = 'waived', waived_by = auth.uid(), waived_at = now(), waived_reason = btrim(p_reason),
         updated_at = now() where id = t.id;
  perform public._onb_audit(t.instance_id, 'onboarding_tasks', t.id, 'onboarding_task_waived', jsonb_build_object('status', t.status),
    jsonb_build_object('reason', p_reason));
  perform public._onb_touch(t.instance_id);
  perform public._onb_recompute(t.instance_id);
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

-- ------------------------------------------------------------- pay
-- HR/payroll enters the pay to apply at activation. It lives only in
-- onboarding_pending_compensation (restricted table); it becomes a
-- compensation_versions row only when the employee is activated.
create or replace function public.set_onboarding_pending_compensation(p_instance_id uuid, p_effective_from date, p_pay_type text,
  p_basic_monthly numeric, p_hourly_rate numeric, p_overtime_eligible boolean, p_reason text, p_variance_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  v_old public.onboarding_pending_compensation;
  v_offer numeric;
  v_amount numeric := case when p_pay_type = 'monthly' then p_basic_monthly else p_hourly_rate end;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  if not (public._onb_can(i.id, 'manage') or public._onb_can(i.id, 'payroll')) then
    raise exception 'You cannot set pay for this onboarding' using errcode = '42501';
  end if;
  if public.payroll_employee_entity(i.employee_id) is null or public._payroll_can_edit_pay(i.employee_id) is not null then
    raise exception '%', coalesce(public._payroll_can_edit_pay(i.employee_id), 'No permission to change pay') using errcode = '42501';
  end if;
  if i.status not in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation') then
    raise exception 'Pay after activation is changed in Payroll' using errcode = '22023';
  end if;
  if p_pay_type not in ('monthly', 'hourly') then raise exception 'Pay type must be monthly or hourly' using errcode = '22023'; end if;
  if coalesce(v_amount, 0) <= 0 or round(v_amount, 2) <> v_amount then raise exception 'Enter an amount above zero' using errcode = '22023'; end if;
  if i.offer_id is not null then select proposed_salary_amount into v_offer from public.offers where id = i.offer_id; end if;
  if v_offer is not null and p_pay_type = 'monthly' and v_offer <> p_basic_monthly
     and nullif(btrim(coalesce(p_variance_reason, '')), '') is null then
    raise exception 'The pay differs from the accepted offer (%). Give a reason for the difference.', v_offer using errcode = '22023';
  end if;
  select * into v_old from public.onboarding_pending_compensation where instance_id = i.id;
  insert into public.onboarding_pending_compensation (instance_id, pay_type, basic_monthly, hourly_rate, overtime_eligible, effective_from,
    reason, offer_amount, variance_reason, status, set_by, set_at)
  values (i.id, p_pay_type, case when p_pay_type = 'monthly' then p_basic_monthly end, case when p_pay_type = 'hourly' then p_hourly_rate end,
    coalesce(p_overtime_eligible, true), coalesce(p_effective_from, i.proposed_start_date), nullif(btrim(coalesce(p_reason, '')), ''),
    v_offer, nullif(btrim(coalesce(p_variance_reason, '')), ''), 'pending_review', auth.uid(), now())
  on conflict (instance_id) do update set pay_type = excluded.pay_type, basic_monthly = excluded.basic_monthly,
    hourly_rate = excluded.hourly_rate, overtime_eligible = excluded.overtime_eligible, effective_from = excluded.effective_from,
    reason = excluded.reason, offer_amount = excluded.offer_amount, variance_reason = excluded.variance_reason,
    status = 'pending_review', set_by = excluded.set_by, set_at = now(), reviewed_by = null, reviewed_at = null, review_reason = null;
  -- Audit without amounts in onboarding-visible fields: amounts go only to the payroll audit trail shape.
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values ('onboarding_pending_compensation', i.id, auth.uid(), 'onboarding_pay_set',
    case when v_old.instance_id is not null then jsonb_build_object('pay_type', v_old.pay_type, 'basic_monthly', v_old.basic_monthly,
      'hourly_rate', v_old.hourly_rate, 'status', v_old.status) end,
    jsonb_build_object('pay_type', p_pay_type, 'basic_monthly', p_basic_monthly, 'hourly_rate', p_hourly_rate,
      'offer_amount', v_offer, 'variance_reason', p_variance_reason, 'operation_id', public._onb_op(), 'onboarding_instance_id', i.id),
    i.entity_id, i.employee_id);
  perform public._onb_touch(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'status', 'pending_review', 'differs_from_offer', v_offer is not null and v_offer <> v_amount);
end;
$$;

create or replace function public.review_onboarding_compensation(p_instance_id uuid, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.onboarding_pending_compensation; i public.onboarding_instances;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  perform public._onb_require(i.id, 'payroll');
  select * into c from public.onboarding_pending_compensation where instance_id = i.id for update;
  if c.instance_id is null or c.status <> 'pending_review' then raise exception 'No pay is waiting for review' using errcode = '22023'; end if;
  if p_decision not in ('approved', 'changes_required') then raise exception 'Decision must be approved or changes_required' using errcode = '22023'; end if;
  if p_decision = 'changes_required' and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  if c.set_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You entered this pay; another payroll approver must review it' using errcode = '42501';
  end if;
  if i.employee_id = public.my_employee_id() then raise exception 'You cannot review your own pay' using errcode = '42501'; end if;
  update public.onboarding_pending_compensation set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(),
         review_reason = nullif(btrim(coalesce(p_reason, '')), '') where instance_id = i.id;
  insert into public.onboarding_reviews (instance_id, section, reviewer_id, reviewer_role, decision, reason)
  values (i.id, 'payroll', auth.uid(), 'payroll', p_decision, nullif(btrim(coalesce(p_reason, '')), ''));
  perform public._onb_audit(i.id, 'onboarding_pending_compensation', i.id, 'onboarding_pay_reviewed', null,
    jsonb_build_object('decision', p_decision, 'reason', p_reason));
  perform public._onb_touch(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'status', p_decision);
end;
$$;

-- ----------------------------------------------- payment verification
create or replace function public.verify_payment_details(p_payment_details_id uuid, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare pd public.employee_payment_details; v_inst uuid; v_entity uuid;
begin
  select * into pd from public.employee_payment_details where id = p_payment_details_id for update;
  if pd.id is null then raise exception 'Payment details not found' using errcode = 'P0002'; end if;
  v_entity := public.payroll_employee_entity(pd.employee_id);
  if not public.payroll_can(v_entity, 'approve') then raise exception 'Only payroll approvers can verify bank details' using errcode = '42501'; end if;
  if pd.status <> 'submitted' then raise exception 'These details are not waiting for verification' using errcode = '22023'; end if;
  if pd.submitted_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You entered these details; someone else must verify them' using errcode = '42501';
  end if;
  if pd.employee_id = public.my_employee_id() then raise exception 'You cannot verify your own bank details' using errcode = '42501'; end if;
  if p_decision not in ('verified', 'rejected') then raise exception 'Decision must be verified or rejected' using errcode = '22023'; end if;
  if p_decision = 'rejected' and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  update public.employee_payment_details set status = p_decision, verified_by = auth.uid(), verified_at = now(),
         rejection_reason = case when p_decision = 'rejected' then btrim(p_reason) end where id = pd.id;
  select id into v_inst from public.onboarding_instances where employee_id = pd.employee_id
     and status not in ('completed', 'cancelled', 'withdrawn') order by created_at desc limit 1;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_payment_details', pd.id, auth.uid(), 'payment_details_' || p_decision,
    jsonb_build_object('reason', p_reason, 'iban_last4', right(pd.iban, 4), 'operation_id', public._onb_op(), 'onboarding_instance_id', v_inst),
    v_entity, pd.employee_id);
  if v_inst is not null then
    if p_decision = 'rejected' then
      perform public.create_notification(v_entity, null, pd.employee_id, 'onboarding_changes_required', 'Check your bank details',
        btrim(p_reason), 'onboarding_instance', v_inst, 'high', format('onb:%s:bank:%s', v_inst, pd.id));
    end if;
    perform public._onb_touch(v_inst);
    perform public._onb_recompute(v_inst);
  end if;
  return jsonb_build_object('ok', true, 'status', p_decision);
end;
$$;

-- -------------------------------------------------------- exceptions
create or replace function public.raise_onboarding_exception(p_instance_id uuid, p_type text, p_description text,
  p_owner_role text default 'hr', p_is_blocking boolean default true, p_due_date date default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id uuid; i public.onboarding_instances;
begin
  perform public._onb_require(p_instance_id, 'operate');
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.status in ('completed', 'cancelled', 'withdrawn') then raise exception 'This onboarding is closed' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_description, '')), '') is null then raise exception 'Describe the problem' using errcode = '22023'; end if;
  insert into public.onboarding_exceptions (instance_id, exception_type, is_blocking, description, owner_role, due_date, raised_by)
  values (i.id, p_type, coalesce(p_is_blocking, true), btrim(p_description), coalesce(p_owner_role, 'hr'), p_due_date, auth.uid())
  returning id into v_id;
  perform public._onb_audit(i.id, 'onboarding_exceptions', v_id, 'onboarding_exception_raised', null,
    jsonb_build_object('type', p_type, 'blocking', p_is_blocking, 'owner_role', p_owner_role));
  perform public._onb_touch(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'exception_id', v_id);
end;
$$;

create or replace function public.resolve_onboarding_exception(p_exception_id uuid, p_resolution text, p_cancel boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare x public.onboarding_exceptions;
begin
  select * into x from public.onboarding_exceptions where id = p_exception_id for update;
  if x.id is null then raise exception 'Exception not found' using errcode = 'P0002'; end if;
  if not public._onb_can_own(x.instance_id, x.owner_role) and not public._onb_can(x.instance_id, 'manage') then
    raise exception 'This item belongs to the % role', x.owner_role using errcode = '42501';
  end if;
  if x.status <> 'open' then return jsonb_build_object('ok', true, 'already', true); end if;
  if nullif(btrim(coalesce(p_resolution, '')), '') is null then raise exception 'Say how it was resolved' using errcode = '22023'; end if;
  update public.onboarding_exceptions set status = case when p_cancel then 'cancelled' else 'resolved' end,
         resolution = btrim(p_resolution), resolved_by = auth.uid(), resolved_at = now() where id = x.id;
  perform public._onb_audit(x.instance_id, 'onboarding_exceptions', x.id, 'onboarding_exception_resolved', null,
    jsonb_build_object('resolution', p_resolution, 'cancelled', p_cancel));
  perform public._onb_touch(x.instance_id);
  perform public._onb_recompute(x.instance_id);
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

-- -------------------------------------------------- dashboard summary
-- Counts only, in the caller's scope.
create or replace function public.onboarding_dashboard_summary(p_entity_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  v_role public.user_role := public.my_role();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  r jsonb;
begin
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())
          or public.payroll_can(p_entity_id, 'approve')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  with scope as (
    select i.* from public.onboarding_instances i
     where i.entity_id = p_entity_id
       and (v_role in ('owner', 'entity_admin') or public.payroll_can(p_entity_id, 'approve')
            or (v_role = 'location_manager' and i.home_location_id = public.my_location())))
  select jsonb_build_object(
    'open', count(*) filter (where status not in ('completed', 'cancelled', 'withdrawn')),
    'by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from scope group by status) s), '{}'::jsonb),
    'starting_7_days', count(*) filter (where status not in ('completed', 'cancelled', 'withdrawn', 'activated', 'day_one', 'in_progress')
                                         and proposed_start_date between v_today and v_today + 7),
    'start_at_risk', count(*) filter (where status not in ('ready_for_activation', 'completed', 'cancelled', 'withdrawn', 'activated', 'day_one', 'in_progress')
                                       and proposed_start_date <= v_today + 3),
    'ready_for_activation', count(*) filter (where status = 'ready_for_activation'),
    'awaiting_review', (select count(*) from public.onboarding_tasks t join scope s on s.id = t.instance_id where t.status = 'submitted'),
    'overdue_tasks', (select count(*) from public.onboarding_tasks t join scope s on s.id = t.instance_id
                       where t.status not in ('approved', 'waived', 'cancelled') and t.due_date < v_today
                         and s.status not in ('completed', 'cancelled', 'withdrawn')),
    'open_exceptions', (select count(*) from public.onboarding_exceptions x join scope s on s.id = x.instance_id where x.status = 'open'),
    'pay_awaiting_review', case when public.payroll_can(p_entity_id, 'approve')
      then (select count(*) from public.onboarding_pending_compensation c join scope s on s.id = c.instance_id where c.status = 'pending_review') end,
    'bank_awaiting_verification', case when public.payroll_can(p_entity_id, 'approve')
      then (select count(*) from public.employee_payment_details pd join scope s on s.employee_id = pd.employee_id where pd.status = 'submitted') end,
    'probation_reviews_due', (select count(*) from public.employee_probation_periods pp join public.employees e on e.id = pp.employee_id
                               where e.entity_id = p_entity_id and pp.status = 'active' and pp.review_due_date <= v_today
                                 and (v_role <> 'location_manager' or e.home_location_id = public.my_location())))
    into r from scope;
  return r;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['review_onboarding_section(uuid, text, text, text)', 'review_onboarding_task(uuid, text, text)',
    'waive_onboarding_task(uuid, text)',
    'set_onboarding_pending_compensation(uuid, date, text, numeric, numeric, boolean, text, text)',
    'review_onboarding_compensation(uuid, text, text)', 'verify_payment_details(uuid, text, text)',
    'raise_onboarding_exception(uuid, text, text, text, boolean, date)', 'resolve_onboarding_exception(uuid, text, boolean)',
    'onboarding_dashboard_summary(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ===== migrations/006_onboarding_build_d_activation.sql
-- =====================================================================
-- Migration 006 — Build D: approve and activate (one transaction).
-- Readiness is recomputed on the server at the moment of approval; the
-- client's view of "ready" is never trusted. Everything below happens
-- or nothing does: status, start date, pay version, probation, day-one
-- tasks, notifications, audit. A retry after success returns the first
-- result (idempotent on activation_operation_id).
-- Depends on: 001–005, set_employee_status, payroll_set_compensation.
-- =====================================================================


create or replace function public.approve_and_activate_employee(p_instance_id uuid, p_expected_version integer, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  s public.onboarding_settings;
  c public.onboarding_pending_compensation;
  r jsonb;
  v_op uuid;
  v_start date;
  v_prob_end date;
  v_prob_id uuid;
  v_tasks integer;
  v_comp jsonb;
  v_mgr_user uuid;
  v_user uuid;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  perform public._onb_require(i.id, 'approve');

  -- Idempotent retry.
  if i.activation_operation_id is not null then
    return jsonb_build_object('ok', true, 'already_activated', true, 'operation_id', i.activation_operation_id,
      'employee_id', i.employee_id, 'status', i.status, 'activated_at', i.activated_at);
  end if;
  if i.status <> 'ready_for_activation' then
    -- Status may be stale; recompute once before refusing.
    perform public._onb_recompute(i.id);
    select * into i from public.onboarding_instances where id = p_instance_id;
  end if;
  if p_expected_version is distinct from i.row_version then
    raise exception 'This onboarding changed since you opened it; reload and check again' using errcode = '40001';
  end if;

  select * into e from public.employees where id = i.employee_id for update;
  if e.id = public.my_employee_id() then raise exception 'You cannot activate yourself' using errcode = '42501'; end if;
  if e.employment_status <> 'pre_boarding' then
    raise exception 'Employee is % (expected pre-boarding)', e.employment_status using errcode = '22023';
  end if;

  s := public._onb_settings(i.entity_id);
  select * into c from public.onboarding_pending_compensation where instance_id = i.id for update;
  if s.require_distinct_activation_approver and public.my_role() <> 'owner'
     and (c.set_by = auth.uid() or c.reviewed_by = auth.uid()) then
    raise exception 'You entered or reviewed this employee''s pay; a different approver must activate' using errcode = '42501';
  end if;

  r := public._onb_readiness(i.id, 'full');
  if not (r ->> 'ready')::boolean then
    raise exception 'Not ready to activate: %', (select string_agg(b ->> 'message', ' | ') from jsonb_array_elements(r -> 'blockers') b)
      using errcode = '22023', hint = 'Resolve the blocking items, then approve again.';
  end if;
  if i.status <> 'ready_for_activation' then
    raise exception 'Onboarding is % (expected ready for activation)', i.status using errcode = '22023';
  end if;

  v_op := public._onb_op();
  v_start := i.proposed_start_date;

  -- 1. Employee master: start date, then status through the existing gate
  --    (it re-checks the key documents). The flag lets 010's guard pass.
  update public.employees set join_date = v_start, home_location_id = i.home_location_id, position_id = i.position_id,
         employment_type = i.employment_type, reporting_manager_employee_id = i.reporting_manager_employee_id, updated_at = now()
   where id = e.id;
  perform set_config('app.onboarding_activation', i.id::text, true);
  perform public.set_employee_status(e.id, 'active', coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Activated from onboarding'));
  perform set_config('app.onboarding_activation', '', true);

  -- 2. Pay: the approved pending pay becomes the first compensation version.
  v_comp := public.payroll_set_compensation(e.id, coalesce(c.effective_from, v_start), c.pay_type, c.basic_monthly, c.hourly_rate,
    c.overtime_eligible, coalesce(c.reason, 'Starting pay (onboarding)'));

  -- 3. Probation (Decree-Law 33/2021 Art. 9: at most six months).
  if s.probation_months > 0 then
    v_prob_end := (v_start + make_interval(months => s.probation_months))::date - 1;
    insert into public.employee_probation_periods (employee_id, onboarding_instance_id, start_date, end_date, review_due_date)
    values (e.id, i.id, v_start, v_prob_end, greatest(v_start, v_prob_end - s.probation_review_days_before))
    on conflict do nothing
    returning id into v_prob_id;
    update public.employees set probation_end_date = v_prob_end where id = e.id;
  end if;

  -- 4. Day-one and first-weeks tasks.
  update public.onboarding_instances set actual_start_date = v_start where id = i.id;
  v_tasks := public._onb_generate_tasks(i.id, 'day_one') + public._onb_generate_tasks(i.id, 'initial_period');
  perform public._onb_sync_derived(i.id);  -- e.g. a policy already acknowledged completes its day-one task

  -- 5. Instance.
  perform public._onb_set_status(i.id, 'activated', p_reason);
  update public.onboarding_instances set activation_operation_id = v_op, activated_at = now(), activated_by = auth.uid(),
         activation_reason = nullif(btrim(coalesce(p_reason, '')), '') where id = i.id;

  -- 6. Notifications (deduped; no pay in any message).
  perform public.create_notification(i.entity_id, null, e.id, 'onboarding_activated', 'Welcome to the team',
    format('Your start date is %s. Your first-day checklist is in the app.', to_char(v_start, 'DD Mon YYYY')),
    'onboarding_instance', i.id, 'normal', format('onb:%s:activated:employee', i.id));
  select m.auth_user_id into v_mgr_user from public.employees m where m.id = i.reporting_manager_employee_id;
  if v_mgr_user is not null then
    perform public.create_notification(i.entity_id, v_mgr_user, null, 'onboarding_activated', 'New starter activated',
      format('%s starts on %s.', e.full_name, to_char(v_start, 'DD Mon YYYY')), 'onboarding_instance', i.id, 'normal',
      format('onb:%s:activated:manager', i.id));
  end if;
  for v_user in select p.id from public.profiles p where p.is_active and p.entity_id = i.entity_id and p.role = 'entity_admin'
                  and p.id <> auth.uid() loop
    perform public.create_notification(i.entity_id, v_user, null, 'onboarding_activated', 'New starter activated',
      format('%s starts on %s.', e.full_name, to_char(v_start, 'DD Mon YYYY')), 'onboarding_instance', i.id, 'normal',
      format('onb:%s:activated:hr:%s', i.id, v_user));
  end loop;

  perform public._onb_audit(i.id, 'employees', e.id, 'employee_activated', jsonb_build_object('employment_status', 'pre_boarding'),
    jsonb_build_object('employment_status', 'active', 'join_date', v_start, 'probation_end_date', v_prob_end,
      'probation_period_id', v_prob_id, 'compensation_version_id', v_comp ->> 'version_id', 'post_start_tasks', v_tasks,
      'readiness', r, 'reason', p_reason));

  return jsonb_build_object('ok', true, 'already_activated', false, 'operation_id', v_op, 'employee_id', e.id,
    'status', 'activated', 'join_date', v_start, 'probation_end_date', v_prob_end, 'post_start_tasks', v_tasks);
end;
$$;

revoke all on function public.approve_and_activate_employee(uuid, integer, text) from public, anon;
grant execute on function public.approve_and_activate_employee(uuid, integer, text) to authenticated;

-- ===== migrations/007_onboarding_build_e_dayone_probation.sql
-- =====================================================================
-- Migration 007 — Build E: day one, closure, probation and reports.
-- Depends on: 001–006.
-- =====================================================================


-- ------------------------------------------------------------ day one
-- started  → day_one (then in_progress once day-one tasks are done)
-- no_show  → blocking exception for HR; employee stays active until HR decides
-- delayed  → new start date; the probation window moves with it
create or replace function public.record_day_one_outcome(p_instance_id uuid, p_outcome text, p_new_start_date date default null,
  p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  s public.onboarding_settings;
  v_end date;
begin
  perform public._onb_require(p_instance_id, 'operate');
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status not in ('activated', 'day_one') then raise exception 'Day one is recorded after activation' using errcode = '22023'; end if;
  if p_outcome not in ('started', 'no_show', 'delayed') then raise exception 'Outcome must be started, no_show or delayed' using errcode = '22023'; end if;
  if p_outcome <> 'started' and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if i.day_one_outcome = 'started' then return jsonb_build_object('ok', true, 'already', true); end if;

  update public.onboarding_instances set day_one_outcome = p_outcome, day_one_recorded_at = now(), day_one_recorded_by = auth.uid()
   where id = i.id;
  if p_outcome = 'started' then
    update public.onboarding_instances set actual_start_date = coalesce(actual_start_date, proposed_start_date) where id = i.id;
    perform public._onb_set_status(i.id, 'day_one', 'Employee started');
    perform public._onb_advance_post_start(i.id);  -- day-one tasks may already be done
  elsif p_outcome = 'no_show' then
    insert into public.onboarding_exceptions (instance_id, exception_type, description, owner_role, due_date, raised_by)
    values (i.id, 'no_show', btrim(p_reason), 'hr', (now() at time zone 'Asia/Dubai')::date + 1, auth.uid());
  else
    if p_new_start_date is null or p_new_start_date <= coalesce(i.actual_start_date, i.proposed_start_date) then
      raise exception 'Give the new (later) start date' using errcode = '22023';
    end if;
    s := public._onb_settings(i.entity_id);
    update public.onboarding_instances set actual_start_date = p_new_start_date, proposed_start_date = p_new_start_date,
           day_one_outcome = null where id = i.id;
    update public.employees set join_date = p_new_start_date, updated_at = now() where id = i.employee_id;
    if s.probation_months > 0 then
      v_end := (p_new_start_date + make_interval(months => s.probation_months))::date - 1;
      update public.employee_probation_periods set start_date = p_new_start_date, end_date = v_end,
             review_due_date = greatest(p_new_start_date, v_end - s.probation_review_days_before), updated_at = now()
       where onboarding_instance_id = i.id and status = 'active' and previous_period_id is null;
      update public.employees set probation_end_date = v_end where id = i.employee_id;
    end if;
    update public.onboarding_tasks t set due_date = t.due_date + (p_new_start_date - coalesce(i.actual_start_date, i.proposed_start_date))
     where t.instance_id = i.id and t.phase <> 'pre_activation' and t.status not in ('approved', 'waived', 'cancelled');
    insert into public.onboarding_exceptions (instance_id, exception_type, is_blocking, description, owner_role, raised_by, status,
      resolution, resolved_by, resolved_at)
    values (i.id, 'delayed_start', false, btrim(p_reason), 'hr', auth.uid(), 'resolved',
      'Start moved to ' || p_new_start_date, auth.uid(), now());
  end if;
  perform public._onb_audit(i.id, 'onboarding_instances', i.id, 'onboarding_day_one_recorded', null,
    jsonb_build_object('outcome', p_outcome, 'new_start_date', p_new_start_date, 'reason', p_reason));
  perform public._onb_touch(i.id);
  return jsonb_build_object('ok', true, 'already', false, 'outcome', p_outcome);
end;
$$;

-- Moves day_one → in_progress when every required day-one task is done.
create or replace function public._onb_advance_post_start(p_instance_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.status = 'day_one' and not exists (select 1 from public.onboarding_tasks where instance_id = i.id and phase = 'day_one'
       and is_required and status not in ('approved', 'waived', 'cancelled')) then
    perform public._onb_set_status(i.id, 'in_progress', 'Day-one tasks complete');
  end if;
end;
$$;

create or replace function public.trg_onb_task_post_start()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.phase = 'day_one' and new.status in ('approved', 'waived') and old.status is distinct from new.status then
    perform public._onb_advance_post_start(new.instance_id);
  end if;
  return new;
end;
$$;
drop trigger if exists onboarding_task_post_start on public.onboarding_tasks;
create trigger onboarding_task_post_start after update of status on public.onboarding_tasks
  for each row execute function public.trg_onb_task_post_start();

-- ------------------------------------------------------------ closure
create or replace function public.close_onboarding(p_instance_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances; v_open text; v_snap jsonb;
begin
  perform public._onb_require(p_instance_id, 'manage');
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status = 'completed' then return jsonb_build_object('ok', true, 'already', true); end if;
  if i.status not in ('day_one', 'in_progress') then raise exception 'Onboarding closes after the employee has started' using errcode = '22023'; end if;
  select string_agg(item_label, ', ') into v_open from public.onboarding_tasks
   where instance_id = i.id and is_required and status not in ('approved', 'waived', 'cancelled');
  if v_open is not null then raise exception 'Still open: %', v_open using errcode = '22023'; end if;
  if exists (select 1 from public.onboarding_exceptions where instance_id = i.id and status = 'open') then
    raise exception 'Resolve the open exceptions first' using errcode = '22023';
  end if;
  v_snap := jsonb_build_object(
    'closed_at', now(), 'notes', p_notes, 'activated_at', i.activated_at, 'actual_start_date', i.actual_start_date,
    'days_to_activate', extract(day from (i.activated_at - i.started_at))::integer,
    'tasks', (select jsonb_object_agg(status, n) from (select status, count(*) n from public.onboarding_tasks where instance_id = i.id group by status) x),
    'reviews', (select count(*) from public.onboarding_reviews where instance_id = i.id),
    'changes_requested', (select count(*) from public.onboarding_reviews where instance_id = i.id and decision <> 'approved'),
    'exceptions', (select count(*) from public.onboarding_exceptions where instance_id = i.id));
  perform public._onb_set_status(i.id, 'completed', p_notes);
  update public.onboarding_instances set completed_at = now(), closed_by = auth.uid(), closure_snapshot = v_snap where id = i.id;
  perform public._onb_audit(i.id, 'onboarding_instances', i.id, 'onboarding_completed', null, v_snap);
  return jsonb_build_object('ok', true, 'already', false, 'summary', v_snap);
end;
$$;

-- ---------------------------------------------------------- probation
create or replace function public._onb_probation_scope(p_period_id uuid, p_cap text)
returns public.employee_probation_periods language plpgsql stable security definer set search_path to '' as $$
declare pp public.employee_probation_periods; e public.employees; v_role public.user_role := public.my_role();
begin
  select * into pp from public.employee_probation_periods where id = p_period_id;
  if pp.id is null then raise exception 'Probation period not found' using errcode = 'P0002'; end if;
  select * into e from public.employees where id = pp.employee_id;
  if not public.is_active_user() or e.id = public.my_employee_id() or not (
       v_role = 'owner' or (v_role = 'entity_admin' and e.entity_id = public.my_entity())
       or (p_cap = 'review' and v_role = 'location_manager' and e.home_location_id = public.my_location())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return pp;
end;
$$;

create or replace function public.record_probation_review(p_period_id uuid, p_recommendation text, p_comments text, p_ratings jsonb default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare pp public.employee_probation_periods; v_id uuid;
begin
  pp := public._onb_probation_scope(p_period_id, 'review');
  if pp.status not in ('active', 'extended') then raise exception 'This probation is already decided' using errcode = '22023'; end if;
  insert into public.employee_probation_reviews (probation_period_id, reviewer_id, reviewer_role, recommendation, comments, ratings)
  values (pp.id, auth.uid(), public.my_role()::text, p_recommendation, p_comments, p_ratings) returning id into v_id;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_probation_reviews', v_id, auth.uid(), 'probation_review_recorded',
    jsonb_build_object('period_id', pp.id, 'recommendation', p_recommendation), public.payroll_employee_entity(pp.employee_id), pp.employee_id);
  return jsonb_build_object('ok', true, 'review_id', v_id);
end;
$$;

-- Decision: confirmed / extended (total ≤ 6 months from the first start) / not_confirmed.
-- not_confirmed never ends employment by itself: it opens an HR exception
-- (notice under Art. 9 is handled in the offboarding process).
create or replace function public.decide_probation_outcome(p_period_id uuid, p_outcome text, p_effective_date date,
  p_new_end_date date default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  pp public.employee_probation_periods;
  v_first date;
  v_new uuid;
  v_inst uuid;
  s public.onboarding_settings;
begin
  pp := public._onb_probation_scope(p_period_id, 'decide');
  select * into pp from public.employee_probation_periods where id = pp.id for update;
  if pp.status <> 'active' then raise exception 'This probation is already decided' using errcode = '22023'; end if;
  if p_outcome not in ('confirmed', 'extended', 'not_confirmed') then raise exception 'Unknown outcome' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null and p_outcome <> 'confirmed' then raise exception 'A reason is required' using errcode = '22023'; end if;
  if not exists (select 1 from public.employee_probation_reviews where probation_period_id = pp.id) then
    raise exception 'Record at least one probation review first' using errcode = '22023';
  end if;
  if public.my_role() <> 'owner' and not exists (select 1 from public.employee_probation_reviews
       where probation_period_id = pp.id and reviewer_id <> auth.uid()) then
    raise exception 'The decision needs a review from someone other than you' using errcode = '42501';
  end if;
  -- Earliest start in the chain of periods.
  with recursive chain as (
    select id, start_date, previous_period_id from public.employee_probation_periods where id = pp.id
    union all
    select p.id, p.start_date, p.previous_period_id from public.employee_probation_periods p join chain c on p.id = c.previous_period_id)
  select min(start_date) into v_first from chain;

  update public.employee_probation_periods set status = p_outcome, decided_by = auth.uid(), decided_at = now(),
         decision_effective_date = coalesce(p_effective_date, (now() at time zone 'Asia/Dubai')::date),
         decision_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now()
   where id = pp.id;

  if p_outcome = 'confirmed' then
    update public.employees set probation_end_date = least(coalesce(p_effective_date, pp.end_date), pp.end_date) where id = pp.employee_id;
  elsif p_outcome = 'extended' then
    if p_new_end_date is null or p_new_end_date <= pp.end_date then raise exception 'Give a later end date' using errcode = '22023'; end if;
    if p_new_end_date > (v_first + interval '6 months')::date - 1 then
      raise exception 'Probation cannot exceed six months in total (UAE Decree-Law 33/2021 Art. 9); latest end is %',
        (v_first + interval '6 months')::date - 1 using errcode = '22023';
    end if;
    select * into s from public.onboarding_settings where entity_id = public.payroll_employee_entity(pp.employee_id);
    insert into public.employee_probation_periods (employee_id, onboarding_instance_id, start_date, end_date, review_due_date, previous_period_id)
    values (pp.employee_id, pp.onboarding_instance_id, pp.end_date + 1, p_new_end_date,
            greatest(pp.end_date + 1, p_new_end_date - coalesce(s.probation_review_days_before, 14)), pp.id)
    returning id into v_new;
    update public.employees set probation_end_date = p_new_end_date where id = pp.employee_id;
  else
    select id into v_inst from public.onboarding_instances where employee_id = pp.employee_id order by created_at desc limit 1;
    if v_inst is not null then
      insert into public.onboarding_exceptions (instance_id, exception_type, description, owner_role, raised_by, due_date)
      values (v_inst, 'probation_not_confirmed', 'Probation not confirmed: ' || btrim(p_reason) || '. Start offboarding with the required notice.',
              'hr', auth.uid(), coalesce(p_effective_date, (now() at time zone 'Asia/Dubai')::date));
    end if;
  end if;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_probation_periods', pp.id, auth.uid(), 'probation_' || p_outcome,
    jsonb_build_object('effective_date', p_effective_date, 'new_end_date', p_new_end_date, 'new_period_id', v_new, 'reason', p_reason),
    public.payroll_employee_entity(pp.employee_id), pp.employee_id);
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'new_period_id', v_new);
end;
$$;

create or replace function public.list_probation_due(p_entity_id uuid, p_within_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_role public.user_role := public.my_role(); v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('period_id', pp.id, 'employee_id', e.id, 'full_name', e.full_name,
      'location', l.name, 'start_date', pp.start_date, 'end_date', pp.end_date, 'review_due_date', pp.review_due_date,
      'is_extension', pp.previous_period_id is not null,
      'reviews', (select count(*) from public.employee_probation_reviews r where r.probation_period_id = pp.id),
      'overdue', pp.review_due_date < v_today) order by pp.review_due_date)
    from public.employee_probation_periods pp join public.employees e on e.id = pp.employee_id
    left join public.locations l on l.id = e.home_location_id
   where e.entity_id = p_entity_id and pp.status = 'active' and e.employment_status = 'active'
     and pp.review_due_date <= v_today + p_within_days
     and (v_role <> 'location_manager' or e.home_location_id = public.my_location())), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------ reports
-- kind: funnel | ageing | blocked_reasons | starting_soon | overdue_tasks | invitations
--       | document_rejections | day_one | probation_due | time_to_activate
create or replace function public.onboarding_report(p_entity_id uuid, p_kind text, p_from date default null, p_to date default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_role public.user_role := public.my_role();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_from date := coalesce(p_from, v_today - 90);
  v_to date := coalesce(p_to, v_today);
  r jsonb;
begin
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  create temp table if not exists _onb_rep_scope (id uuid primary key) on commit drop;
  truncate _onb_rep_scope;
  insert into _onb_rep_scope select i.id from public.onboarding_instances i
   where i.entity_id = p_entity_id and (v_role <> 'location_manager' or i.home_location_id = public.my_location());

  if p_kind = 'funnel' then
    select jsonb_object_agg(status, n) into r from (select i.status, count(*) n from public.onboarding_instances i
      join _onb_rep_scope s on s.id = i.id where (i.started_at at time zone 'Asia/Dubai')::date between v_from and v_to group by i.status) x;
  elsif p_kind = 'ageing' then
    select jsonb_agg(jsonb_build_object('instance_id', i.id, 'employee', e.full_name, 'status', i.status,
             'days_open', v_today - (i.started_at at time zone 'Asia/Dubai')::date, 'days_in_status', v_today - (i.status_changed_at at time zone 'Asia/Dubai')::date)
             order by i.started_at) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id join public.employees e on e.id = i.employee_id
     where i.status not in ('completed', 'cancelled', 'withdrawn');
  elsif p_kind = 'blocked_reasons' then
    select jsonb_agg(jsonb_build_object('code', code, 'count', n) order by n desc) into r from (
      select b ->> 'code' code, count(*) n from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id
       cross join lateral jsonb_array_elements(public._onb_readiness(i.id, 'operations') -> 'blockers') b
       where i.status in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked') group by 1) x;
  elsif p_kind = 'starting_soon' then
    select jsonb_agg(jsonb_build_object('instance_id', i.id, 'employee', e.full_name, 'start_date', i.proposed_start_date, 'status', i.status,
             'blocking', (public._onb_readiness(i.id, 'operations') ->> 'blocking_count')::integer) order by i.proposed_start_date) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id join public.employees e on e.id = i.employee_id
     where i.status not in ('completed', 'cancelled', 'withdrawn') and i.proposed_start_date between v_today and v_today + 14;
  elsif p_kind = 'overdue_tasks' then
    select jsonb_agg(jsonb_build_object('task_id', t.id, 'instance_id', t.instance_id, 'employee', e.full_name, 'task', t.item_label,
             'owner_role', t.owner_role, 'due_date', t.due_date, 'days_overdue', v_today - t.due_date) order by t.due_date) into r
      from public.onboarding_tasks t join _onb_rep_scope s on s.id = t.instance_id join public.onboarding_instances i on i.id = t.instance_id
      join public.employees e on e.id = i.employee_id
     where t.status not in ('approved', 'waived', 'cancelled') and t.due_date < v_today and i.status not in ('completed', 'cancelled', 'withdrawn');
  elsif p_kind = 'invitations' then
    select jsonb_object_agg(status, n) into r from (select v.status, count(*) n from public.onboarding_invitations v
      join _onb_rep_scope s on s.id = v.instance_id where (v.issued_at at time zone 'Asia/Dubai')::date between v_from and v_to group by v.status) x;
  elsif p_kind = 'document_rejections' then
    select jsonb_agg(jsonb_build_object('doc_type', doc_type, 'rejected', n) order by n desc) into r from (
      select d.doc_type, count(*) n from public.employee_documents d join public.onboarding_instances i on i.employee_id = d.employee_id
        join _onb_rep_scope s on s.id = i.id
       where d.review_status = 'rejected' and (d.submitted_at at time zone 'Asia/Dubai')::date between v_from and v_to
         and (v_role <> 'location_manager' or not public.is_restricted_doc_type(d.doc_type))
       group by d.doc_type) x;
  elsif p_kind = 'day_one' then
    select jsonb_build_object('started', count(*) filter (where day_one_outcome = 'started'),
             'no_show', count(*) filter (where day_one_outcome = 'no_show'),
             'delayed', (select count(*) from public.onboarding_exceptions x join _onb_rep_scope s on s.id = x.instance_id where x.exception_type = 'delayed_start'),
             'not_recorded', count(*) filter (where status = 'activated' and actual_start_date < v_today)) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id
     where coalesce(i.actual_start_date, i.proposed_start_date) between v_from and v_to;
  elsif p_kind = 'probation_due' then
    r := public.list_probation_due(p_entity_id, 30);
  elsif p_kind = 'time_to_activate' then
    select jsonb_build_object('activated', count(*),
             'avg_days', round(avg(extract(epoch from (activated_at - started_at)) / 86400)::numeric, 1),
             'max_days', round(max(extract(epoch from (activated_at - started_at)) / 86400)::numeric, 1),
             'activated_after_start_date', count(*) filter (where (activated_at at time zone 'Asia/Dubai')::date > proposed_start_date)) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id
     where activated_at is not null and (activated_at at time zone 'Asia/Dubai')::date between v_from and v_to;
  else
    raise exception 'Unknown report %', p_kind using errcode = '22023';
  end if;
  return jsonb_build_object('kind', p_kind, 'from', v_from, 'to', v_to, 'data', coalesce(r, '[]'::jsonb));
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['_onb_advance_post_start(uuid)', 'trg_onb_task_post_start()', '_onb_probation_scope(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['record_day_one_outcome(uuid, text, date, text)', 'close_onboarding(uuid, text)',
    'record_probation_review(uuid, text, text, jsonb)', 'decide_probation_outcome(uuid, text, date, date, text)',
    'list_probation_due(uuid, integer)', 'onboarding_report(uuid, text, date, date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ===== migrations/008_onboarding_workflow_reminders.sql
-- =====================================================================
-- Migration 008 — workflow integration and reminders.
-- Adds the 'onboarding' module to the existing workflow engine (same
-- evaluate_workflow_rules path as leave/documents), a status-change
-- trigger, and a daily reminder job (system-only).
-- Depends on: 001–007, workflow_rules, evaluate_workflow_rules,
--             create_notification.
-- =====================================================================


alter table public.workflow_rules drop constraint if exists workflow_rules_module_check;
alter table public.workflow_rules add constraint workflow_rules_module_check
  check (module = any (array['leave', 'document', 'attendance', 'schedule', 'payroll', 'recruitment', 'onboarding']));

-- Same body as the live catalog (checked 27 Sep 2026) plus 'onboarding'.
create or replace function public.workflow_trigger_catalog()
returns jsonb language sql immutable set search_path to '' as $$
  select jsonb_build_object(
    'leave', jsonb_build_object(
      'leave_submitted', jsonb_build_array('employee_id', 'location_id', 'leave_type_id', 'days_requested')),
    'document', jsonb_build_object(
      'document_expiring_soon', jsonb_build_array('employee_id', 'location_id', 'document_id', 'doc_type', 'expiry_date', 'days_to_expiry'),
      'submitted_for_review', jsonb_build_array('employee_id', 'location_id', 'document_id', 'doc_type', 'is_renewal')),
    'attendance', jsonb_build_object(
      'late_clock_in', jsonb_build_array('employee_id', 'location_id', 'shift_id', 'attendance_id', 'late_minutes')),
    'schedule', jsonb_build_object(
      'schedule_published', jsonb_build_array('employee_id', 'location_id', 'shift_date'),
      'shift_adjusted', jsonb_build_array('employee_id', 'previous_employee_id', 'location_id', 'shift_date', 'change_type')),
    'payroll', jsonb_build_object(
      'payslip_published', jsonb_build_array('employee_id', 'payroll_run_id', 'period_start', 'period_end', 'is_revision')),
    'recruitment', jsonb_build_object(),
    'onboarding', jsonb_build_object(
      'onboarding_started', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'source', 'proposed_start_date'),
      'onboarding_section_submitted', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'section'),
      'onboarding_changes_required', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id'),
      'onboarding_ready_for_activation', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'proposed_start_date'),
      'employee_activated', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'join_date'),
      'onboarding_task_overdue', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'task_id', 'owner_role', 'days_overdue'),
      'probation_review_due', jsonb_build_array('employee_id', 'location_id', 'probation_period_id', 'review_due_date', 'days_to_due'))
  );
$$;

-- --------------------------------------------- status → workflow events
create or replace function public.trg_onb_workflow_status()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_event text;
begin
  v_event := case
    when tg_op = 'INSERT' then 'onboarding_started'
    when new.status = 'changes_required' and old.status <> 'changes_required' then 'onboarding_changes_required'
    when new.status = 'ready_for_activation' and old.status <> 'ready_for_activation' then 'onboarding_ready_for_activation'
    when new.status = 'activated' and old.status <> 'activated' then 'employee_activated'
    else null end;
  if v_event is null then return new; end if;
  begin
    perform public.evaluate_workflow_rules('onboarding', v_event, new.entity_id, 'onboarding_instances', new.id,
      jsonb_build_object('employee_id', new.employee_id, 'location_id', new.home_location_id, 'onboarding_instance_id', new.id,
                         'source', new.source, 'proposed_start_date', new.proposed_start_date,
                         'join_date', coalesce(new.actual_start_date, new.proposed_start_date)));
  exception when others then
    raise warning 'workflow % failed: %', v_event, sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists workflow_on_onboarding_status on public.onboarding_instances;
create trigger workflow_on_onboarding_status after insert or update of status on public.onboarding_instances
  for each row execute function public.trg_onb_workflow_status();

create or replace function public.trg_onb_workflow_section()
returns trigger language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances;
begin
  if new.status <> 'submitted' then return new; end if;
  select * into i from public.onboarding_instances where id = new.instance_id;
  begin
    perform public.evaluate_workflow_rules('onboarding', 'onboarding_section_submitted', i.entity_id, 'onboarding_section_submissions', new.id,
      jsonb_build_object('employee_id', i.employee_id, 'location_id', i.home_location_id, 'onboarding_instance_id', i.id, 'section', new.section));
  exception when others then
    raise warning 'workflow onboarding_section_submitted failed: %', sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists workflow_on_onboarding_section on public.onboarding_section_submissions;
create trigger workflow_on_onboarding_section after insert on public.onboarding_section_submissions
  for each row execute function public.trg_onb_workflow_section();

-- ----------------------------------------------------- daily reminders
-- One consolidated, deduped notification per person per day. Expires
-- stale invitations, escalates overdue items to HR after 2 days, raises
-- probation-review-due events. Run as the database owner (pg_cron).
create or replace function public.onboarding_send_reminders()
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_expired integer := 0;
  v_sent integer := 0;
  r record;
  x record;
begin
  -- Refuse API callers: only a session with no JWT (cron / SQL editor).
  if auth.uid() is not null or coalesce(current_setting('request.jwt.claims', true), '') not in ('', 'null') then
    raise exception 'System job only' using errcode = '42501';
  end if;

  update public.onboarding_invitations set status = 'expired' where status = 'issued' and expires_at < now();
  get diagnostics v_expired = row_count;

  -- Employees: one reminder listing what they still owe.
  for r in select i.id, i.entity_id, i.employee_id, count(*) n, min(t.due_date) first_due
             from public.onboarding_instances i join public.onboarding_tasks t on t.instance_id = i.id
            where i.status in ('initiated', 'awaiting_employee', 'changes_required') and t.owner_role = 'employee'
              and t.is_required and t.status in ('not_started', 'in_progress', 'changes_required')
            group by i.id loop
    perform public.create_notification(r.entity_id, null, r.employee_id, 'onboarding_reminder', 'Finish your onboarding',
      format('%s item(s) left%s.', r.n, case when r.first_due < v_today then ', some overdue' else '' end),
      'onboarding_instance', r.id, case when r.first_due < v_today then 'high' else 'normal' end,
      format('onb:%s:remind:employee:%s', r.id, v_today));
    v_sent := v_sent + 1;
  end loop;

  -- Branch managers and HR: overdue tasks they own; escalate to HR after 2 days.
  for r in select i.entity_id, i.home_location_id, t.owner_role, count(*) n, max(v_today - t.due_date) worst,
                  (array_agg(i.id order by t.due_date))[1] first_instance
             from public.onboarding_tasks t join public.onboarding_instances i on i.id = t.instance_id
            where t.status not in ('approved', 'waived', 'cancelled', 'submitted') and t.due_date < v_today
              and t.owner_role <> 'employee' and i.status not in ('completed', 'cancelled', 'withdrawn')
            group by 1, 2, 3 loop
    for x in select p.id from public.profiles p
              where p.is_active and ((r.owner_role = 'location_manager' and p.role = 'location_manager' and p.location_id = r.home_location_id)
                 or (p.role = 'entity_admin' and p.entity_id = r.entity_id
                     and (r.owner_role in ('hr', 'approver', 'payroll') or r.worst >= 2))) loop
      perform public.create_notification(r.entity_id, x.id, null, 'onboarding_task_overdue', 'Onboarding tasks overdue',
        format('%s overdue %s task(s), oldest %s day(s).', r.n, replace(r.owner_role, '_', ' '), r.worst),
        'onboarding_instance', r.first_instance, case when r.worst >= 2 then 'high' else 'normal' end,
        format('onb:overdue:%s:%s:%s:%s', r.home_location_id, r.owner_role, x.id, v_today));
      v_sent := v_sent + 1;
    end loop;
    begin
      perform public.evaluate_workflow_rules('onboarding', 'onboarding_task_overdue', r.entity_id, 'onboarding_instances', r.first_instance,
        jsonb_build_object('location_id', r.home_location_id, 'onboarding_instance_id', r.first_instance, 'owner_role', r.owner_role,
                           'days_overdue', r.worst));
    exception when others then raise warning 'workflow onboarding_task_overdue failed: %', sqlerrm;
    end;
  end loop;

  -- Probation reviews due (event only; rules decide who hears about it).
  for r in select pp.id, pp.employee_id, pp.review_due_date, e.entity_id, e.home_location_id
             from public.employee_probation_periods pp join public.employees e on e.id = pp.employee_id
            where pp.status = 'active' and e.employment_status = 'active'
              and pp.review_due_date in (v_today, v_today + 7) loop
    begin
      perform public.evaluate_workflow_rules('onboarding', 'probation_review_due', r.entity_id, 'employee_probation_periods', r.id,
        jsonb_build_object('employee_id', r.employee_id, 'location_id', r.home_location_id, 'probation_period_id', r.id,
                           'review_due_date', r.review_due_date, 'days_to_due', r.review_due_date - v_today));
    exception when others then raise warning 'workflow probation_review_due failed: %', sqlerrm;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'invitations_expired', v_expired, 'notifications', v_sent, 'run_at', now());
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['trg_onb_workflow_status()', 'trg_onb_workflow_section()', 'onboarding_send_reminders()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- ===== migrations/009_onboarding_rls_storage.sql
-- =====================================================================
-- Migration 009 — RLS and storage.
-- All writes go through the SECURITY DEFINER RPCs in 003–008, so only
-- SELECT policies are defined, and only SELECT is granted. Policies use
-- inline expressions (the _onb_* helpers are not executable by API roles).
--
-- Sensitive tables:
--   onboarding_pending_compensation  owner / entity admin / payroll approvers
--   employee_payment_details         payroll approvers + the employee (own)
-- Branch managers never see pay, bank details or restricted documents.
--
-- Storage: pre-boarding employees could not upload or read their own
-- documents (existing policies require employment_status = 'active').
-- Additive policies below allow exactly: upload to a path the server
-- staged for them, and read their own documents, while an onboarding
-- is open. Existing policies are not changed.
-- =====================================================================


-- Is the caller the pre-boarding employee of this employee id, with an
-- open onboarding? (Only answers about the caller themself.)
create or replace function public.onboarding_is_preboarding_self(p_employee_id uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select p_employee_id is not null and p_employee_id = public.my_employee_id()
     and exists (select 1 from public.onboarding_instances i where i.employee_id = p_employee_id
                  and i.status in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked',
                                   'ready_for_activation', 'activated', 'day_one', 'in_progress'));
$$;
revoke all on function public.onboarding_is_preboarding_self(uuid) from public, anon;
grant execute on function public.onboarding_is_preboarding_self(uuid) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['onboarding_settings', 'employee_numbering', 'onboarding_templates', 'onboarding_template_tasks',
    'onboarding_policies', 'onboarding_instances', 'onboarding_tasks', 'onboarding_task_dependencies',
    'onboarding_pending_compensation', 'employee_payment_details', 'onboarding_invitations', 'onboarding_section_submissions',
    'onboarding_reviews', 'onboarding_exceptions', 'employee_acknowledgements', 'employee_contract_acceptances',
    'employee_probation_periods', 'employee_probation_reviews'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- Shorthands used below (inline):
--   ADMIN(entity)  = owner, or entity admin of that entity
--   LM(location)   = location manager of that branch
--   PAYROLL(entity)= payroll_can(entity, 'approve')

-- ------------------------------------------------ company configuration
create policy onboarding_settings_select on public.onboarding_settings for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner'
         or ((select public.my_role()) in ('entity_admin', 'location_manager') and entity_id = (select public.my_entity()))));

create policy employee_numbering_select on public.employee_numbering for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner'
         or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))));

create policy onboarding_templates_select on public.onboarding_templates for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner'
         or ((select public.my_role()) in ('entity_admin', 'location_manager') and entity_id = (select public.my_entity()))));

create policy onboarding_template_tasks_select on public.onboarding_template_tasks for select to authenticated
  using (exists (select 1 from public.onboarding_templates t where t.id = template_id));  -- inherits the template policy

-- Policies are read by every employee of the company (they acknowledge them).
create policy onboarding_policies_select on public.onboarding_policies for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner' or entity_id = (select public.my_entity())
         or entity_id = (select e.entity_id from public.employees e where e.id = (select public.my_employee_id()))));

-- ------------------------------------------------------------- instances
create policy onboarding_instances_select on public.onboarding_instances for select to authenticated
  using ((select public.is_active_user()) and (
    (select public.my_role()) = 'owner'
    or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))
    or ((select public.my_role()) = 'location_manager' and home_location_id = (select public.my_location()))
    or public.payroll_can(entity_id, 'approve')
    or employee_id = (select public.my_employee_id())));

-- Child tables inherit the instance policy through the EXISTS subquery.
create policy onboarding_tasks_select on public.onboarding_tasks for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id)
         -- branch managers and the employee do not see payroll-section tasks' evidence
         and (section not in ('payroll') or exists (select 1 from public.onboarding_instances i where i.id = instance_id
              and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                   or public.payroll_can(i.entity_id, 'approve')))));

create policy onboarding_task_dependencies_select on public.onboarding_task_dependencies for select to authenticated
  using (exists (select 1 from public.onboarding_tasks t where t.id = task_id));

create policy onboarding_invitations_select on public.onboarding_invitations for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location())))));

create policy onboarding_section_submissions_select on public.onboarding_section_submissions for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or i.employee_id = (select public.my_employee_id())
                      or ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location())
                          and section not in ('payment', 'payroll', 'documents', 'employment')))));

create policy onboarding_reviews_select on public.onboarding_reviews for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or (section = 'payroll' and public.payroll_can(i.entity_id, 'approve'))
                      or (section not in ('payment', 'payroll', 'documents', 'employment')
                          and ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location())
                               or i.employee_id = (select public.my_employee_id()))))));

create policy onboarding_exceptions_select on public.onboarding_exceptions for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location()))
                      or (owner_role = 'payroll' and public.payroll_can(i.entity_id, 'approve')))));

-- ---------------------------------------------------------- sensitive
create policy onboarding_pending_compensation_select on public.onboarding_pending_compensation for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or public.payroll_can(i.entity_id, 'approve'))
                 and i.employee_id is distinct from (select public.my_employee_id())));

create policy employee_payment_details_select on public.employee_payment_details for select to authenticated
  using ((select public.is_active_user()) and (
    employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id and public.payroll_can(e.entity_id, 'approve')
               and e.id is distinct from (select public.my_employee_id()))));

-- ---------------------------------------- acknowledgements / contract / probation
create policy employee_acknowledgements_select on public.employee_acknowledgements for select to authenticated
  using ((select public.is_active_user()) and (employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id
               and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity()))
                    or ((select public.my_role()) = 'location_manager' and e.home_location_id = (select public.my_location())))))));

-- Contract acceptance follows the restricted 'contract' document: no branch managers.
create policy employee_contract_acceptances_select on public.employee_contract_acceptances for select to authenticated
  using ((select public.is_active_user()) and (employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id
               and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity())))))));

create policy employee_probation_periods_select on public.employee_probation_periods for select to authenticated
  using ((select public.is_active_user()) and (employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id
               and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity()))
                    or ((select public.my_role()) = 'location_manager' and e.home_location_id = (select public.my_location())))))));

-- Reviews are management-only (the employee sees the outcome, not the notes).
create policy employee_probation_reviews_select on public.employee_probation_reviews for select to authenticated
  using ((select public.is_active_user()) and exists (select 1 from public.employee_probation_periods pp
           join public.employees e on e.id = pp.employee_id
          where pp.id = probation_period_id and e.id is distinct from (select public.my_employee_id())
            and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity()))
                 or ((select public.my_role()) = 'location_manager' and e.home_location_id = (select public.my_location())))));

-- ------------------------------------------------ pre-boarding documents
-- Additive: the pre-boarding employee reads their own document rows.
create policy documents_select_preboarding_self on public.employee_documents for select to authenticated
  using (((upload_confirmed = true) or (submitted_by = (select auth.uid())))
         and public.onboarding_is_preboarding_self(employee_id));

-- Additive: upload only to a path stage_my_onboarding_document() created for them.
create policy doc_bucket_write_preboarding_self on storage.objects for insert to authenticated
  with check (bucket_id = 'employee-documents'
    and (select public.my_role()) = 'staff'
    and exists (select 1 from public.employee_documents d
                 where d.storage_path = name and d.submitted_by = (select auth.uid()) and not d.upload_confirmed
                   and public.onboarding_is_preboarding_self(d.employee_id)));

-- Additive: read own document files during onboarding.
create policy doc_bucket_read_preboarding_self on storage.objects for select to authenticated
  using (bucket_id = 'employee-documents'
    and exists (select 1 from public.employee_documents d
                 where d.storage_path = name and public.onboarding_is_preboarding_self(d.employee_id)));

-- ===== migrations/010_activation_guard.sql
-- =====================================================================
-- Migration 010 — activation guard (DEPLOY ONLY WITH THE ONBOARDING UI).
--
-- After this, pre_boarding → active is only possible through
-- approve_and_activate_employee(). The existing "Activate" button on the
-- employee profile (which calls set_employee_status directly) will then
-- fail for pre-boarding employees with a clear message. Deploy 010 when
-- the onboarding screens are live, not before.
--
-- Body = live set_employee_status (fetched 27 Sep 2026) + the guard block
-- marked "ONBOARDING GUARD". Nothing else changed.
-- =====================================================================


create or replace function public.set_employee_status(p_employee_id uuid, p_new_status public.employee_status, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  v_emp public.employees;
  v_reason text := nullif(btrim(p_reason), '');
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_allowed boolean;
  v_cancelled integer := 0;
  v_published_left integer := 0;
  v_profile public.profiles;
  v_profile_deactivated boolean := false;
  v_missing_docs text[];
begin
  if v_role is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_new_status is null then
    raise exception 'A new status is required' using errcode = '22023';
  end if;

  select * into v_emp from public.employees where id = p_employee_id for update;
  if v_emp.id is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = public.my_location())
  ) then
    raise exception 'Not authorized to change this employee''s status' using errcode = '42501';
  end if;

  if v_emp.id = public.my_employee_id() then
    raise exception 'You cannot change your own employment status' using errcode = '42501';
  end if;

  if v_emp.employment_status = p_new_status then
    raise exception 'Employee is already %', p_new_status using errcode = '22023';
  end if;

  v_allowed := case
    when v_emp.employment_status = 'candidate' and p_new_status in ('pre_boarding', 'inactive') then true
    when v_emp.employment_status = 'pre_boarding' and p_new_status in ('active', 'inactive') then true
    when v_emp.employment_status = 'active' and p_new_status = 'inactive' then true
    when v_emp.employment_status = 'inactive' and p_new_status = 'active' then true
    else false
  end;
  if not v_allowed then
    raise exception 'Status change % -> % is not allowed', v_emp.employment_status, p_new_status using errcode = '22023';
  end if;

  -- ONBOARDING GUARD: first activation only through approve_and_activate_employee(),
  -- which sets app.onboarding_activation to a ready instance of this employee.
  if v_emp.employment_status = 'pre_boarding' and p_new_status = 'active' then
    if not exists (
      select 1 from public.onboarding_instances oi
       where oi.employee_id = v_emp.id
         and oi.id::text = coalesce(current_setting('app.onboarding_activation', true), '')
         and oi.status = 'ready_for_activation'
    ) then
      raise exception 'Pre-boarding employees are activated from their onboarding (Approve and activate)'
        using errcode = '42501',
              hint = 'Open Onboarding, resolve the blocking items, then use Approve and activate.';
    end if;
  end if;
  -- END ONBOARDING GUARD

  if v_role = 'location_manager' and not (v_emp.employment_status = 'pre_boarding' and p_new_status = 'active') then
    raise exception 'Location managers can only activate pre-boarding employees' using errcode = '42501';
  end if;
  if v_emp.employment_status = 'inactive' and v_role not in ('owner', 'entity_admin') then
    raise exception 'Only an owner or entity admin can reactivate an employee' using errcode = '42501';
  end if;
  if (p_new_status = 'inactive' or v_emp.employment_status = 'inactive') and v_reason is null then
    raise exception 'A reason is required to inactivate or reactivate an employee' using errcode = '22023';
  end if;

  if p_new_status = 'active' then
    v_missing_docs := public.employee_missing_key_documents(p_employee_id);
    if cardinality(v_missing_docs) > 0 then
      raise exception 'Cannot activate: approved, unexpired key documents are missing (%)',
        array_to_string(v_missing_docs, ', ')
        using errcode = '22023',
              hint = 'Upload and approve the missing documents on the employee''s Documents tab, then activate.';
    end if;
  end if;

  if p_new_status = 'inactive' and v_emp.auth_user_id is not null then
    select * into v_profile from public.profiles where id = v_emp.auth_user_id for update;
    if v_profile.id is not null and v_profile.role = 'owner' and v_role <> 'owner' then
      raise exception 'Only an owner can inactivate an employee linked to an owner login' using errcode = '42501';
    end if;
  end if;

  update public.employees set employment_status = p_new_status, updated_at = now() where id = p_employee_id;

  if p_new_status = 'inactive' then
    -- Revoke the linked login (keeps the profile row for history).
    if v_profile.id is not null and v_profile.is_active then
      update public.profiles
         set is_active = false, deactivated_at = now(), deactivated_by = auth.uid(),
             deactivation_reason = 'Employee inactivated: ' || v_reason
       where id = v_profile.id;
      update public.access_grants
         set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
             revoke_reason = 'Employee inactivated: ' || v_reason, updated_at = now()
       where applied_user_id = v_profile.id and status = 'applied';
      v_profile_deactivated := true;
    end if;
    -- Pending grants for this employee can no longer be applied.
    update public.access_grants
       set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
           revoke_reason = 'Employee inactivated: ' || v_reason, updated_at = now()
     where employee_id = p_employee_id and status = 'pending';

    -- Cancel future draft (unpublished) shifts; published history and
    -- published future shifts are left for the manager to reassign.
    update public.shifts
       set status = 'cancelled'
     where employee_id = p_employee_id
       and shift_date > v_today
       and is_published = false
       and status <> 'cancelled';
    get diagnostics v_cancelled = row_count;

    select count(*) into v_published_left
      from public.shifts s
     where s.employee_id = p_employee_id and s.shift_date > v_today
       and s.is_published and s.status <> 'cancelled';
  end if;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('employees', p_employee_id, auth.uid(),
    case when p_new_status = 'inactive' then 'employee_deactivated'
         when v_emp.employment_status = 'inactive' then 'employee_reactivated'
         else 'employee_status_changed' end,
    jsonb_build_object('employment_status', v_emp.employment_status),
    jsonb_build_object('employment_status', p_new_status, 'reason', v_reason, 'actor_role', v_role,
                       'login_deactivated', v_profile_deactivated,
                       'draft_future_shifts_cancelled', v_cancelled,
                       'published_future_shifts_remaining', v_published_left),
    v_emp.entity_id, v_emp.home_location_id, p_employee_id);
end;
$function$;

-- ===== tests/onboarding_tests.sql
-- ============================================================
-- Smart Employee Onboarding — business workflow tests.
-- Creates a throw-away company, branch, managers and logins, runs the
-- whole lifecycle as each persona (PostgREST-style impersonation) and
-- ROLLS BACK. Nothing persists. Run as postgres AFTER migrations
-- 001–010 are applied (SQL editor / psql). The final statement raises
-- an exception whose message lists every result.
-- ============================================================

create temp table t_results(n serial, name text, pass boolean, detail text);
grant all on t_results to authenticated;
grant usage on sequence t_results_n_seq to authenticated;
create temp table t_ctx(k text primary key, v text);
grant all on t_ctx to authenticated;

create function pg_temp.login(p_sub uuid) returns void language plpgsql as $f$
begin
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
  set local role authenticated;
end $f$;
create function pg_temp.ok(p_name text, p_cond boolean, p_detail text default null) returns void language sql as $f$
  insert into t_results(name, pass, detail) values (p_name, coalesce(p_cond, false), p_detail);
$f$;
create function pg_temp.put(k text, v text) returns void language sql as $f$
  insert into t_ctx values (k, v) on conflict (k) do update set v = excluded.v;
$f$;
create function pg_temp.get(k text) returns text language sql security definer as $f$ select v from t_ctx where t_ctx.k = get.k; $f$;
-- Read-anything helpers for assertions (run as definer = postgres).
create function pg_temp.q_int(p_sql text) returns bigint language plpgsql security definer as $f$
declare r bigint; begin execute p_sql into r; return r; end $f$;
create function pg_temp.q_text(p_sql text) returns text language plpgsql security definer as $f$
declare r text; begin execute p_sql into r; return r; end $f$;

-- ---------------------------------------------------------------- fixtures
set local session_replication_role = replica;
insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'onb.owner@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000002', 'onb.admin@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000003', 'onb.admin3@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000004', 'onb.lm@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000005', 'onb.payroll@example.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000006', 'onb.other@example.test', 'authenticated', 'authenticated');
insert into public.entities (id, name, default_currency) values
  ('c2000000-0000-4000-8000-000000000001', 'ONB Test Cafe', 'AED'),
  ('c2000000-0000-4000-8000-000000000002', 'ONB Other Co', 'AED');
insert into public.locations (id, entity_id, name) values
  ('c3000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', 'ONB Branch 1'),
  ('c3000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000001', 'ONB Branch 2'),
  ('c3000000-0000-4000-8000-000000000003', 'c2000000-0000-4000-8000-000000000002', 'ONB Other Branch');
insert into public.profiles (id, full_name, role, entity_id, location_id, is_active) values
  ('c1000000-0000-4000-8000-000000000001', 'ONB Owner', 'owner', null, null, true),
  ('c1000000-0000-4000-8000-000000000002', 'ONB Admin', 'entity_admin', 'c2000000-0000-4000-8000-000000000001', null, true),
  ('c1000000-0000-4000-8000-000000000003', 'ONB Admin 3', 'entity_admin', 'c2000000-0000-4000-8000-000000000001', null, true),
  ('c1000000-0000-4000-8000-000000000004', 'ONB Branch Mgr', 'location_manager', 'c2000000-0000-4000-8000-000000000001',
   'c3000000-0000-4000-8000-000000000001', true),
  ('c1000000-0000-4000-8000-000000000005', 'ONB Payroll', 'staff', 'c2000000-0000-4000-8000-000000000001', null, true),
  ('c1000000-0000-4000-8000-000000000006', 'ONB Other Admin', 'entity_admin', 'c2000000-0000-4000-8000-000000000002', null, true);
insert into public.payroll_permissions (user_id, entity_id, preset) values
  ('c1000000-0000-4000-8000-000000000005', 'c2000000-0000-4000-8000-000000000001', 'payroll_admin');
insert into public.positions (id, entity_id, title, department) values
  ('c4000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', 'ONB Barista', 'Floor');
-- The reporting manager is an active employee linked to the LM login.
insert into public.employees (id, entity_id, home_location_id, position_id, auth_user_id, full_name, employment_status, join_date) values
  ('c5000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', 'c3000000-0000-4000-8000-000000000001',
   'c4000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000004', 'ONB Manager', 'active', '2024-01-01');
set local session_replication_role = origin;

-- ================================================================= tests
do $t$
declare
  v_owner uuid := 'c1000000-0000-4000-8000-000000000001';
  v_admin uuid := 'c1000000-0000-4000-8000-000000000002';
  v_admin3 uuid := 'c1000000-0000-4000-8000-000000000003';
  v_lm uuid := 'c1000000-0000-4000-8000-000000000004';
  v_pay uuid := 'c1000000-0000-4000-8000-000000000005';
  v_other uuid := 'c1000000-0000-4000-8000-000000000006';
  v_ent uuid := 'c2000000-0000-4000-8000-000000000001';
  v_l1 uuid := 'c3000000-0000-4000-8000-000000000001';
  v_pos uuid := 'c4000000-0000-4000-8000-000000000001';
  v_mgr uuid := 'c5000000-0000-4000-8000-000000000001';
  v_start date := (now() at time zone 'Asia/Dubai')::date + 10;
  j jsonb;
  v_inst uuid;
  v_emp uuid;
  v_task uuid;
  v_pd uuid;
  v_ver integer;
  v_pol record;
  v_period uuid;
begin
  -- ------------------------------------------------ A. setup and start
  perform pg_temp.login(v_admin);
  perform public.seed_default_onboarding_template(v_ent);
  perform pg_temp.ok('A1 default template seeded with 19 tasks',
    pg_temp.q_int(format('select count(*) from public.onboarding_template_tasks tt join public.onboarding_templates t on t.id = tt.template_id where t.entity_id = %L', v_ent)) = 19);

  j := public.start_onboarding_direct_hire(v_ent, 'ONB New Hire', 'onb.new@example.test', '+971 50 123 4567', 'female',
         v_l1, v_pos, 'full_time', v_start, v_mgr, 'Walk-in hire after trial shift');
  v_inst := (j ->> 'onboarding_instance_id')::uuid;
  v_emp := (j ->> 'employee_id')::uuid;
  perform pg_temp.put('inst', v_inst::text);
  perform pg_temp.put('emp', v_emp::text);
  perform pg_temp.ok('A2 direct hire creates pre-boarding employee + onboarding',
    pg_temp.q_text(format('select employment_status::text from public.employees where id = %L', v_emp)) = 'pre_boarding'
    and (j ->> 'task_count')::int = 13, j::text);
  perform pg_temp.ok('A3 employee number assigned',
    pg_temp.q_text(format('select employee_number from public.employees where id = %L', v_emp)) = 'EMP-0001');

  begin
    perform public.start_onboarding_direct_hire(v_ent, 'ONB Dup', 'ONB.NEW@example.test ', null, null, v_l1, v_pos, 'full_time',
      v_start, v_mgr, 'dup');
    perform pg_temp.ok('A4 duplicate email in same company refused', false);
  exception when others then
    perform pg_temp.ok('A4 duplicate email in same company refused', sqlstate = '23505', sqlerrm);
  end;

  begin
    perform public.update_onboarding_setup(v_inst, '{"proposed_start_date":"2030-01-01"}', 'x', -1);
    perform pg_temp.ok('A5 stale row_version refused', false);
  exception when others then
    perform pg_temp.ok('A5 stale row_version refused', sqlstate = '40001', sqlerrm);
  end;

  perform pg_temp.login(v_other);
  begin
    perform public.get_onboarding_workspace(v_inst);
    perform pg_temp.ok('A6 other company admin cannot open workspace', false);
  exception when others then
    perform pg_temp.ok('A6 other company admin cannot open workspace', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.ok('A7 other company admin sees no instance rows', (select count(*) from public.onboarding_instances) = 0);

  -- ------------------------------------------------ B. invitation and portal
  perform pg_temp.login(v_admin);
  j := public.issue_onboarding_invitation(v_inst);
  perform pg_temp.ok('B1 invitation issued, email to send', (j ->> 'send_email')::boolean, j::text);
  j := public.issue_onboarding_invitation(v_inst);
  perform pg_temp.ok('B2 issuing again is idempotent', (j ->> 'already_issued')::boolean, j::text);

  -- The new hire signs up (handle_new_user applies the pending grant).
  reset role;
  insert into auth.users (id, email, aud, role) values ('c1000000-0000-4000-8000-000000000009', 'onb.new@example.test', 'authenticated', 'authenticated');
  perform pg_temp.ok('B3 sign-up links login to the employee',
    pg_temp.q_text(format('select auth_user_id::text from public.employees where id = %L', v_emp)) = 'c1000000-0000-4000-8000-000000000009');

  perform pg_temp.login('c1000000-0000-4000-8000-000000000009');
  j := public.get_my_onboarding();
  perform pg_temp.ok('B4 employee portal loads', (j -> 'onboarding' ->> 'id')::uuid = v_inst, left(j::text, 300));
  perform pg_temp.ok('B5 portal has no pay data', j::text !~* 'basic_monthly|hourly_rate|proposed_salary');
  begin
    perform public.save_my_onboarding_profile('{"email":"x@y.z"}');
    perform pg_temp.ok('B6 employee cannot edit non-whitelisted fields', false);
  exception when others then
    perform pg_temp.ok('B6 employee cannot edit non-whitelisted fields', sqlstate = '22023', sqlerrm);
  end;
  perform public.save_my_onboarding_profile('{"phone":"+971501234567","dob":"1998-04-02","gender":"female","nationality":"Philippines",
    "residential_address":"Al Barsha, Dubai","emergency_contact_name":"Maria","emergency_contact_phone":"+639170000000"}');
  j := public.stage_my_onboarding_document('passport', 'pdf', (now() + interval '3 years')::date, null);
  perform pg_temp.ok('B7 pre-boarding employee can stage own document upload',
    j ->> 'storage_path' like v_ent::text || '/' || v_emp::text || '/%', j::text);
  begin
    perform public.stage_my_onboarding_document('contract', 'pdf', null, null);
    perform pg_temp.ok('B8 employee cannot upload the contract', false);
  exception when others then
    perform pg_temp.ok('B8 employee cannot upload the contract', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.ok('B9 pre-boarding employee reads own staged document row', (select count(*) from public.employee_documents) >= 1);

  select id into v_task from public.onboarding_tasks where instance_id = v_inst and item_key = 'operations_setup';
  begin
    perform public.complete_onboarding_task(v_task, null);
    perform pg_temp.ok('B10 employee cannot complete a branch-manager task', false);
  exception when others then
    perform pg_temp.ok('B10 employee cannot complete a branch-manager task', sqlstate = '42501', sqlerrm);
  end;
  begin
    perform public.save_my_payment_details('bank_transfer', 'ENBD', 'ONB New Hire', 'AE12 3456', null);
    perform pg_temp.ok('B11 malformed IBAN refused', false);
  exception when others then
    perform pg_temp.ok('B11 malformed IBAN refused', sqlstate = '22023', sqlerrm);
  end;
  perform public.save_my_payment_details('bank_transfer', 'ENBD', 'ONB New Hire', 'AE07 0331 2345 6789 0123 456', null);
  for v_pol in select p.id from public.onboarding_policies p where p.entity_id = v_ent and p.is_active loop
    perform public.acknowledge_onboarding_policy(v_pol.id);
  end loop;
  begin
    perform public.accept_employment_contract(v_inst);
    perform pg_temp.ok('B12 contract acceptance needs an approved contract', false);
  exception when others then
    perform pg_temp.ok('B12 contract acceptance needs an approved contract', sqlstate = '22023', sqlerrm);
  end;
  j := public.submit_onboarding_section(v_inst, 'profile');
  perform pg_temp.ok('B13 profile section submitted',
    pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and section = ''profile'' and status = ''submitted''', v_inst)) = 2);
  begin
    perform public.save_my_onboarding_profile('{"phone":"+971500000000"}');
    perform pg_temp.ok('B14 profile locked while under review', false);
  exception when others then
    perform pg_temp.ok('B14 profile locked while under review', sqlstate = '22023', sqlerrm);
  end;

  -- Key documents: approved passport/visa/Emirates ID and HR contract (fixture, as if reviewed).
  reset role;
  set local session_replication_role = replica;
  insert into public.employee_documents (employee_id, doc_type, storage_path, expiry_date, review_status, is_current, submitted_by, submitted_at,
    reviewed_by, reviewed_at, upload_confirmed, version_number)
  select v_emp, d::public.document_type, format('%s/%s/fixture-%s.pdf', v_ent, v_emp, d), (now() + interval '2 years')::date, 'approved', true,
         v_admin, now(), v_owner, now(), true, 1
    from unnest(array['passport', 'visa', 'emirates_id', 'contract']) d;
  set local session_replication_role = origin;

  perform pg_temp.login('c1000000-0000-4000-8000-000000000009');
  j := public.accept_employment_contract(v_inst);
  perform pg_temp.ok('B15 employee accepts the approved contract', (j ->> 'ok')::boolean and not (j ->> 'already_accepted')::boolean, j::text);
  j := public.accept_employment_contract(v_inst);
  perform pg_temp.ok('B16 contract acceptance is idempotent', (j ->> 'already_accepted')::boolean, j::text);
  perform pg_temp.ok('B17 employee sees own bank details only', (select count(*) from public.employee_payment_details) = 1);
  perform pg_temp.ok('B18 employee cannot read pending pay', (select count(*) from public.onboarding_pending_compensation) = 0);

  -- ------------------------------------------------ C. reviews, pay, bank
  perform pg_temp.login(v_admin);
  j := public.review_onboarding_section(v_inst, 'profile', 'changes_required', 'Emergency contact phone looks incomplete');
  perform pg_temp.ok('C1 HR requests changes with a reason',
    pg_temp.q_text(format('select status from public.onboarding_instances where id = %L', v_inst)) = 'changes_required');
  perform pg_temp.login('c1000000-0000-4000-8000-000000000009');
  perform public.save_my_onboarding_profile('{"emergency_contact_phone":"+639171234567"}');
  perform public.submit_onboarding_section(v_inst, 'profile');
  perform pg_temp.login(v_admin);
  perform public.review_onboarding_section(v_inst, 'profile', 'approved', null);
  perform pg_temp.ok('C2 resubmitted profile approved',
    pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and section = ''profile'' and status = ''approved''', v_inst)) = 2);

  j := public.set_onboarding_pending_compensation(v_inst, null, 'monthly', 4000, null, true, 'Starting pay', null);
  perform pg_temp.ok('C3 HR enters pay (pending review)', j ->> 'status' = 'pending_review', j::text);
  begin
    perform public.review_onboarding_compensation(v_inst, 'approved', null);
    perform pg_temp.ok('C4 pay maker cannot approve own entry', false);
  exception when others then
    perform pg_temp.ok('C4 pay maker cannot approve own entry', sqlstate = '42501', sqlerrm);
  end;

  perform pg_temp.login(v_lm);
  perform pg_temp.ok('C5 branch manager sees the onboarding', (select count(*) from public.onboarding_instances where id = v_inst) = 1);
  perform pg_temp.ok('C6 branch manager cannot read pay', (select count(*) from public.onboarding_pending_compensation) = 0);
  perform pg_temp.ok('C7 branch manager cannot read bank details', (select count(*) from public.employee_payment_details) = 0);
  j := public.get_onboarding_workspace(v_inst);
  perform pg_temp.ok('C8 branch manager workspace has no pay/bank', j -> 'compensation' = 'null'::jsonb or j -> 'compensation' is null,
    left((j -> 'compensation')::text, 100));
  select id into v_task from public.onboarding_tasks where instance_id = v_inst and item_key = 'operations_setup';
  j := public.complete_onboarding_task(v_task, '{"note":"Uniform size M ordered"}');
  perform pg_temp.ok('C9 branch manager completes operations task', j ->> 'status' = 'approved', j::text);

  perform pg_temp.login(v_pay);
  perform public.review_onboarding_compensation(v_inst, 'approved', null);
  select id into v_pd from public.employee_payment_details where employee_id = v_emp and status = 'submitted';
  perform public.verify_payment_details(v_pd, 'verified', null);
  perform pg_temp.ok('C10 payroll approves pay and verifies bank',
    pg_temp.q_text(format('select status from public.onboarding_pending_compensation where instance_id = %L', v_inst)) = 'approved'
    and pg_temp.q_text(format('select status from public.employee_payment_details where id = %L', v_pd)) = 'verified');

  perform pg_temp.login(v_admin);
  select id into v_task from public.onboarding_tasks where instance_id = v_inst and item_key = 'passport';
  begin
    perform public.waive_onboarding_task(v_task, 'n/a');
    perform pg_temp.ok('C11 statutory document cannot be waived', false);
  exception when others then
    perform pg_temp.ok('C11 statutory document cannot be waived', sqlstate = '22023', sqlerrm);
  end;
  j := public.calculate_onboarding_readiness(v_inst);
  perform pg_temp.ok('C12 readiness: ready for activation', (j ->> 'ready')::boolean
    and pg_temp.q_text(format('select status from public.onboarding_instances where id = %L', v_inst)) = 'ready_for_activation', j::text);
  j := public.onboarding_dashboard_summary(v_ent);
  perform pg_temp.ok('C13 dashboard summary counts ready', (j ->> 'ready_for_activation')::int = 1, j::text);

  -- ------------------------------------------------ D. activation
  begin
    perform public.set_employee_status(v_emp, 'active', 'raw');
    perform pg_temp.ok('D1 raw activation blocked (010 guard)', false);
  exception when others then
    perform pg_temp.ok('D1 raw activation blocked (010 guard)', sqlstate = '42501', sqlerrm);
  end;
  v_ver := pg_temp.q_int(format('select row_version from public.onboarding_instances where id = %L', v_inst));
  begin
    perform public.approve_and_activate_employee(v_inst, v_ver, 'Go');
    perform pg_temp.ok('D2 pay maker cannot also activate', false);
  exception when others then
    perform pg_temp.ok('D2 pay maker cannot also activate', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.login(v_admin3);
  begin
    perform public.approve_and_activate_employee(v_inst, v_ver - 1, 'Go');
    perform pg_temp.ok('D3 stale version refused at activation', false);
  exception when others then
    perform pg_temp.ok('D3 stale version refused at activation', sqlstate = '40001', sqlerrm);
  end;
  j := public.approve_and_activate_employee(v_inst, v_ver, 'All checks complete');
  perform pg_temp.ok('D4 second admin activates', (j ->> 'ok')::boolean and not (j ->> 'already_activated')::boolean, j::text);
  j := public.approve_and_activate_employee(v_inst, v_ver, 'retry');
  perform pg_temp.ok('D5 activation retry is idempotent', (j ->> 'already_activated')::boolean, j::text);
  perform pg_temp.ok('D6 employee active with join date',
    pg_temp.q_text(format('select employment_status::text || join_date::text from public.employees where id = %L', v_emp)) = 'active' || v_start::text);
  perform pg_temp.ok('D7 first compensation version created',
    pg_temp.q_int(format('select count(*) from public.compensation_versions where employee_id = %L and basic_monthly = 4000 and effective_from = %L', v_emp, v_start)) = 1);
  perform pg_temp.ok('D8 probation ≤ 6 months created',
    pg_temp.q_text(format('select end_date::text from public.employee_probation_periods where employee_id = %L and status = ''active''', v_emp))
      = ((v_start + interval '6 months')::date - 1)::text);
  perform pg_temp.ok('D9 day-one and first-month tasks generated',
    pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and phase <> ''pre_activation''', v_inst)) = 6);
  perform pg_temp.ok('D10 activation audited with operation id',
    pg_temp.q_int(format('select count(*) from public.audit_log where action = ''employee_activated'' and record_id = %L and new_value ? ''operation_id''', v_emp)) = 1);
  perform pg_temp.ok('D11 employee notified once',
    pg_temp.q_int(format('select count(*) from public.notifications where employee_id = %L and notification_type = ''onboarding_activated''', v_emp)) = 1);

  -- ------------------------------------------------ E. day one and probation
  perform pg_temp.login(v_lm);
  perform public.record_day_one_outcome(v_inst, 'started', null, null);
  for v_task in select id from public.onboarding_tasks where instance_id = v_inst and phase = 'day_one' and owner_role = 'location_manager' loop
    perform public.complete_onboarding_task(v_task, null);
  end loop;
  perform pg_temp.ok('E1 food safety SOP task completed from the earlier acknowledgement',
    pg_temp.q_text(format('select status from public.onboarding_tasks where instance_id = %L and item_key = ''food_safety_ack''', v_inst)) = 'approved');
  perform pg_temp.ok('E2 day one done → in progress',
    pg_temp.q_text(format('select status from public.onboarding_instances where id = %L', v_inst)) = 'in_progress',
    pg_temp.q_text(format('select string_agg(item_key || '':'' || status, '','') from public.onboarding_tasks where instance_id = %L and phase = ''day_one''', v_inst)));

  perform pg_temp.login(v_admin);
  begin
    perform public.close_onboarding(v_inst, null);
    perform pg_temp.ok('E3 cannot close with open follow-ups', false);
  exception when others then
    perform pg_temp.ok('E3 cannot close with open follow-ups', sqlstate = '22023', sqlerrm);
  end;

  select id into v_period from public.employee_probation_periods where employee_id = v_emp and status = 'active';
  perform pg_temp.login(v_lm);
  perform public.record_probation_review(v_period, 'confirm', 'Reliable, learns fast', '{"punctuality":5}');
  begin
    perform public.decide_probation_outcome(v_period, 'confirmed', null, null, null);
    perform pg_temp.ok('E4 branch manager cannot decide probation', false);
  exception when others then
    perform pg_temp.ok('E4 branch manager cannot decide probation', sqlstate = '42501', sqlerrm);
  end;
  perform pg_temp.login(v_admin);
  begin
    perform public.decide_probation_outcome(v_period, 'extended', null, (v_start + interval '7 months')::date, 'More time');
    perform pg_temp.ok('E5 extension beyond six months refused', false);
  exception when others then
    perform pg_temp.ok('E5 extension beyond six months refused', sqlstate = '22023', sqlerrm);
  end;
  j := public.onboarding_report(v_ent, 'time_to_activate');
  perform pg_temp.ok('E6 time-to-activate report', (j -> 'data' ->> 'activated')::int = 1, j::text);

  perform pg_temp.ok('E7 workflow catalog lists onboarding events', public.workflow_trigger_catalog() -> 'onboarding' ? 'employee_activated');
  begin
    perform public.onboarding_send_reminders();
    perform pg_temp.ok('E8 reminder job refuses API callers', false);
  exception when others then
    perform pg_temp.ok('E8 reminder job refuses API callers', sqlstate = '42501', sqlerrm);
  end;

  -- ------------------------------------------------ F. withdrawal path
  j := public.start_onboarding_direct_hire(v_ent, 'ONB Second Hire', 'onb.second@example.test', null, null, v_l1, v_pos, 'part_time',
         v_start, v_mgr, 'Referral');
  v_inst := (j ->> 'onboarding_instance_id')::uuid;
  perform public.withdraw_onboarding(v_inst, 'Accepted another job');
  perform pg_temp.ok('F1 withdrawal keeps record, inactivates, cancels tasks',
    pg_temp.q_text(format('select employment_status::text from public.employees where id = %L', (j ->> 'employee_id'))) = 'inactive'
    and pg_temp.q_int(format('select count(*) from public.onboarding_tasks where instance_id = %L and status <> ''cancelled''', v_inst)) = 0);
end $t$;

reset role;
do $$ begin
  raise exception 'ONBOARDING_TESTS % passed / % total || FAILED: % || ALL: %',
    (select count(*) from t_results where pass), (select count(*) from t_results),
    coalesce((select string_agg(name || ' [' || coalesce(detail, '') || ']', ' ;; ' order by n) from t_results where not pass), 'none'),
    (select string_agg(n || '.' || name, ' | ' order by n) from t_results);
end $$;
rollback;
