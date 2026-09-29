-- Owner uploads no longer wait for review.
--
-- approve_document had a hard "uploader can never approve" rule that ran
-- before the approval matrix, and confirm_document_upload only auto-approved
-- when someone other than the uploader confirmed (never the case). Both now
-- defer to can_review_document(): the owner may approve anything, including
-- their own uploads; entity_admin self-approval stays behind
-- entity_admin_self_approval_enabled and excludes restricted doc types;
-- location managers and staff still need a separate reviewer.

create or replace function public.approve_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_doc record;
begin
  select d.*, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_doc from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_document_id for update of d;

  if v_doc.id is null then raise exception 'Document % not found', p_document_id; end if;
  if not v_doc.upload_confirmed then raise exception 'This document''s upload has not been confirmed yet'; end if;
  if v_doc.review_status <> 'pending_review' then raise exception 'Only a pending_review document can be approved'; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_doc.emp_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_doc.emp_home_location = my_location() and not public.is_restricted_doc_type(v_doc.doc_type))
  ) then raise exception 'Not authorized to review this document'; end if;

  if not public.can_review_document(v_doc.submitted_by, auth.uid(), v_doc.doc_type) then
    if v_doc.uploaded_by = auth.uid() then
      raise exception 'You uploaded this document; someone else must approve it' using errcode = '42501';
    end if;
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
    jsonb_build_object('employee_id', v_doc.employee_id, 'doc_type', v_doc.doc_type, 'supersedes', v_doc.supersedes_document_id,
                       'self_approved', v_doc.uploaded_by = auth.uid()),
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
$$;

create or replace function public.confirm_document_upload(p_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
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

  -- An upload by someone the approval matrix already trusts to approve it
  -- (the owner; an entity admin where self-approval is enabled) is approved
  -- on the spot instead of waiting in the review queue.
  if v_role in ('owner', 'entity_admin')
     and v_doc.uploaded_by = auth.uid()
     and public.can_review_document(v_doc.submitted_by, auth.uid(), v_doc.doc_type) then
    perform public.approve_document(p_document_id);
    return jsonb_build_object('ok', true, 'already_confirmed', false, 'review_status', 'approved');
  end if;

  return jsonb_build_object('ok', true, 'already_confirmed', false, 'review_status', 'pending_review');
end;
$$;
