
-- Bug found by negative-access test T5: the documents_insert policy's
-- supersedes_document_id ownership check subqueried employee_documents
-- itself (aliased pd), which (a) re-triggers RLS evaluation on the same
-- table mid-INSERT, tripping Postgres's "infinite recursion detected in
-- policy for relation" guard, and (b) had a logic bug comparing
-- pd.id = pd.supersedes_document_id (always false / self-referential)
-- instead of the NEW row's supersedes_document_id value. The insert was
-- still blocked (Postgres raises before completing), but for the wrong
-- reason and with a confusing error instead of a clean rejection.
--
-- Fix: move the same-table lookup into a SECURITY DEFINER helper, matching
-- the established pattern (my_employee_id(), is_active_employee()) that
-- lets these functions read rows without re-entering RLS on the caller's
-- behalf.
create or replace function public.renewal_supersedes_owned_by(
  p_supersedes_document_id uuid,
  p_employee_id uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select exists (
    select 1
    from public.employee_documents pd
    where pd.id = p_supersedes_document_id
      and pd.employee_id = p_employee_id
  );
$$;

revoke all on function public.renewal_supersedes_owned_by(uuid, uuid) from public, anon;
grant execute on function public.renewal_supersedes_owned_by(uuid, uuid) to authenticated;

drop policy if exists documents_insert on public.employee_documents;

create policy documents_insert on public.employee_documents
for insert
with check (
  (
    employee_id = my_employee_id()
    and public.is_active_employee(employee_id)
    and submitted_by = auth.uid()
    and review_status = 'pending_review'
    and is_current = false
    and reviewed_by is null and reviewed_at is null
    and archived_by is null and archived_at is null
    and rejection_reason is null
    and (
      supersedes_document_id is null
      or public.renewal_supersedes_owned_by(supersedes_document_id, my_employee_id())
    )
  )
  or exists (
    select 1 from public.employees e
    where e.id = employee_documents.employee_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and e.entity_id = my_entity())
        or (
          my_role() = 'location_manager'
          and e.home_location_id = my_location()
          and not public.is_restricted_doc_type(employee_documents.doc_type)
        )
      )
  )
);

