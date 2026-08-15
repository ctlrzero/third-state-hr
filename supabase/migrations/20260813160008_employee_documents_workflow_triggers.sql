
-- Defense-in-depth: these invariants hold regardless of whether a write
-- comes through the approve_document/reject_document/submit_document_renewal
-- RPCs or a direct table write from an authorised role. RLS decides *who*
-- may write; these triggers decide whether *what* they're writing is a
-- structurally valid document-workflow transition.

create or replace function public.enforce_document_insert_invariants()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prev record;
begin
  if new.supersedes_document_id is not null then
    select id, employee_id, version_number, is_current, review_status
      into v_prev
      from public.employee_documents
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

    -- Server computes the version number; never trust a client-supplied one.
    new.version_number := v_prev.version_number + 1;
  else
    new.version_number := 1;
  end if;

  -- A brand-new row can never arrive pre-approved/rejected/archived.
  if new.supersedes_document_id is null and new.review_status <> 'pending_review' and new.reviewed_by is not null then
    raise exception 'A new document cannot be inserted already reviewed';
  end if;

  if new.review_status = 'approved' and new.submitted_by = new.reviewed_by then
    raise exception 'Self-approval is not permitted';
  end if;

  return new;
end;
$$;

drop trigger if exists employee_documents_insert_invariants on public.employee_documents;
create trigger employee_documents_insert_invariants
  before insert on public.employee_documents
  for each row execute function public.enforce_document_insert_invariants();

create or replace function public.enforce_document_update_invariants()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Provenance fields are immutable after the row is created.
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
    if new.reviewed_by = new.submitted_by then
      raise exception 'Self-approval is not permitted';
    end if;
  end if;

  if new.review_status = 'rejected' then
    if new.rejection_reason is null or length(trim(new.rejection_reason)) = 0 then
      raise exception 'Rejection requires a rejection_reason';
    end if;
    if new.reviewed_by is null or new.reviewed_by = new.submitted_by then
      raise exception 'Rejection must record a reviewer distinct from the submitter';
    end if;
    -- Rejecting a renewal never touches the still-current approved version.
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

drop trigger if exists employee_documents_update_invariants on public.employee_documents;
create trigger employee_documents_update_invariants
  before update on public.employee_documents
  for each row execute function public.enforce_document_update_invariants();

-- At most one current, approved document per employee per document type —
-- this is what makes "the previous version stays current until approval"
-- and "approval atomically supersedes it" actually enforceable rather than
-- just a convention the application layer promises to follow.
alter table public.employee_documents
  add constraint employee_documents_one_current_per_type
  unique (employee_id, doc_type, is_current) deferrable initially deferred;

