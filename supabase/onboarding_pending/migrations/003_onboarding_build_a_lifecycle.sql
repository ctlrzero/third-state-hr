-- =====================================================================
-- Migration 003 — Build A: lifecycle foundation.
-- Templates, numbering, settings, policies, the three entry paths
-- (accepted offer, direct hire, existing pre-boarding employee), setup
-- changes, cancel / withdraw, dashboard and workspace reads.
-- Depends on: 001, 002.
-- =====================================================================

begin;

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

commit;
