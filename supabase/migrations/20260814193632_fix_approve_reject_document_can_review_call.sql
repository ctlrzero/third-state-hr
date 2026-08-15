
-- Fix a copy-paste regression introduced in wire_notifications_documents: approve_document
-- / reject_document called can_review_document() with the wrong (2-arg) signature. The
-- real, current signature is the 3-arg one from the Phase 1.4 hardening pass
-- (p_submitted_by, p_reviewed_by, p_doc_type), where p_reviewed_by must equal auth.uid().
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

  perform public.create_notification(
    v_doc.emp_entity_id, null, v_doc.employee_id, 'document_approved',
    'Document approved',
    format('Your %s has been approved.', replace(v_doc.doc_type::text, '_', ' ')),
    'employee_documents', p_document_id, 'normal',
    'document_approved:' || p_document_id::text
  );
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

  perform public.create_notification(
    v_doc.emp_entity_id, null, v_doc.employee_id, 'document_rejected',
    'Document rejected',
    format('Your %s was rejected: %s', replace(v_doc.doc_type::text, '_', ' '), p_reason),
    'employee_documents', p_document_id, 'high',
    'document_rejected:' || p_document_id::text
  );
end;
$$;

revoke all on function public.approve_document(uuid) from public, anon;
grant execute on function public.approve_document(uuid) to authenticated;
revoke all on function public.reject_document(uuid, text) from public, anon;
grant execute on function public.reject_document(uuid, text) to authenticated;

