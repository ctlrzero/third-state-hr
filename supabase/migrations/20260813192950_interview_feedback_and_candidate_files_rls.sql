
-- interview_feedback: admins (scoped like interviews_admin_all) get full
-- access -- this is how a Recruiting Admin/Owner reviews and reopens
-- feedback. The interviewer only ever gets read access to their own
-- submission; all writes (draft save, submit, reopen) go through RPCs so
-- the "read-only after submit" and "reopen requires a reason" rules live
-- in exactly one place instead of being duplicated in RLS.
create policy interview_feedback_admin_all on public.interview_feedback
for all
using (
  exists (
    select 1 from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = interview_feedback.interview_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
)
with check (
  exists (
    select 1 from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = interview_feedback.interview_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
);

create policy interview_feedback_interviewer_select on public.interview_feedback
for select
using (
  submitted_by = auth.uid()
  and exists (
    select 1 from public.interviews iv
    where iv.id = interview_feedback.interview_id and iv.interviewer_id = auth.uid()
  )
);

-- candidate_files: admins get the same ALL access as candidates_access.
-- The interviewer gets SELECT only, only for files explicitly marked
-- visible_to_interviewers, and only when linked (via job_applications) to
-- an interview assigned to them that's not cancelled, in-entity, and
-- within the visibility window -- never a folder-wide grant.
create policy candidate_files_admin_all on public.candidate_files
for all
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (
    my_role() = 'location_manager'
    and exists (select 1 from public.candidates c where c.id = candidate_files.candidate_id and c.location_id = my_location())
  )
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (
    my_role() = 'location_manager'
    and exists (select 1 from public.candidates c where c.id = candidate_files.candidate_id and c.location_id = my_location())
  )
);

create policy candidate_files_interviewer_select on public.candidate_files
for select
using (
  visible_to_interviewers = true
  and public.is_active_employee(my_employee_id())
  and exists (
    select 1
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.candidate_id = candidate_files.candidate_id
      and iv.interviewer_id = auth.uid()
      and iv.cancelled_at is null
      and jr.entity_id = my_entity()
      and public.is_interview_within_visibility_window(
        iv.scheduled_at,
        (select f.status from public.interview_feedback f where f.interview_id = iv.id)
      )
  )
);
