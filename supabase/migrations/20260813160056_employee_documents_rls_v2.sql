
drop policy if exists documents_select on public.employee_documents;
drop policy if exists documents_insert on public.employee_documents;
drop policy if exists documents_update on public.employee_documents;
drop policy if exists documents_delete on public.employee_documents;

-- SELECT: an active employee sees every version of their own documents
-- (current, pending, rejected, superseded, archived) so they can see status
-- and history. Owner/entity_admin/location_manager see documents for
-- employees in scope; location_manager additionally excludes restricted
-- (compensation-adjacent) doc types.
create policy documents_select on public.employee_documents
for select
using (
  (employee_id = my_employee_id() and public.is_active_employee(employee_id))
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

-- INSERT: an active employee may submit a renewal only for themself, only as
-- pending_review/not-current, only superseding their own current approved
-- document, and only naming themself as submitter. Owner/entity_admin/
-- location_manager may insert directly within scope (first-time uploads),
-- subject to the same doc-type restriction as SELECT.
create policy documents_insert on public.employee_documents
for insert
with check (
  (
    employee_id = my_employee_id()
    and public.is_active_employee(employee_id)
    and submitted_by = auth.uid()
    and review_status = 'pending_review'
    and is_current = false
    and reviewed_by is null
    and reviewed_at is null
    and archived_by is null
    and archived_at is null
    and rejection_reason is null
    and (
      supersedes_document_id is null
      or exists (
        select 1 from public.employee_documents pd
        where pd.id = supersedes_document_id
          and pd.employee_id = my_employee_id()
      )
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

-- UPDATE: owner/entity_admin/location_manager only — employees can never
-- update a document row (no self-approval path exists at all, not even a
-- narrowly-scoped one). Location_manager still excluded from restricted
-- doc types.
create policy documents_update on public.employee_documents
for update
using (
  exists (
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
)
with check (
  exists (
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

-- DELETE: only a pending, not-yet-current submission may ever be removed
-- (a failed/abandoned upload before review) — by its own submitter or by
-- owner/entity_admin/location_manager in scope. Approved, rejected,
-- superseded and archived rows have no delete path at all.
create policy documents_delete on public.employee_documents
for delete
using (
  review_status = 'pending_review'
  and is_current = false
  and (
    submitted_by = auth.uid()
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
  )
);

