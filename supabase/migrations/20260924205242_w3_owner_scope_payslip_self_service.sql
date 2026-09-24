-- ============================================================
-- W3: owner-scope sweep, payslip self-service read model,
--     published-payslip immutability, completeness fix
-- ------------------------------------------------------------
-- Owner profiles have entity_id NULL, so anything keyed on
-- my_entity() silently returned nothing for the owner. Owner now
-- works across entities (explicit p_entity_id where the signature
-- has one, otherwise all entities). entity_admin / location_manager
-- stay scoped exactly as before.
--
-- Signature changes (additive):
--   propose_data_retention_policy(p_table_name, p_retention_years,
--     p_disposal_method, p_legal_basis, p_entity_id uuid default null)
--   (existing 4-arg named calls resolve unchanged)
-- New RPCs: get_my_payslips(), get_my_payslip(p_payslip_id)
-- ============================================================

-- ------------------------------------------------------------
-- 0. Maintenance bypass helper for payroll immutability triggers.
--    Only honoured for a direct postgres session (migrations, SQL
--    editor) that explicitly sets tshr.uat_maintenance = on. API
--    sessions always connect as "authenticator" and can never pass.
-- ------------------------------------------------------------
create or replace function public._maintenance_bypass()
returns boolean
language sql stable
set search_path = ''
as $$
  select session_user in ('postgres', 'supabase_admin')
     and coalesce(current_setting('tshr.uat_maintenance', true), '') = 'on';
$$;
revoke all on function public._maintenance_bypass() from public, anon, authenticated;

create or replace function public.enforce_payroll_child_immutability()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_run_id uuid;
  v_status text;
begin
  if public._maintenance_bypass() then
    return coalesce(new, old);
  end if;
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

-- Published (approved/paid) payslips are never overwritten or deleted.
-- Draft / in_review runs stay recalculable (run_payroll_calculation).
create or replace function public.enforce_published_payslip_immutability()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  if public._maintenance_bypass() then
    return coalesce(new, old);
  end if;
  select status into v_status from public.payroll_runs
   where id = coalesce(new.payroll_run_id, old.payroll_run_id);
  if v_status in ('approved', 'paid') then
    raise exception 'Payslips of a published (%) payroll run are immutable. Create a revision run for corrections.', v_status
      using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.payroll_run_id is distinct from old.payroll_run_id then
    select status into v_status from public.payroll_runs where id = old.payroll_run_id;
    if v_status in ('approved', 'paid') then
      raise exception 'Payslips cannot be moved out of a published payroll run' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_published_payslip_immutability() from public, anon, authenticated;

drop trigger if exists trg_payslips_published_immutability on public.payslips;
create trigger trg_payslips_published_immutability
before insert or update or delete on public.payslips
for each row execute function public.enforce_published_payslip_immutability();

-- ------------------------------------------------------------
-- 1. get_employee_completeness: text[] || 'literal' was parsed as an
--    array literal (22P02 for every employee). Use array_append.
-- ------------------------------------------------------------
create or replace function public.get_employee_completeness(p_employee_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_emp public.employees;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_missing text[] := array[]::text[];
  v_total integer := 8;
  d text;
begin
  select * into v_emp from public.employees where id = p_employee_id;
  if v_emp.id is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;
  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = public.my_location())
    or v_emp.id = public.my_employee_id()
  ) then
    raise exception 'Not authorized to view this employee' using errcode = '42501';
  end if;

  if v_emp.phone is null or v_emp.email is null then
    v_missing := array_append(v_missing, 'contact'::text);
  end if;
  if v_emp.emergency_contact_name is null or v_emp.emergency_contact_phone is null then
    v_missing := array_append(v_missing, 'emergency_contact'::text);
  end if;
  if v_emp.position_id is null then
    v_missing := array_append(v_missing, 'position'::text);
  end if;
  if v_emp.join_date is null then
    v_missing := array_append(v_missing, 'join_date'::text);
  end if;

  foreach d in array array['passport', 'visa', 'emirates_id', 'contract']::text[] loop
    if not exists (
      select 1 from public.employee_documents ed
      where ed.employee_id = p_employee_id
        and ed.doc_type = d::public.document_type
        and ed.is_current
        and ed.review_status = 'approved'
        and (ed.expiry_date is null or ed.expiry_date >= v_today)
    ) then
      v_missing := array_append(v_missing, d || '_document');
    end if;
  end loop;

  return jsonb_build_object(
    'percent', round(100.0 * (v_total - cardinality(v_missing)) / v_total)::integer,
    'missing', to_jsonb(v_missing),
    'total', v_total,
    'complete', v_total - cardinality(v_missing)
  );
end;
$$;
revoke all on function public.get_employee_completeness(uuid) from public, anon;
grant execute on function public.get_employee_completeness(uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. get_owner_dashboard_kpis: owner + NULL entity = group totals.
--    Same keys as before plus "scope" ('entity' | 'all_entities').
--    Dates use the Asia/Dubai business day.
-- ------------------------------------------------------------
create or replace function public.get_owner_dashboard_kpis(p_entity_id uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_entity uuid;
  v_all boolean := false;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_month_start timestamptz := (date_trunc('month', (now() at time zone 'Asia/Dubai'))) at time zone 'Asia/Dubai';
  v_result jsonb;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Not authorized to view owner dashboard KPIs' using errcode = '42501';
  end if;
  if v_role = 'entity_admin' then
    if p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
      raise exception 'entity_admin can only view their own entity''s KPIs' using errcode = '42501';
    end if;
    v_entity := public.my_entity();
  else
    v_entity := p_entity_id;
    v_all := p_entity_id is null;
  end if;

  select jsonb_build_object(
    'entity_id', v_entity,
    'scope', case when v_all then 'all_entities' else 'entity' end,
    'generated_at', now(),
    'headcount', (
      select jsonb_build_object(
        'candidate', count(*) filter (where e.employment_status = 'candidate'),
        'pre_boarding', count(*) filter (where e.employment_status = 'pre_boarding'),
        'active', count(*) filter (where e.employment_status = 'active'),
        'inactive', count(*) filter (where e.employment_status = 'inactive'),
        'total', count(*))
      from public.employees e where (v_all or e.entity_id = v_entity)
    ),
    'document_expiry', (
      select jsonb_build_object(
        'expired', count(*) filter (where ed.expiry_date < v_today),
        'expiring_30_days', count(*) filter (where ed.expiry_date >= v_today and ed.expiry_date <= v_today + 30),
        'ok', count(*) filter (where ed.expiry_date is null or ed.expiry_date > v_today + 30))
      from public.employee_documents ed join public.employees e on e.id = ed.employee_id
      where (v_all or e.entity_id = v_entity) and ed.is_current = true
    ),
    'document_review_queue', (
      select count(*) from public.employee_documents ed join public.employees e on e.id = ed.employee_id
      where (v_all or e.entity_id = v_entity) and ed.review_status = 'pending_review' and ed.upload_confirmed = true
    ),
    'leave', (
      select jsonb_build_object(
        'pending_requests', count(*) filter (where lr.status = 'pending'),
        'approved_this_month', count(*) filter (where lr.status = 'approved' and lr.decided_at >= v_month_start))
      from public.leave_requests lr join public.employees e on e.id = lr.employee_id
      where (v_all or e.entity_id = v_entity)
    ),
    'payroll', (
      select jsonb_build_object(
        'draft_runs', count(*) filter (where pr.status = 'draft'),
        'in_review_runs', count(*) filter (where pr.status = 'in_review'),
        'approved_unpaid_runs', count(*) filter (where pr.status = 'approved'),
        'paid_runs', count(*) filter (where pr.status = 'paid'))
      from public.payroll_runs pr where (v_all or pr.entity_id = v_entity)
    ),
    'recruitment', (
      select jsonb_build_object(
        'open_requisitions', count(*) filter (where jr.status = 'open'),
        'candidates_in_pipeline', (select count(*) from public.candidates c
                                    where (v_all or c.entity_id = v_entity)
                                      and c.status not in ('hired', 'rejected', 'withdrawn')))
      from public.job_requisitions jr where (v_all or jr.entity_id = v_entity)
    ),
    'workflow', (
      select jsonb_build_object(
        'active_rules', count(*) filter (where w.is_active),
        'runs_last_7_days', (select count(*) from public.workflow_runs wr
                              where (v_all or wr.entity_id = v_entity) and wr.ran_at > now() - interval '7 days'))
      from public.workflow_rules w where (v_all or w.entity_id = v_entity)
    )
  ) into v_result;

  return v_result;
end;
$$;
revoke all on function public.get_owner_dashboard_kpis(uuid) from public, anon;
grant execute on function public.get_owner_dashboard_kpis(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. get_document_expiry_detail: owner + NULL entity = all entities.
-- ------------------------------------------------------------
create or replace function public.get_document_expiry_detail(p_entity_id uuid default null, p_bucket text default 'expiring_30_days')
returns table(employee_id uuid, employee_name text, doc_type public.document_type, expiry_date date)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_entity uuid;
  v_all boolean := false;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if v_role = 'entity_admin' then
    if p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
      raise exception 'entity_admin can only view their own entity' using errcode = '42501';
    end if;
    v_entity := public.my_entity();
  else
    v_entity := p_entity_id;
    v_all := p_entity_id is null;
  end if;
  return query
    select e.id, e.full_name, ed.doc_type, ed.expiry_date
    from public.employee_documents ed
    join public.employees e on e.id = ed.employee_id
    where (v_all or e.entity_id = v_entity) and ed.is_current = true
      and case p_bucket
        when 'expired' then ed.expiry_date < v_today
        when 'expiring_30_days' then ed.expiry_date >= v_today and ed.expiry_date <= v_today + 30
        else ed.expiry_date is null or ed.expiry_date > v_today + 30
      end
    order by ed.expiry_date nulls last;
end;
$$;
revoke all on function public.get_document_expiry_detail(uuid, text) from public, anon;
grant execute on function public.get_document_expiry_detail(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 4. get_documents_for_review: owner + NULL = all entities;
--    entity_admin / location_manager + NULL = their own entity.
-- ------------------------------------------------------------
create or replace function public.get_documents_for_review(p_entity_id uuid)
returns table(id uuid, employee_id uuid, employee_name text, doc_type public.document_type, storage_path text,
              expiry_date date, notes text, review_status text, version_number integer, supersedes_document_id uuid,
              is_current boolean, submitted_by uuid, submitted_at timestamptz, reviewed_by uuid, reviewed_at timestamptz,
              rejection_reason text, archived_at timestamptz, archived_by uuid, created_at timestamptz,
              updated_at timestamptz, redacted boolean)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_entity uuid;
  v_all boolean := false;
  v_mgr_entity uuid;
begin
  if v_role = 'location_manager' then
    select l.entity_id into v_mgr_entity from public.locations l where l.id = public.my_location();
    if v_mgr_entity is null or (p_entity_id is not null and v_mgr_entity <> p_entity_id) then
      raise exception 'Not authorized to view documents for this entity';
    end if;
    v_entity := v_mgr_entity;
  elsif v_role = 'entity_admin' then
    if p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
      raise exception 'Not authorized to view documents for this entity';
    end if;
    v_entity := public.my_entity();
  elsif v_role = 'owner' then
    v_entity := p_entity_id;
    v_all := p_entity_id is null;
  else
    raise exception 'Not authorized to view documents for this entity';
  end if;

  return query
  select
    d.id, d.employee_id, e.full_name, d.doc_type,
    case when v_role = 'location_manager' and public.is_restricted_doc_type(d.doc_type) then null else d.storage_path end,
    d.expiry_date,
    case when v_role = 'location_manager' and public.is_restricted_doc_type(d.doc_type) then null else d.notes end,
    d.review_status, d.version_number, d.supersedes_document_id, d.is_current,
    d.submitted_by, d.submitted_at, d.reviewed_by, d.reviewed_at, d.rejection_reason,
    d.archived_at, d.archived_by, d.created_at, d.updated_at,
    (v_role = 'location_manager' and public.is_restricted_doc_type(d.doc_type)) as redacted
  from public.employee_documents d
  join public.employees e on e.id = d.employee_id
  where (v_all or e.entity_id = v_entity)
    and d.upload_confirmed = true
    and (v_role in ('owner', 'entity_admin') or e.home_location_id = public.my_location());
end;
$$;
revoke all on function public.get_documents_for_review(uuid) from public, anon;
grant execute on function public.get_documents_for_review(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5. Data retention: owner can propose for any entity (explicit
--    p_entity_id), approve is owner-only across entities; audited.
-- ------------------------------------------------------------
drop function if exists public.propose_data_retention_policy(text, integer, text, text);
create function public.propose_data_retention_policy(
  p_table_name text,
  p_retention_years integer,
  p_disposal_method text,
  p_legal_basis text,
  p_entity_id uuid default null
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_entity uuid;
  v_id uuid;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Only owner/entity_admin can propose a retention policy' using errcode = '42501';
  end if;
  if v_role = 'entity_admin' then
    if p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
      raise exception 'Entity admins can only propose policies for their own entity' using errcode = '42501';
    end if;
    v_entity := public.my_entity();
  else
    if p_entity_id is null then
      raise exception 'Owner must specify p_entity_id' using errcode = '22023';
    end if;
    v_entity := p_entity_id;
  end if;
  if not exists (select 1 from public.entities where id = v_entity) then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;

  insert into public.data_retention_policies(entity_id, table_name, retention_years, disposal_method, legal_basis, created_by)
  values (v_entity, p_table_name, p_retention_years, p_disposal_method, p_legal_basis, auth.uid())
  returning id into v_id;

  insert into public.audit_log(table_name, record_id, changed_by, action, new_value, entity_id)
  values ('data_retention_policies', v_id, auth.uid(), 'retention_policy_proposed',
          jsonb_build_object('table_name', p_table_name, 'retention_years', p_retention_years,
                             'disposal_method', p_disposal_method, 'actor_role', v_role), v_entity);
  return v_id;
end;
$$;
revoke all on function public.propose_data_retention_policy(text, integer, text, text, uuid) from public, anon;
grant execute on function public.propose_data_retention_policy(text, integer, text, text, uuid) to authenticated;

create or replace function public.approve_data_retention_policy(p_policy_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pol public.data_retention_policies;
begin
  if public.my_role() is distinct from 'owner'::public.user_role then
    raise exception 'Only the owner can approve a retention policy' using errcode = '42501';
  end if;
  select * into v_pol from public.data_retention_policies where id = p_policy_id for update;
  if v_pol.id is null then
    raise exception 'Retention policy not found' using errcode = 'P0002';
  end if;
  if v_pol.is_approved then
    raise exception 'Retention policy is already approved' using errcode = '22023';
  end if;
  update public.data_retention_policies
     set is_approved = true, approved_by = auth.uid(), approved_at = now()
   where id = p_policy_id;
  insert into public.audit_log(table_name, record_id, changed_by, action, old_value, new_value, entity_id)
  values ('data_retention_policies', p_policy_id, auth.uid(), 'retention_policy_approved',
          jsonb_build_object('is_approved', false),
          jsonb_build_object('is_approved', true, 'table_name', v_pol.table_name, 'retention_years', v_pol.retention_years),
          v_pol.entity_id);
end;
$$;
revoke all on function public.approve_data_retention_policy(uuid) from public, anon;
grant execute on function public.approve_data_retention_policy(uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. Payslip self-service read model.
--    There is no stored payslip PDF: staff previously read the raw
--    payslips row. These RPCs return the complete published payslip
--    (own records only, identity from auth.uid()) so the client can
--    render / print a PDF. Draft and in_review runs are never
--    returned. No bank or identity-document numbers are exposed.
-- ------------------------------------------------------------
create or replace function public._payroll_run_version(p_payroll_run_id uuid)
returns integer
language sql stable
set search_path = ''
as $$
  with recursive chain as (
    select pr.id, pr.revises_payroll_run_id, 1 as depth
      from public.payroll_runs pr where pr.id = p_payroll_run_id
    union all
    select pr.id, pr.revises_payroll_run_id, c.depth + 1
      from public.payroll_runs pr join chain c on pr.id = c.revises_payroll_run_id
     where c.depth < 50
  )
  select max(depth)::integer from chain;
$$;
revoke all on function public._payroll_run_version(uuid) from public, anon, authenticated;

create or replace function public.get_my_payslips()
returns table(
  payslip_id uuid,
  payroll_run_id uuid,
  period_start date,
  period_end date,
  run_status text,
  version integer,
  is_revision boolean,
  superseded boolean,
  published_at timestamptz,
  currency text,
  gross_pay numeric,
  total_deductions numeric,
  net_pay numeric
)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_emp uuid := public.my_employee_id();
begin
  if v_emp is null or not public.is_active_user() then
    return;
  end if;
  return query
  select ps.id, pr.id, pr.period_start, pr.period_end, pr.status,
         public._payroll_run_version(pr.id),
         pr.revises_payroll_run_id is not null,
         exists (select 1 from public.payroll_runs r2
                  where r2.revises_payroll_run_id = pr.id and r2.status in ('approved', 'paid')),
         pr.approved_at,
         coalesce(en.default_currency, 'AED'),
         coalesce(ps.base_pay, 0) + coalesce(ps.overtime_pay, 0) + coalesce(ps.holiday_pay, 0) + coalesce(ps.tips_share, 0),
         coalesce(ps.total_deductions, 0),
         ps.net_pay
  from public.payslips ps
  join public.payroll_runs pr on pr.id = ps.payroll_run_id
  join public.entities en on en.id = pr.entity_id
  where ps.employee_id = v_emp
    and pr.status in ('approved', 'paid')
  order by pr.period_start desc, public._payroll_run_version(pr.id) desc;
end;
$$;
revoke all on function public.get_my_payslips() from public, anon;
grant execute on function public.get_my_payslips() to authenticated;

create or replace function public.get_my_payslip(p_payslip_id uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_emp uuid := public.my_employee_id();
  v_ps public.payslips;
  v_run public.payroll_runs;
  v_result jsonb;
begin
  if v_emp is null or not public.is_active_user() then
    raise exception 'No employee record is linked to your account' using errcode = '42501';
  end if;
  select * into v_ps from public.payslips where id = p_payslip_id;
  select * into v_run from public.payroll_runs where id = v_ps.payroll_run_id;
  -- Same error for "not found", "not yours" and "not published": no probing.
  if v_ps.id is null or v_ps.employee_id is distinct from v_emp or v_run.status not in ('approved', 'paid') then
    raise exception 'Payslip not found' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'payslip_id', v_ps.id,
    'payroll_run_id', v_run.id,
    'version', public._payroll_run_version(v_run.id),
    'is_revision', v_run.revises_payroll_run_id is not null,
    'revises_payroll_run_id', v_run.revises_payroll_run_id,
    'superseded', exists (select 1 from public.payroll_runs r2
                           where r2.revises_payroll_run_id = v_run.id and r2.status in ('approved', 'paid')),
    'run_status', v_run.status,
    'period_start', v_run.period_start,
    'period_end', v_run.period_end,
    'published_at', v_run.approved_at,
    'generated_at', v_ps.generated_at,
    'currency', coalesce(en.default_currency, 'AED'),
    'employer', jsonb_build_object(
      'entity_id', en.id, 'name', en.name, 'trade_license_no', en.trade_license_no, 'emirate', en.emirate),
    'employee', jsonb_build_object(
      'employee_id', e.id, 'full_name', e.full_name, 'preferred_name', e.preferred_name,
      'position_title', pos.title, 'location_name', loc.name,
      'employment_type', e.employment_type, 'join_date', e.join_date),
    'salary', jsonb_build_object(
      'pay_type', c.pay_type, 'pay_rate', c.pay_rate,
      'overtime_multiplier', c.overtime_multiplier, 'holiday_multiplier', c.holiday_multiplier,
      'regular_hours', coalesce(t.regular_hours, 0), 'overtime_hours', coalesce(t.overtime_hours, 0),
      'holiday_hours', coalesce(t.holiday_hours, 0)),
    'earnings', jsonb_build_array(
      jsonb_build_object('code', 'base', 'label', 'Basic pay', 'amount', coalesce(v_ps.base_pay, 0)),
      jsonb_build_object('code', 'overtime', 'label', 'Overtime', 'amount', coalesce(v_ps.overtime_pay, 0)),
      jsonb_build_object('code', 'holiday', 'label', 'Public holiday pay', 'amount', coalesce(v_ps.holiday_pay, 0)),
      jsonb_build_object('code', 'tips', 'label', 'Tips share', 'amount', coalesce(v_ps.tips_share, 0))),
    'allowances', '[]'::jsonb,
    'deductions', coalesce((
      select jsonb_agg(jsonb_build_object('type', d.deduction_type, 'amount', d.amount, 'notes', d.notes)
                       order by d.created_at)
        from public.payslip_deductions d
       where d.payroll_run_id = v_run.id and d.employee_id = v_emp), '[]'::jsonb),
    'gross_pay', coalesce(v_ps.base_pay, 0) + coalesce(v_ps.overtime_pay, 0) + coalesce(v_ps.holiday_pay, 0) + coalesce(v_ps.tips_share, 0),
    'total_deductions', coalesce(v_ps.total_deductions, 0),
    'net_pay', v_ps.net_pay
  ) into v_result
  from public.employees e
  join public.entities en on en.id = v_run.entity_id
  left join public.positions pos on pos.id = e.position_id
  left join public.locations loc on loc.id = e.home_location_id
  left join public.employee_compensation c on c.employee_id = e.id
  left join public.timesheet_entries t on t.payroll_run_id = v_run.id and t.employee_id = e.id
  where e.id = v_emp;

  insert into public.audit_log(table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  select 'payslips', v_ps.id, auth.uid(), 'payslip_viewed',
         jsonb_build_object('payroll_run_id', v_run.id), v_run.entity_id, e.home_location_id, v_emp
    from public.employees e where e.id = v_emp;

  return v_result;
end;
$$;
revoke all on function public.get_my_payslip(uuid) from public, anon;
grant execute on function public.get_my_payslip(uuid) to authenticated;
