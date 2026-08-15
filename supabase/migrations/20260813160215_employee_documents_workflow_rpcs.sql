
-- submit_document_renewal: the only sanctioned path for an employee to
-- renew one of their own documents. Computes version linkage server-side;
-- the client only supplies the new file's storage path and metadata.
create or replace function public.submit_document_renewal(
  p_current_document_id uuid,
  p_storage_path text,
  p_expiry_date date default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_current record;
  v_new_id uuid;
begin
  select id, employee_id, doc_type, is_current, review_status
    into v_current
    from employee_documents
    where id = p_current_document_id;

  if v_current.id is null then
    raise exception 'Document % not found', p_current_document_id;
  end if;

  if v_current.employee_id <> my_employee_id() then
    raise exception 'You can only renew your own documents';
  end if;

  if not public.is_active_employee(v_current.employee_id) then
    raise exception 'Inactive employees cannot submit documents';
  end if;

  if v_current.is_current is not true or v_current.review_status <> 'approved' then
    raise exception 'Only the current approved document can be renewed';
  end if;

  insert into employee_documents (
    employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, is_current, version_number, supersedes_document_id,
    submitted_by, submitted_at
  ) values (
    v_current.employee_id, v_current.doc_type, p_storage_path, p_expiry_date, p_notes,
    'pending_review', false, 1, p_current_document_id,
    auth.uid(), now()
  )
  returning id into v_new_id;
  -- version_number above is a placeholder; the insert trigger recomputes it
  -- from supersedes_document_id, so the literal 1 never actually lands.

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('employee_documents', v_new_id, auth.uid(), 'renewal_submitted',
    jsonb_build_object('employee_id', v_current.employee_id, 'doc_type', v_current.doc_type, 'supersedes', p_current_document_id));

  return v_new_id;
end;
$$;

-- approve_document: atomically promotes a pending renewal to current and
-- retires the previous current version to 'superseded'. Also used to
-- approve a manager-submitted first-time upload that was left pending.
create or replace function public.approve_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
  v_home_location uuid;
  v_entity_id uuid;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.id = p_document_id
    for update of d;

  if v_doc.id is null then
    raise exception 'Document % not found', p_document_id;
  end if;

  if v_doc.review_status <> 'pending_review' then
    raise exception 'Only a pending_review document can be approved';
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location()
        and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then
    raise exception 'Not authorized to review this document';
  end if;

  if v_doc.submitted_by = auth.uid() then
    raise exception 'Self-approval is not permitted';
  end if;

  -- Flip the old current version to superseded BEFORE the new one becomes
  -- current, so the one-current-per-employee/doc_type index never sees two
  -- current rows at once (see index comment: not deferrable).
  if v_doc.supersedes_document_id is not null then
    update employee_documents
      set review_status = 'superseded', is_current = false
      where id = v_doc.supersedes_document_id and is_current = true;
  end if;

  update employee_documents
    set review_status = 'approved', is_current = true,
        reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('employee_documents', p_document_id, auth.uid(), 'document_approved',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'supersedes', v_doc.supersedes_document_id));

  if v_doc.supersedes_document_id is not null then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('employee_documents', v_doc.supersedes_document_id, auth.uid(), 'document_superseded',
      jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'superseded_by', p_document_id));
  end if;
end;
$$;

-- reject_document: requires a reason, never touches the still-current
-- approved version, and leaves the employee free to resubmit.
create or replace function public.reject_document(p_document_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A rejection reason is required';
  end if;

  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.id = p_document_id
    for update of d;

  if v_doc.id is null then
    raise exception 'Document % not found', p_document_id;
  end if;

  if v_doc.review_status <> 'pending_review' then
    raise exception 'Only a pending_review document can be rejected';
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location()
        and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then
    raise exception 'Not authorized to review this document';
  end if;

  if v_doc.submitted_by = auth.uid() then
    raise exception 'Self-review is not permitted';
  end if;

  update employee_documents
    set review_status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
        rejection_reason = p_reason
    where id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('employee_documents', p_document_id, auth.uid(), 'document_rejected',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'reason', p_reason));
end;
$$;

-- archive_document: the sanctioned replacement for hard-delete on any
-- approved/rejected/superseded document. Never available for pending_review.
create or replace function public.archive_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.id = p_document_id
    for update of d;

  if v_doc.id is null then
    raise exception 'Document % not found', p_document_id;
  end if;

  if v_doc.review_status = 'pending_review' then
    raise exception 'A pending submission must be rejected or removed, not archived';
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location()
        and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then
    raise exception 'Not authorized to archive this document';
  end if;

  update employee_documents
    set review_status = 'archived', is_current = false,
        archived_by = auth.uid(), archived_at = now()
    where id = p_document_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('employee_documents', p_document_id, auth.uid(), 'document_archived',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type));
end;
$$;

-- delete_pending_document: the only remaining hard-delete path, restricted
-- by RLS to pending_review + not-current rows. Wrapped in an RPC purely so
-- the removal is audited.
create or replace function public.delete_pending_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.id = p_document_id;

  if v_doc.id is null then
    raise exception 'Document % not found', p_document_id;
  end if;

  if v_doc.review_status <> 'pending_review' or v_doc.is_current is true then
    raise exception 'Only a pending, not-current submission can be removed this way';
  end if;

  if not (
    v_doc.submitted_by = auth.uid()
    or my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location()
        and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then
    raise exception 'Not authorized to remove this document';
  end if;

  insert into audit_log (table_name, record_id, changed_by, action, old_value)
  values ('employee_documents', p_document_id, auth.uid(), 'pending_upload_removed',
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'storage_path', v_doc.storage_path));

  delete from employee_documents where id = p_document_id;
end;
$$;

-- log_document_access: called by the client after a successful preview or
-- download (the file itself is fetched via a short-lived signed URL, not
-- through this function). Re-derives authorisation independently of RLS so
-- an attempt against a document outside the caller's scope is both denied
-- and recorded, instead of just silently returning no rows the way a
-- plain SELECT would.
create or replace function public.log_document_access(p_document_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_doc record;
  v_authorized boolean;
begin
  if p_action not in ('preview', 'download') then
    raise exception 'Invalid action %', p_action;
  end if;

  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.id = p_document_id;

  if v_doc.id is null then
    raise exception 'Document % not found', p_document_id;
  end if;

  v_authorized := (
    (v_doc.employee_id = my_employee_id() and public.is_active_employee(v_doc.employee_id))
    or my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location()
        and not public.is_restricted_doc_type(v_doc.doc_type))
  );

  if not v_authorized then
    insert into audit_log (table_name, record_id, changed_by, action, old_value)
    values ('employee_documents', p_document_id, auth.uid(), 'unauthorized_access_attempt',
      jsonb_build_object('attempted_action', p_action));
    raise exception 'Not authorized to access this document';
  end if;

  insert into audit_log (table_name, record_id, changed_by, action, old_value)
  values ('employee_documents', p_document_id, auth.uid(), p_action,
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type));
end;
$$;

grant execute on function public.submit_document_renewal(uuid, text, date, text) to authenticated;
grant execute on function public.approve_document(uuid) to authenticated;
grant execute on function public.reject_document(uuid, text) to authenticated;
grant execute on function public.archive_document(uuid) to authenticated;
grant execute on function public.delete_pending_document(uuid) to authenticated;
grant execute on function public.log_document_access(uuid, text) to authenticated;

