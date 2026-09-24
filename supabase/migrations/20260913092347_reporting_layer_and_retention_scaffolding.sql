
-- ============================================================
-- BR-RPT-001: consolidated owner dashboard KPIs (people, document
-- expiry, payroll, leave -- attendance already covered by
-- get_location_attendance_overview/get_attendance_exceptions).
-- ============================================================

create or replace function public.get_owner_dashboard_kpis(p_entity_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity uuid := coalesce(p_entity_id, my_entity());
  v_result jsonb;
begin
  if my_role() not in ('owner','entity_admin') then
    raise exception 'Not authorized to view owner dashboard KPIs';
  end if;
  if my_role() = 'entity_admin' and v_entity <> my_entity() then
    raise exception 'entity_admin can only view their own entity''s KPIs';
  end if;

  select jsonb_build_object(
    'entity_id', v_entity,
    'generated_at', now(),
    'headcount', (
      select jsonb_build_object(
        'candidate', count(*) filter (where employment_status = 'candidate'),
        'pre_boarding', count(*) filter (where employment_status = 'pre_boarding'),
        'active', count(*) filter (where employment_status = 'active'),
        'inactive', count(*) filter (where employment_status = 'inactive'),
        'total', count(*)
      )
      from employees where entity_id = v_entity
    ),
    'document_expiry', (
      select jsonb_build_object(
        'expired', count(*) filter (where expiry_date < current_date),
        'expiring_30_days', count(*) filter (where expiry_date >= current_date and expiry_date <= current_date + interval '30 days'),
        'ok', count(*) filter (where expiry_date is null or expiry_date > current_date + interval '30 days')
      )
      from employee_documents ed join employees e on e.id = ed.employee_id
      where e.entity_id = v_entity and ed.is_current = true
    ),
    'document_review_queue', (
      select count(*) from employee_documents ed join employees e on e.id = ed.employee_id
      where e.entity_id = v_entity and ed.review_status = 'pending_review'
    ),
    'leave', (
      select jsonb_build_object(
        'pending_requests', count(*) filter (where lr.status = 'pending'),
        'approved_this_month', count(*) filter (where lr.status = 'approved' and date_trunc('month', lr.decided_at) = date_trunc('month', now()))
      )
      from leave_requests lr join employees e on e.id = lr.employee_id
      where e.entity_id = v_entity
    ),
    'payroll', (
      select jsonb_build_object(
        'draft_runs', count(*) filter (where status = 'draft'),
        'in_review_runs', count(*) filter (where status = 'in_review'),
        'approved_unpaid_runs', count(*) filter (where status = 'approved'),
        'paid_runs', count(*) filter (where status = 'paid')
      )
      from payroll_runs where entity_id = v_entity
    ),
    'recruitment', (
      select jsonb_build_object(
        'open_requisitions', count(*) filter (where status = 'open'),
        'candidates_in_pipeline', (select count(*) from candidates where entity_id = v_entity and status not in ('hired','rejected','withdrawn'))
      )
      from job_requisitions where entity_id = v_entity
    ),
    'workflow', (
      select jsonb_build_object(
        'active_rules', count(*) filter (where is_active),
        'runs_last_7_days', (select count(*) from workflow_runs wr where wr.entity_id = v_entity and wr.ran_at > now() - interval '7 days')
      )
      from workflow_rules where entity_id = v_entity
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_owner_dashboard_kpis(uuid) is 'BR-RPT-001: single-call KPI bundle for the owner dashboard. This returns the underlying reconciled data (BR-RPT-004 export/PDF/XLSX rendering is a frontend concern this session cannot verify without the React codebase).';

-- Reconciliation helper for BR-RPT-001 acceptance ("report totals reconcile
-- to drill-down records"): row-level detail behind the document_expiry bucket
create or replace function public.get_document_expiry_detail(p_entity_id uuid default null, p_bucket text default 'expiring_30_days')
returns table (employee_id uuid, employee_name text, doc_type document_type, expiry_date date)
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity uuid := coalesce(p_entity_id, my_entity());
begin
  if my_role() not in ('owner','entity_admin') then
    raise exception 'Not authorized';
  end if;
  return query
    select e.id, e.full_name, ed.doc_type, ed.expiry_date
    from employee_documents ed
    join employees e on e.id = ed.employee_id
    where e.entity_id = v_entity and ed.is_current = true
      and case p_bucket
        when 'expired' then ed.expiry_date < current_date
        when 'expiring_30_days' then ed.expiry_date >= current_date and ed.expiry_date <= current_date + interval '30 days'
        else ed.expiry_date is null or ed.expiry_date > current_date + interval '30 days'
      end
    order by ed.expiry_date nulls last;
end;
$$;

-- ============================================================
-- NFR-DAT-002 / D09: data retention policy scaffolding.
-- Records the intended retention schedule per table with an explicit
-- approval gate -- mirrors the leave_accrual_policies is_approved
-- pattern. Deliberately does NOT perform any deletion: automating
-- disposal without a signed-off UAE-compliant schedule is exactly
-- what the BRD says not to do (D09, NFR-DAT-002).
-- ============================================================

create table public.data_retention_policies (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  table_name text not null,
  retention_years integer not null check (retention_years > 0),
  disposal_method text not null default 'manual_review' check (disposal_method in ('manual_review','soft_delete','hard_delete')),
  legal_basis text,
  is_approved boolean not null default false,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (entity_id, table_name)
);

comment on table public.data_retention_policies is 'NFR-DAT-002/D09: records the intended retention period per table. No automatic deletion job reads this table yet -- disposal_method defaults to manual_review until Legal/Owner approve a specific schedule and a disposal mechanism is explicitly built against it.';

alter table public.data_retention_policies enable row level security;

create policy data_retention_policies_select on public.data_retention_policies
  for select using (entity_id = my_entity() and my_role() in ('owner','entity_admin'));

create or replace function public.propose_data_retention_policy(
  p_table_name text, p_retention_years integer, p_disposal_method text, p_legal_basis text
) returns uuid
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity uuid := my_entity();
  v_id uuid;
begin
  if my_role() not in ('owner','entity_admin') then
    raise exception 'Only owner/entity_admin can propose a retention policy';
  end if;
  insert into data_retention_policies(entity_id, table_name, retention_years, disposal_method, legal_basis, created_by)
  values (v_entity, p_table_name, p_retention_years, p_disposal_method, p_legal_basis, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.approve_data_retention_policy(p_policy_id uuid) returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity uuid;
begin
  select entity_id into v_entity from data_retention_policies where id = p_policy_id;
  if v_entity is null or v_entity <> my_entity() or my_role() <> 'owner' then
    raise exception 'Only owner can approve a retention policy for their entity';
  end if;
  update data_retention_policies set is_approved = true, approved_by = auth.uid(), approved_at = now() where id = p_policy_id;
end;
$$;

-- Draft (unapproved) starting proposals for the two real entities, using
-- commonly-cited UAE norms (7 years for payroll/financial records is the
-- widely-referenced figure; confirm against final legal advice before approving).
insert into public.data_retention_policies (entity_id, table_name, retention_years, disposal_method, legal_basis, created_by)
select e.id, v.table_name, v.years, 'manual_review', v.basis, null
from public.entities e
cross join (values
  ('payroll_runs', 7, 'Commonly-cited UAE practice for financial/payroll records -- NOT yet confirmed against a specific legal opinion'),
  ('payslips', 7, 'Same as payroll_runs'),
  ('employee_documents', 7, 'Post-employment retention of identity/contract evidence -- confirm against UAE PDPL and MOHRE guidance'),
  ('audit_log', 7, 'Matches payroll/document retention for consistent evidentiary coverage'),
  ('attendance_records', 2, 'Working-time records -- placeholder pending legal confirmation')
) as v(table_name, years, basis)
where e.name in ('Third State Cafe', 'Ateej Tea Brew')
on conflict (entity_id, table_name) do nothing;

-- ============================================================
-- Phase 3 kickoff -- WPS export READINESS, not a finalized SIF file.
-- SIF field order and delimiter are bank/WPS-agent-specific and
-- sources conflict (comma vs. pipe-delimited depending on agent) --
-- generating a wrong byte-exact file risks real payroll rejection.
-- This builds the data-completeness layer only (BR-PAY-007 groundwork):
-- confirms every employee in a run has what a SIF requires, and adds
-- the establishment-level MOL/MOHRE ID entities will need.
-- ============================================================

alter table public.entities add column mohre_establishment_id text;
comment on column public.entities.mohre_establishment_id is 'MOHRE/MOL establishment (employer) ID, required as the SCR record''s employer identifier once WPS SIF export is built against a confirmed bank/agent spec.';

create or replace function public.get_wps_export_readiness(p_payroll_run_id uuid)
returns table (
  employee_id uuid,
  employee_name text,
  missing_labor_card_no boolean,
  missing_bank_iban boolean,
  missing_bank_name boolean,
  net_pay numeric
)
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity uuid;
begin
  select entity_id into v_entity from payroll_runs where id = p_payroll_run_id;
  if v_entity is null or not (my_role() = 'owner' or (my_role()='entity_admin' and v_entity = my_entity())) then
    raise exception 'Not authorized to view WPS readiness for this payroll run';
  end if;

  return query
    select e.id, e.full_name,
      (eid.labor_card_no is null or length(trim(eid.labor_card_no)) = 0),
      (eid.bank_iban is null or length(trim(eid.bank_iban)) = 0),
      (eid.bank_name is null or length(trim(eid.bank_name)) = 0),
      p.net_pay
    from payslips p
    join employees e on e.id = p.employee_id
    left join employee_identity_documents eid on eid.employee_id = e.id
    where p.payroll_run_id = p_payroll_run_id
    order by e.full_name;
end;
$$;

comment on function public.get_wps_export_readiness(uuid) is 'Phase 3 groundwork for BR-PAY-007. Flags missing IBAN/labor-card/bank-name data per employee in a payroll run. Does NOT generate a SIF file -- exact field order/delimiter must be confirmed with the specific bank/WPS agent (these vary) before a byte-format generator is built.';
