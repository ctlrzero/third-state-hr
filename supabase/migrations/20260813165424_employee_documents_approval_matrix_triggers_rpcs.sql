
-- Insert invariants: allow an insert to arrive pre-approved (used only by
-- create_document_upload's immediate-approve path for owner / opted-in
-- entity_admin uploads), but require the approval to already satisfy the
-- matrix at insert time. Renewals (supersedes_document_id set) always come
-- from an employee's own submission and must always start pending_review --
-- there is no immediate-approve path for a renewal.
create or replace function public.enforce_document_insert_invariants()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_prev record;
begin
  if new.supersedes_document_id is not null then
    select id, employee_id, version_number, is_current, review_status
      into v_prev
      from employee_documents
      where id = new.supersedes_document_id;

    if v_prev.id is null then
      raise exception 'supersedes_document_id does not reference an existing document';
    end if;

    if v_prev.employee_id <> new.employee_id then
      raise exception 'A renewal must supersede a document belonging to the same employee';
    end if;

    if v_prev.is_current is not true or v_prev.review_status <> 'approved' then
      raise exception 'Only the current approved document for an employee/type can be renewed';
    end if;

    new.version_number := v_prev.version_number + 1;

    if new.review_status <> 'pending_review' or new.reviewed_by is not null or new.reviewed_at is not null then
      raise exception 'A renewal must be submitted as pending_review with no reviewer set';
    end if;
  else
    new.version_number := 1;

    if new.review_status = 'pending_review' then
      if new.reviewed_by is not null or new.reviewed_at is not null then
        raise exception 'A pending submission cannot have reviewed_by/reviewed_at set';
      end if;
    elsif new.review_status = 'approved' then
      if new.reviewed_by is null or new.reviewed_at is null then
        raise exception 'An approved document must record reviewed_by and reviewed_at';
      end if;
      if not public.can_review_document(new.submitted_by, new.reviewed_by, new.doc_type) then
        raise exception 'Not authorized to approve this document at insert time';
      end if;
    else
      raise exception 'A new document must be inserted as pending_review, or approved when the uploader is authorized to self-approve';
    end if;
  end if;

  return new;
end;
$$;

-- Update invariants: same immutability + rejection/archive rules as before,
-- but the approval-authority check now defers to the shared matrix instead
-- of a blanket "not the submitter" rule, so it can express the different
-- rules for employee / location_manager / entity_admin / owner submitters.
create or replace function public.enforce_document_update_invariants()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if new.employee_id <> old.employee_id
     or new.doc_type <> old.doc_type
     or new.storage_path <> old.storage_path
     or new.submitted_by is distinct from old.submitted_by
     or new.submitted_at is distinct from old.submitted_at
     or new.version_number <> old.version_number
     or new.supersedes_document_id is distinct from old.supersedes_document_id
  then
    raise exception 'employee_id, doc_type, storage_path, submitted_by, submitted_at, version_number and supersedes_document_id are immutable after submission';
  end if;

  if new.review_status = 'approved' and old.review_status is distinct from 'approved' then
    if new.reviewed_by is null or new.reviewed_at is null then
      raise exception 'Approval must record reviewed_by and reviewed_at';
    end if;
    if not public.can_review_document(new.submitted_by, new.reviewed_by, new.doc_type) then
      raise exception 'Not authorized to approve this document under the approval matrix';
    end if;
  end if;

  if new.review_status = 'rejected' then
    if new.rejection_reason is null or length(trim(new.rejection_reason)) = 0 then
      raise exception 'Rejection requires a rejection_reason';
    end if;
    if new.reviewed_by is null then
      raise exception 'Rejection must record a reviewer';
    end if;
    if not public.can_review_document(new.submitted_by, new.reviewed_by, new.doc_type) then
      raise exception 'Not authorized to reject this document under the approval matrix';
    end if;
    if new.is_current is true then
      raise exception 'A rejected document cannot be marked current';
    end if;
  end if;

  if new.review_status = 'archived' then
    if old.review_status = 'pending_review' then
      raise exception 'A pending submission must be rejected or removed, not archived';
    end if;
    if new.archived_by is null or new.archived_at is null then
      raise exception 'Archiving must record archived_by and archived_at';
    end if;
    if new.is_current is true then
      raise exception 'An archived document cannot be marked current';
    end if;
  end if;

  return new;
end;
$$;

-- approve_document / reject_document: keep the existing entity/location
-- scope gate (who may touch this row at all) and layer the submitter-aware
-- approval matrix on top (who may approve *this submitter's* document).
create or replace function public.approve_document(p_document_id uuid)
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

  if not public.can_review_document(v_doc.submitted_by, auth.uid(), v_doc.doc_type) then
    raise exception 'Not authorized to approve this submitter''s document under the approval matrix';
  end if;

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

  if not public.can_review_document(v_doc.submitted_by, auth.uid(), v_doc.doc_type) then
    raise exception 'Not authorized to reject this submitter''s document under the approval matrix';
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
