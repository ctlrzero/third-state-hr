
-- Location Managers may now see limited metadata (doc type, expiry,
-- review/version state) for sensitive doc types, but never the file itself
-- -- previously they saw nothing at all for a restricted type, not even the
-- expiry date, since documents_select excluded the whole row. Row-level
-- security can't redact individual columns, so this is a curated,
-- SECURITY DEFINER projection (the same pattern as get_audit_log /
-- get_my_notifications) rather than a change to the raw table policy.
create or replace function public.get_documents_for_review(p_entity_id uuid)
returns table (
  id uuid, employee_id uuid, employee_name text, doc_type document_type, storage_path text, expiry_date date,
  notes text, review_status text, version_number int, supersedes_document_id uuid, is_current boolean,
  submitted_by uuid, submitted_at timestamptz, reviewed_by uuid, reviewed_at timestamptz, rejection_reason text,
  archived_at timestamptz, archived_by uuid, created_at timestamptz, updated_at timestamptz, redacted boolean
)
language plpgsql security definer stable set search_path to 'public', 'pg_temp'
as $$
declare
  v_role user_role := my_role();
  v_mgr_entity uuid;
begin
  if v_role = 'location_manager' then
    select l.entity_id into v_mgr_entity from locations l where l.id = my_location();
    if v_mgr_entity is null or v_mgr_entity <> p_entity_id then
      raise exception 'Not authorized to view documents for this entity';
    end if;
  elsif v_role = 'entity_admin' then
    if p_entity_id <> my_entity() then raise exception 'Not authorized to view documents for this entity'; end if;
  elsif v_role <> 'owner' then
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
  from employee_documents d
  join employees e on e.id = d.employee_id
  where e.entity_id = p_entity_id
    and d.upload_confirmed = true
    and (v_role in ('owner', 'entity_admin') or e.home_location_id = my_location());
end;
$$;

revoke all on function public.get_documents_for_review(uuid) from public, anon;
grant execute on function public.get_documents_for_review(uuid) to authenticated;

-- A document whose file was never confirmed uploaded can't be reviewed --
-- this shouldn't be reachable via the UI (the review queue only ever shows
-- confirmed documents), but it's a real backstop against a direct RPC call.
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
  if not v_doc.upload_confirmed then raise exception 'This document''s upload has not been confirmed yet'; end if;
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
  if not v_doc.upload_confirmed then raise exception 'This document''s upload has not been confirmed yet'; end if;
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

