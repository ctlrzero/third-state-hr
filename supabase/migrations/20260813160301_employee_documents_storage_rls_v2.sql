
drop policy if exists doc_bucket_read on storage.objects;
drop policy if exists doc_bucket_write on storage.objects;

-- Read/signed-URL generation: mirrors employee_documents SELECT exactly, by
-- joining on the row whose storage_path matches this object's name, rather
-- than trusting the path segments alone. This is what actually replaces the
-- old "any authenticated user, any object in the bucket" policy.
create policy doc_bucket_read on storage.objects
for select
using (
  bucket_id = 'employee-documents'
  and exists (
    select 1 from public.employee_documents d
    join public.employees e on e.id = d.employee_id
    where d.storage_path = storage.objects.name
      and (
        (d.employee_id = public.my_employee_id() and public.is_active_employee(d.employee_id))
        or public.my_role() = 'owner'
        or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
        or (
          public.my_role() = 'location_manager'
          and e.home_location_id = public.my_location()
          and not public.is_restricted_doc_type(d.doc_type)
        )
      )
  )
);

-- Upload: no employee_documents row exists yet for a brand-new object, so
-- this checks the path prefix (entity_id/employee_id/...) against the
-- caller's own scope instead. The employee_documents INSERT policy (which
-- does run before this file is referenced by a row) independently enforces
-- that the row's real employee_id/doc_type are honest, so a mismatched path
-- can't be used to smuggle access.
create policy doc_bucket_write on storage.objects
for insert
with check (
  bucket_id = 'employee-documents'
  and (
    (
      public.my_role() = 'staff'
      and (storage.foldername(name))[2] = public.my_employee_id()::text
      and public.is_active_employee(public.my_employee_id())
    )
    or public.my_role() = 'owner'
    or (public.my_role() = 'entity_admin' and (storage.foldername(name))[1] = public.my_entity()::text)
    or (
      public.my_role() = 'location_manager'
      and exists (
        select 1 from public.employees e
        where e.id::text = (storage.foldername(name))[2]
          and e.home_location_id = public.my_location()
      )
    )
  )
);

-- Delete: only ever a pending, not-current, not-yet-approved upload —
-- exactly the same set employee_documents itself allows deleting.
create policy doc_bucket_delete on storage.objects
for delete
using (
  bucket_id = 'employee-documents'
  and exists (
    select 1 from public.employee_documents d
    join public.employees e on e.id = d.employee_id
    where d.storage_path = storage.objects.name
      and d.review_status = 'pending_review'
      and d.is_current = false
      and (
        d.submitted_by = auth.uid()
        or public.my_role() = 'owner'
        or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
        or (
          public.my_role() = 'location_manager'
          and e.home_location_id = public.my_location()
          and not public.is_restricted_doc_type(d.doc_type)
        )
      )
  )
);

