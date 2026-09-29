
-- stage_document_upload: record who actually performed the upload and whether it
-- was self-service or assisted (on someone else's behalf); keep the checklist row
-- in employee_document_requirements in sync.
create or replace function public.stage_document_upload(
  p_employee_id uuid, p_doc_type public.document_type, p_file_extension text,
  p_expiry_date date default null, p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_emp record;
  v_role public.user_role := public.my_role();
  v_sensitive boolean := public.is_restricted_doc_type(p_doc_type);
  v_new_id uuid := gen_random_uuid();
  v_path text;
  v_current_id uuid;
  v_method text;
begin
  if p_file_extension is null or lower(p_file_extension) not in ('pdf', 'jpg', 'jpeg', 'png') then
    raise exception 'Unsupported file type — only PDF, JPG and PNG are accepted';
  end if;

  select e.id, e.entity_id, e.home_location_id, e.employment_status into v_emp from employees e where e.id = p_employee_id;
  if v_emp.id is null then raise exception 'Employee % not found', p_employee_id; end if;
  if v_emp.employment_status = 'inactive' then raise exception 'Cannot upload documents for an inactive employee'; end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = my_location() and not v_sensitive)
    or p_employee_id = public.my_employee_id()
  ) then raise exception 'Not authorized to upload documents for this employee'; end if;

  v_method := case when p_employee_id = public.my_employee_id() then 'self' else 'assisted' end;

  select id into v_current_id from employee_documents where employee_id = p_employee_id and doc_type = p_doc_type and is_current = true;

  v_path := format('%s/%s/%s/1/%s.%s', v_emp.entity_id, p_employee_id, v_new_id, v_new_id, lower(p_file_extension));

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, version_number, supersedes_document_id, is_current, submitted_by, submitted_at, upload_confirmed,
    uploaded_by, upload_method
  ) values (
    v_new_id, p_employee_id, p_doc_type, v_path, p_expiry_date, p_notes,
    'pending_review', 1, v_current_id, false, auth.uid(), now(), false,
    auth.uid(), v_method
  );

  insert into employee_document_requirements (employee_id, doc_type, status, document_id, created_by)
  values (p_employee_id, p_doc_type, 'pending_review', v_new_id, auth.uid())
  on conflict (employee_id, doc_type) do update
    set status = 'pending_review', document_id = v_new_id, updated_at = now();

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'document_upload_staged',
    jsonb_build_object('employee_id', p_employee_id, 'doc_type', p_doc_type, 'supersedes', v_current_id, 'submitted_role', v_role, 'upload_method', v_method),
    v_emp.entity_id, v_emp.home_location_id, p_employee_id);

  return jsonb_build_object('id', v_new_id, 'storage_path', v_path, 'upload_method', v_method);
end;
$function$;

-- stage_document_renewal: same upload_method/requirement-sync treatment. Renewals
-- were already self-only (employee_id must equal my_employee_id()), so this is
-- always 'self' — kept explicit rather than assumed, in case that constraint is
-- relaxed later to let HR stage a renewal on someone's behalf too.
create or replace function public.stage_document_renewal(
  p_current_document_id uuid, p_file_extension text, p_expiry_date date default null, p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_current record;
  v_new_id uuid := gen_random_uuid();
  v_path text;
  v_method text;
begin
  if p_file_extension is null or lower(p_file_extension) not in ('pdf', 'jpg', 'jpeg', 'png') then
    raise exception 'Unsupported file type — only PDF, JPG and PNG are accepted';
  end if;

  select d.id, d.employee_id, d.doc_type, d.is_current, d.review_status, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_current
    from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_current_document_id;

  if v_current.id is null then raise exception 'Document % not found', p_current_document_id; end if;
  if v_current.employee_id <> my_employee_id() then raise exception 'You can only renew your own documents'; end if;
  if not public.is_active_employee(v_current.employee_id) then raise exception 'Inactive employees cannot submit documents'; end if;
  if v_current.is_current is not true or v_current.review_status <> 'approved' then
    raise exception 'Only the current approved document can be renewed';
  end if;

  v_method := 'self';
  v_path := format('%s/%s/%s/1/%s.%s', v_current.emp_entity_id, v_current.employee_id, v_new_id, v_new_id, lower(p_file_extension));

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, is_current, version_number, supersedes_document_id, submitted_by, submitted_at, upload_confirmed,
    uploaded_by, upload_method
  ) values (
    v_new_id, v_current.employee_id, v_current.doc_type, v_path, p_expiry_date, p_notes,
    'pending_review', false, 1, p_current_document_id, auth.uid(), now(), false,
    auth.uid(), v_method
  );

  insert into employee_document_requirements (employee_id, doc_type, status, document_id, created_by)
  values (v_current.employee_id, v_current.doc_type, 'pending_review', v_new_id, auth.uid())
  on conflict (employee_id, doc_type) do update
    set status = 'pending_review', document_id = v_new_id, updated_at = now();

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'renewal_staged',
    jsonb_build_object('employee_id', v_current.employee_id, 'doc_type', v_current.doc_type, 'supersedes', p_current_document_id),
    v_current.emp_entity_id, v_current.emp_home_location, v_current.employee_id);

  return jsonb_build_object('id', v_new_id, 'storage_path', v_path, 'upload_method', v_method);
end;
$function$;

-- confirm_document_upload: the existing instant-approve shortcut (owner uploads;
-- entity_admin uploads a non-sensitive type with self-approval enabled) must never
-- fire when the person confirming is the same person who uploaded it — that would
-- be exactly the self-review this whole change exists to close off. In the normal
-- flow the confirmer IS the uploader, so this shortcut now only ever fires when a
-- different authorised person confirms someone else's staged upload.
create or replace function public.confirm_document_upload(p_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_doc record;
  v_object_exists boolean;
  v_role user_role := my_role();
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if v_doc.upload_confirmed then
    return jsonb_build_object('ok', true, 'already_confirmed', true, 'review_status', v_doc.review_status);
  end if;

  if not (
    v_doc.submitted_by = auth.uid()
    or v_role = 'owner'
    or (v_role = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (v_role = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then raise exception 'Not authorized to confirm this upload'; end if;

  select exists (
    select 1 from storage.objects where bucket_id = 'employee-documents' and name = v_doc.storage_path
  ) into v_object_exists;

  if not v_object_exists then
    return jsonb_build_object('ok', false, 'code', 'UPLOAD_NOT_FOUND', 'message', 'No file was found at the expected storage location. Try uploading again.');
  end if;

  update employee_documents set upload_confirmed = true, upload_confirmed_at = now() where id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), 'document_upload_confirmed',
    jsonb_build_object('storage_path', v_doc.storage_path), v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);

  if v_doc.supersedes_document_id is null
    and v_doc.uploaded_by is distinct from auth.uid()
    and (
      v_role = 'owner'
      or (v_role = 'entity_admin' and not public.is_restricted_doc_type(v_doc.doc_type) and public.entity_admin_self_approval_enabled())
    ) then
    perform public.approve_document(p_document_id);
    return jsonb_build_object('ok', true, 'already_confirmed', false, 'review_status', 'approved');
  end if;

  return jsonb_build_object('ok', true, 'already_confirmed', false, 'review_status', 'pending_review');
end;
$function$;

-- approve_document / reject_document / archive_document: add the one rule this
-- whole change is about, on top of everything already enforced — whoever the
-- uploader was (self-service or assisted, any role) can never also be the reviewer.
create or replace function public.approve_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id for update of d;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if not v_doc.upload_confirmed then raise exception 'This document''s upload has not been confirmed yet'; end if;
  if v_doc.review_status <> 'pending_review' then raise exception 'Only a pending_review document can be approved'; end if;

  if v_doc.uploaded_by is not null and v_doc.uploaded_by = auth.uid() then
    raise exception 'Not authorized: whoever uploaded a document can never also approve it' using errcode = '42501';
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then raise exception 'Not authorized to review this document'; end if;

  if not public.can_review_document(v_doc.submitted_by, auth.uid(), v_doc.doc_type) then
    raise exception 'Not authorized to approve this submitter''s document under the approval matrix';
  end if;

  if v_doc.supersedes_document_id is not null then
    update employee_documents set review_status = 'superseded', is_current = false
      where id = v_doc.supersedes_document_id and is_current = true;
  end if;

  update employee_documents set review_status = 'approved', is_current = true,
      reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_document_id;

  update employee_document_requirements set status = 'approved', updated_at = now()
    where document_id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), 'document_approved',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'supersedes', v_doc.supersedes_document_id),
    v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);

  if v_doc.supersedes_document_id is not null then
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('employee_documents', v_doc.supersedes_document_id, auth.uid(), 'document_superseded',
      jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'superseded_by', p_document_id),
      v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);
  end if;

  perform public.create_notification(
    v_doc.emp_entity_id, null, v_doc.employee_id, 'document_approved',
    'Document approved',
    format('Your %s has been approved.', replace(v_doc.doc_type::text, '_', ' ')),
    'employee_documents', p_document_id, 'normal',
    'document_approved:' || p_document_id::text
  );
end;
$function$;

create or replace function public.reject_document(p_document_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_doc record;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'A rejection reason is required'; end if;

  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id for update of d;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if not v_doc.upload_confirmed then raise exception 'This document''s upload has not been confirmed yet'; end if;
  if v_doc.review_status <> 'pending_review' then raise exception 'Only a pending_review document can be rejected'; end if;

  if v_doc.uploaded_by is not null and v_doc.uploaded_by = auth.uid() then
    raise exception 'Not authorized: whoever uploaded a document can never also reject it' using errcode = '42501';
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then raise exception 'Not authorized to review this document'; end if;

  if not public.can_review_document(v_doc.submitted_by, auth.uid(), v_doc.doc_type) then
    raise exception 'Not authorized to reject this submitter''s document under the approval matrix';
  end if;

  update employee_documents set review_status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), rejection_reason = p_reason
    where id = p_document_id;

  update employee_document_requirements set status = 'rejected', updated_at = now()
    where document_id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), 'document_rejected',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'reason', p_reason),
    v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);

  perform public.create_notification(
    v_doc.emp_entity_id, null, v_doc.employee_id, 'document_rejected',
    'Document rejected',
    format('Your %s was rejected: %s', replace(v_doc.doc_type::text, '_', ' '), p_reason),
    'employee_documents', p_document_id, 'high',
    'document_rejected:' || p_document_id::text
  );
end;
$function$;

create or replace function public.archive_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id for update of d;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if v_doc.review_status = 'pending_review' then raise exception 'A pending submission must be rejected or removed, not archived'; end if;

  if v_doc.uploaded_by is not null and v_doc.uploaded_by = auth.uid() then
    raise exception 'Not authorized: whoever uploaded a document can never also archive it' using errcode = '42501';
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then raise exception 'Not authorized to archive this document'; end if;

  update employee_documents set review_status = 'archived', is_current = false,
      archived_by = auth.uid(), archived_at = now()
    where id = p_document_id;

  update employee_document_requirements set status = 'archived', updated_at = now()
    where document_id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), 'document_archived',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type),
    v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);
end;
$function$;

-- cleanup: when an unconfirmed staged upload is purged, put its requirement back
-- to Missing rather than leaving it pointed at a document row that no longer exists.
create or replace function public.cleanup_incomplete_document_uploads(p_older_than_hours integer default 24)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_row record;
  v_deleted int := 0;
begin
  if not (my_role() = 'owner' or my_role() = 'entity_admin') then
    raise exception 'Not authorized to run document upload cleanup';
  end if;

  for v_row in
    select d.id, d.storage_path, d.employee_id, d.doc_type, e.entity_id, e.home_location_id
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.upload_confirmed = false
      and d.created_at < now() - make_interval(hours => greatest(p_older_than_hours, 1))
      and (my_role() = 'owner' or e.entity_id = my_entity())
  loop
    update employee_document_requirements
      set status = 'missing', document_id = null, updated_at = now()
      where document_id = v_row.id;

    delete from employee_documents where id = v_row.id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('employee_documents', v_row.id, auth.uid(), 'document_upload_cleanup_removed',
      jsonb_build_object('storage_path', v_row.storage_path), v_row.entity_id, v_row.home_location_id, v_row.employee_id);

    v_deleted := v_deleted + 1;
  end loop;

  return v_deleted;
end;
$function$;

-- New: read the checklist (including Missing rows with no document yet).
create or replace function public.get_document_requirements_for_employee(p_employee_id uuid default null)
returns table (
  id uuid, employee_id uuid, doc_type public.document_type, status text, is_restricted boolean,
  document_id uuid, document_review_status text, document_expiry_date date,
  document_upload_method text, document_uploaded_by uuid,
  waived_reason text, waived_at timestamptz, created_at timestamptz, updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_target uuid := coalesce(p_employee_id, public.my_employee_id());
  v_role public.user_role := public.my_role();
  v_emp record;
begin
  if v_target is null then raise exception 'No employee specified and no linked employee for the caller'; end if;

  select e.id, e.entity_id, e.home_location_id into v_emp from public.employees e where e.id = v_target;
  if v_emp.id is null then raise exception 'Employee % not found', v_target; end if;

  if not (
    v_target = public.my_employee_id()
    or v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = public.my_location())
  ) then raise exception 'Not authorized to view document requirements for this employee'; end if;

  return query
  select r.id, r.employee_id, r.doc_type, r.status, public.is_restricted_doc_type(r.doc_type),
    r.document_id, d.review_status, d.expiry_date, d.upload_method, d.uploaded_by,
    r.waived_reason, r.waived_at, r.created_at, r.updated_at
  from public.employee_document_requirements r
  left join public.employee_documents d on d.id = r.document_id
  where r.employee_id = v_target
    and (
      v_target = public.my_employee_id()
      or v_role in ('owner', 'entity_admin')
      or (v_role = 'location_manager' and not public.is_restricted_doc_type(r.doc_type))
    )
  order by r.doc_type;
end;
$function$;

-- New: create/update the required-document checklist for an employee (used until
-- template-driven auto-seeding from the onboarding module is wired up).
create or replace function public.seed_document_requirements_for_employee(p_employee_id uuid, p_doc_types public.document_type[])
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_emp record;
  v_type public.document_type;
  v_count int := 0;
begin
  if not (my_role() = 'owner' or my_role() = 'entity_admin') then
    raise exception 'Not authorized to configure document requirements' using errcode = '42501';
  end if;

  select e.id, e.entity_id into v_emp from employees e where e.id = p_employee_id;
  if v_emp.id is null then raise exception 'Employee % not found', p_employee_id; end if;
  if my_role() = 'entity_admin' and v_emp.entity_id <> my_entity() then
    raise exception 'Not authorized for this employee''s entity' using errcode = '42501';
  end if;

  foreach v_type in array p_doc_types loop
    insert into employee_document_requirements (employee_id, doc_type, status, created_by)
    values (p_employee_id, v_type, 'missing', auth.uid())
    on conflict (employee_id, doc_type) do nothing;
    if found then v_count := v_count + 1; end if;
  end loop;

  return v_count;
end;
$function$;

-- New: explicit, reasoned exception to a requirement (e.g. genuinely not applicable).
create or replace function public.waive_document_requirement(p_requirement_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_req record;
  v_emp record;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'A reason is required to waive a document requirement'; end if;

  select r.*, e.entity_id as emp_entity_id into v_req
    from employee_document_requirements r join employees e on e.id = r.employee_id
    where r.id = p_requirement_id for update of r;

  if v_req.id is null then raise exception 'Requirement % not found', p_requirement_id; end if;
  if v_req.status = 'approved' then raise exception 'An already-approved requirement cannot be waived'; end if;

  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_req.emp_entity_id = my_entity())) then
    raise exception 'Not authorized to waive this document requirement' using errcode = '42501';
  end if;

  update employee_document_requirements
    set status = 'waived', waived_by = auth.uid(), waived_reason = p_reason, waived_at = now(), updated_at = now()
    where id = p_requirement_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_document_requirements', p_requirement_id, auth.uid(), 'document_requirement_waived',
    jsonb_build_object('employee_id', v_req.employee_id, 'doc_type', v_req.doc_type, 'reason', p_reason),
    v_req.emp_entity_id, v_req.employee_id);
end;
$function$;
;
