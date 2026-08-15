
-- Document-related audit writers: derive entity_id/location_id/employee_id from the
-- already-joined employee record (never a client-supplied value).

create or replace function public.approve_document(p_document_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id for update of d;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if v_doc.review_status <> 'pending_review' then raise exception 'Only a pending_review document can be approved'; end if;

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
end;
$$;

create or replace function public.archive_document(p_document_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id for update of d;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if v_doc.review_status = 'pending_review' then raise exception 'A pending submission must be rejected or removed, not archived'; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then raise exception 'Not authorized to archive this document'; end if;

  update employee_documents set review_status = 'archived', is_current = false,
      archived_by = auth.uid(), archived_at = now()
    where id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), 'document_archived',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type),
    v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);
end;
$$;

create or replace function public.create_document_upload(p_employee_id uuid, p_doc_type document_type, p_storage_path text, p_expiry_date date default null, p_notes text default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_emp record;
  v_role user_role := my_role();
  v_current_id uuid;
  v_new_id uuid := gen_random_uuid();
  v_sensitive boolean := public.is_restricted_doc_type(p_doc_type);
  v_immediate_approve boolean := false;
  v_final_status text;
begin
  select e.id, e.entity_id, e.home_location_id, e.employment_status into v_emp from employees e where e.id = p_employee_id;
  if v_emp.id is null then raise exception 'Employee % not found', p_employee_id; end if;
  if v_emp.employment_status <> 'active' then raise exception 'Cannot upload documents for an inactive employee'; end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = my_location() and not v_sensitive)
  ) then raise exception 'Not authorized to upload documents for this employee'; end if;

  select id into v_current_id from employee_documents where employee_id = p_employee_id and doc_type = p_doc_type and is_current = true;

  if v_role = 'owner' then v_immediate_approve := true;
  elsif v_role = 'entity_admin' and not v_sensitive and public.entity_admin_self_approval_enabled() then v_immediate_approve := true;
  end if;

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, version_number, supersedes_document_id, is_current, submitted_by, submitted_at
  ) values (
    v_new_id, p_employee_id, p_doc_type, p_storage_path, p_expiry_date, p_notes,
    'pending_review', 1, v_current_id, false, auth.uid(), now()
  );

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'document_uploaded',
    jsonb_build_object('employee_id', p_employee_id, 'doc_type', p_doc_type, 'supersedes', v_current_id, 'submitted_role', v_role),
    v_emp.entity_id, v_emp.home_location_id, p_employee_id);

  if v_immediate_approve then
    perform public.approve_document(v_new_id);
    v_final_status := 'approved';
  else
    v_final_status := 'pending_review';
  end if;

  return jsonb_build_object('id', v_new_id, 'review_status', v_final_status);
end;
$$;

create or replace function public.delete_pending_document(p_document_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id where d.id = p_document_id;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if v_doc.review_status <> 'pending_review' or v_doc.is_current is true then
    raise exception 'Only a pending, not-current submission can be removed this way';
  end if;

  if not (
    v_doc.submitted_by = auth.uid()
    or my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then raise exception 'Not authorized to remove this document'; end if;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), 'pending_upload_removed',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'storage_path', v_doc.storage_path),
    v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);

  delete from employee_documents where id = p_document_id;
end;
$$;

create or replace function public.log_document_access(p_document_id uuid, p_action text) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
  v_authorized boolean;
begin
  if p_action not in ('preview', 'download') then raise exception 'Invalid action %', p_action; end if;

  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id where d.id = p_document_id;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;

  v_authorized := (
    (v_doc.employee_id = my_employee_id() and public.is_active_employee(v_doc.employee_id))
    or my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  );

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
    values ('employee_documents', p_document_id, auth.uid(), 'unauthorized_access_attempt',
      jsonb_build_object('attempted_action', p_action), v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);
    raise exception 'Not authorized to access this document';
  end if;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), p_action,
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type),
    v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);
end;
$$;

create or replace function public.reject_document(p_document_id uuid, p_reason text) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'A rejection reason is required'; end if;

  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id for update of d;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if v_doc.review_status <> 'pending_review' then raise exception 'Only a pending_review document can be rejected'; end if;

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

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', p_document_id, auth.uid(), 'document_rejected',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'reason', p_reason),
    v_doc.emp_entity_id, v_doc.emp_home_location, v_doc.employee_id);
end;
$$;

create or replace function public.submit_document_renewal(p_current_document_id uuid, p_storage_path text, p_expiry_date date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_current record;
  v_new_id uuid;
begin
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

  insert into employee_documents (
    employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, is_current, version_number, supersedes_document_id, submitted_by, submitted_at
  ) values (
    v_current.employee_id, v_current.doc_type, p_storage_path, p_expiry_date, p_notes,
    'pending_review', false, 1, p_current_document_id, auth.uid(), now()
  ) returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'renewal_submitted',
    jsonb_build_object('employee_id', v_current.employee_id, 'doc_type', v_current.doc_type, 'supersedes', p_current_document_id),
    v_current.emp_entity_id, v_current.emp_home_location, v_current.employee_id);

  return v_new_id;
end;
$$;
