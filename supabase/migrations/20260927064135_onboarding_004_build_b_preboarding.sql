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
    perform public._onb_sync_derived(i.id);
    perform public._onb_recompute(i.id);
  end if;
  return jsonb_build_object('ok', true, 'already', v_id is null);
end;
$$;

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
end $$;;
