
-- Path convention: entity_id/candidate_id/file_id/filename (mirrors the
-- employee-documents bucket). Admins get read/write scoped like the table
-- RLS above; the interviewer gets read-only, and only for the exact object
-- backing a candidate_files row that's visible_to_interviewers = true and
-- linked to one of their own, non-cancelled, in-window, in-entity
-- interviews -- never a bucket- or folder-wide grant.
create policy candidate_files_bucket_admin_read on storage.objects
for select
using (
  bucket_id = 'candidate-files'
  and exists (
    select 1 from public.candidate_files cf
    where cf.storage_path = storage.objects.name
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and cf.entity_id = my_entity())
        or (
          my_role() = 'location_manager'
          and exists (select 1 from public.candidates c where c.id = cf.candidate_id and c.location_id = my_location())
        )
      )
  )
);

create policy candidate_files_bucket_admin_write on storage.objects
for insert
with check (
  bucket_id = 'candidate-files'
  and (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and (storage.foldername(name))[1] = my_entity()::text)
    or (
      my_role() = 'location_manager'
      and exists (
        select 1 from public.candidates c
        where c.id::text = (storage.foldername(name))[2] and c.location_id = my_location()
      )
    )
  )
);

create policy candidate_files_bucket_admin_delete on storage.objects
for delete
using (
  bucket_id = 'candidate-files'
  and (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and (storage.foldername(name))[1] = my_entity()::text)
    or (
      my_role() = 'location_manager'
      and exists (
        select 1 from public.candidates c
        where c.id::text = (storage.foldername(name))[2] and c.location_id = my_location()
      )
    )
  )
);

create policy candidate_files_bucket_interviewer_read on storage.objects
for select
using (
  bucket_id = 'candidate-files'
  and exists (
    select 1
    from public.candidate_files cf
    join public.job_applications ja on ja.candidate_id = cf.candidate_id
    join public.interviews iv on iv.application_id = ja.id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where cf.storage_path = storage.objects.name
      and cf.visible_to_interviewers = true
      and iv.interviewer_id = auth.uid()
      and iv.cancelled_at is null
      and jr.entity_id = my_entity()
      and public.is_active_employee(my_employee_id())
      and public.is_interview_within_visibility_window(
        iv.scheduled_at,
        (select f.status from public.interview_feedback f where f.interview_id = iv.id)
      )
  )
);
