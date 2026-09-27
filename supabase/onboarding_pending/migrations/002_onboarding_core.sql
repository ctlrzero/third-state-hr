-- =====================================================================
-- Migration 002: shared core — scope checks, audit, state machine,
-- task generation, derived task status and the readiness engine.
-- All internal helpers (_onb_*) are revoked from API roles; only the
-- public RPCs in 003–007 call them.
-- Depends on: 001, payroll v2 (payroll_can), employee_missing_key_documents.
-- =====================================================================

begin;

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
    when p_to = 'withdrawn' then p_from in ('initiated', 'awaiting_employee', 'under_review',
                                           'changes_required', 'blocked', 'ready_for_activation')
    -- After start, only offboarding cancels an onboarding (employment ended before closure).
    when p_to = 'cancelled' then p_from not in ('completed', 'cancelled', 'withdrawn')
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
             and kind in ('document', 'acknowledgement', 'contract_acceptance', 'payment_details', 'compensation', 'availability')
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
    elsif t.kind = 'availability' then
      v_new := case when e.availability_confirmed_at is not null then 'approved' else 'not_started' end;
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

-- Extension point for readiness: later migrations replace this function to
-- add their own blockers/warnings without redefining the engine below.
create or replace function public._onb_extension_checks(p_instance_id uuid, p_audience text)
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('blockers', '[]'::jsonb, 'warnings', '[]'::jsonb);
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

  -- Checks added by later modules (work permit / visa tracking in 012).
  declare v_ext jsonb := public._onb_extension_checks(p_instance_id, p_audience);
  begin
    b := b || coalesce(v_ext -> 'blockers', '[]'::jsonb);
    w := w || coalesce(v_ext -> 'warnings', '[]'::jsonb);
  end;

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
    '_onb_generate_tasks(uuid, text)', '_onb_sync_derived(uuid)', '_onb_readiness(uuid, text)', '_onb_recompute(uuid)',
    '_onb_extension_checks(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

commit;
