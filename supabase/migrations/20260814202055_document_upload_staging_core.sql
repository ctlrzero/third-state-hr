
-- Phase 2.10: document upload staging/retention. Previously the client
-- uploaded bytes to a client-chosen path (embedding the raw file name) and
-- only afterwards called an RPC to create the row -- if the browser crashed
-- or the network dropped between those two steps, the result was an
-- orphaned blob in storage with no database row pointing to it at all (the
-- opposite of what you'd want to clean up). This flips the order: a pending
-- row is created first, with a server-derived path (no client-controlled
-- file name in the storage key at all), the client uploads to that exact
-- path, and a separate confirm step independently verifies the object
-- actually exists in storage.objects before the document is treated as real.
-- An incomplete upload now always leaves an inspectable, cleanable DB row.

alter table public.employee_documents add column upload_confirmed boolean not null default true;
alter table public.employee_documents add column upload_confirmed_at timestamptz;

-- Only the submitter can see their own not-yet-confirmed row (useful for a
-- retry/debug state in the UI); nobody else — reviewers only ever see
-- confirmed documents.
drop policy documents_select on public.employee_documents;
create policy documents_select on public.employee_documents
  for select to authenticated
  using (
    (upload_confirmed = true or submitted_by = auth.uid())
    and (
      (employee_id = my_employee_id() and is_active_employee(employee_id))
      or exists (
        select 1 from employees e where e.id = employee_documents.employee_id and (
          my_role() = 'owner'
          or (my_role() = 'entity_admin' and e.entity_id = my_entity())
          or (my_role() = 'location_manager' and e.home_location_id = my_location() and not is_restricted_doc_type(employee_documents.doc_type))
        )
      )
    )
  );

create or replace function public.stage_document_upload(
  p_employee_id uuid, p_doc_type document_type, p_file_extension text, p_expiry_date date default null, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_emp record;
  v_role user_role := my_role();
  v_sensitive boolean := public.is_restricted_doc_type(p_doc_type);
  v_new_id uuid := gen_random_uuid();
  v_path text;
  v_current_id uuid;
begin
  if p_file_extension is null or lower(p_file_extension) not in ('pdf', 'jpg', 'jpeg', 'png') then
    raise exception 'Unsupported file type — only PDF, JPG and PNG are accepted';
  end if;

  select e.id, e.entity_id, e.home_location_id, e.employment_status into v_emp from employees e where e.id = p_employee_id;
  if v_emp.id is null then raise exception 'Employee % not found', p_employee_id; end if;
  if v_emp.employment_status <> 'active' then raise exception 'Cannot upload documents for an inactive employee'; end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = my_location() and not v_sensitive)
  ) then raise exception 'Not authorized to upload documents for this employee'; end if;

  select id into v_current_id from employee_documents where employee_id = p_employee_id and doc_type = p_doc_type and is_current = true;

  -- Server-derived path: entity/employee folder segments (relied on by the
  -- storage.objects RLS policies, unchanged), then this document's own
  -- freshly-minted id as the file name -- never the client-supplied original
  -- file name, which never appears in the storage key at all.
  v_path := format('%s/%s/%s/1/%s.%s', v_emp.entity_id, p_employee_id, v_new_id, v_new_id, lower(p_file_extension));

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, version_number, supersedes_document_id, is_current, submitted_by, submitted_at, upload_confirmed
  ) values (
    v_new_id, p_employee_id, p_doc_type, v_path, p_expiry_date, p_notes,
    'pending_review', 1, v_current_id, false, auth.uid(), now(), false
  );

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'document_upload_staged',
    jsonb_build_object('employee_id', p_employee_id, 'doc_type', p_doc_type, 'supersedes', v_current_id, 'submitted_role', v_role),
    v_emp.entity_id, v_emp.home_location_id, p_employee_id);

  return jsonb_build_object('id', v_new_id, 'storage_path', v_path);
end;
$$;

create or replace function public.stage_document_renewal(
  p_current_document_id uuid, p_file_extension text, p_expiry_date date default null, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_current record;
  v_new_id uuid := gen_random_uuid();
  v_path text;
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

  v_path := format('%s/%s/%s/1/%s.%s', v_current.emp_entity_id, v_current.employee_id, v_new_id, v_new_id, lower(p_file_extension));

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, is_current, version_number, supersedes_document_id, submitted_by, submitted_at, upload_confirmed
  ) values (
    v_new_id, v_current.employee_id, v_current.doc_type, v_path, p_expiry_date, p_notes,
    'pending_review', false, 1, p_current_document_id, auth.uid(), now(), false
  );

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'renewal_staged',
    jsonb_build_object('employee_id', v_current.employee_id, 'doc_type', v_current.doc_type, 'supersedes', p_current_document_id),
    v_current.emp_entity_id, v_current.emp_home_location, v_current.employee_id);

  return jsonb_build_object('id', v_new_id, 'storage_path', v_path);
end;
$$;

create or replace function public.confirm_document_upload(p_document_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
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

  -- Independent verification, never trusting the caller's say-so: the
  -- object must actually exist at the exact server-derived path.
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

  -- Preserve the original immediate-approval behaviour (owner uploads, or
  -- entity_admin uploads of a non-sensitive type when self-approval is
  -- enabled) -- but only now that the file is confirmed to actually exist,
  -- never before.
  if v_doc.supersedes_document_id is null and (
    v_role = 'owner'
    or (v_role = 'entity_admin' and not public.is_restricted_doc_type(v_doc.doc_type) and public.entity_admin_self_approval_enabled())
  ) then
    perform public.approve_document(p_document_id);
    return jsonb_build_object('ok', true, 'already_confirmed', false, 'review_status', 'approved');
  end if;

  return jsonb_build_object('ok', true, 'already_confirmed', false, 'review_status', 'pending_review');
end;
$$;

-- Cleanup for uploads that were staged (a row + a reserved path exist) but
-- never confirmed -- e.g. the browser closed before the storage upload
-- finished, or before confirm_document_upload was called. Also removes any
-- storage object that might exist at that path despite never being
-- confirmed (belt-and-suspenders; the common case is that nothing was ever
-- actually uploaded there).
create or replace function public.cleanup_incomplete_document_uploads(p_older_than_hours int default 24) returns int
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
  v_deleted int := 0;
begin
  if not (my_role() = 'owner' or my_role() = 'entity_admin') then
    raise exception 'Not authorized to run document upload cleanup';
  end if;

  for v_row in
    select d.id, d.storage_path, d.employee_id, e.entity_id, e.home_location_id
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.upload_confirmed = false
      and d.created_at < now() - make_interval(hours => greatest(p_older_than_hours, 1))
      and (my_role() = 'owner' or e.entity_id = my_entity())
  loop
    delete from storage.objects where bucket_id = 'employee-documents' and name = v_row.storage_path;
    delete from employee_documents where id = v_row.id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('employee_documents', v_row.id, auth.uid(), 'document_upload_cleanup_removed',
      jsonb_build_object('storage_path', v_row.storage_path), v_row.entity_id, v_row.home_location_id, v_row.employee_id);

    v_deleted := v_deleted + 1;
  end loop;

  return v_deleted;
end;
$$;

revoke all on function public.stage_document_upload(uuid, document_type, text, date, text) from public, anon;
grant execute on function public.stage_document_upload(uuid, document_type, text, date, text) to authenticated;

revoke all on function public.stage_document_renewal(uuid, text, date, text) from public, anon;
grant execute on function public.stage_document_renewal(uuid, text, date, text) to authenticated;

revoke all on function public.confirm_document_upload(uuid) from public, anon;
grant execute on function public.confirm_document_upload(uuid) to authenticated;

revoke all on function public.cleanup_incomplete_document_uploads(int) from public, anon;
grant execute on function public.cleanup_incomplete_document_uploads(int) to authenticated;

