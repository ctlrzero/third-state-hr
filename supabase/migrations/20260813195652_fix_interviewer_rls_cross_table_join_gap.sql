
-- Bug fix: interviews_interviewer_select, candidate_files_interviewer_select,
-- and the candidate_files_bucket_interviewer_read storage policy all
-- authorized access by joining directly to job_applications/job_requisitions
-- (and, for storage, interviews too). RLS applies to every table reference
-- inside a policy expression, and the staff/interviewer role has no SELECT
-- grant on job_applications or job_requisitions at all (by design - those
-- stay owner/entity_admin/location_manager only). So those nested joins were
-- silently returning zero rows for a legitimately assigned interviewer any
-- time the check ran as a direct table/storage query instead of through a
-- SECURITY DEFINER RPC - most importantly, this broke real signed-URL access
-- to approved candidate files (Supabase Storage's createSignedUrl checks
-- storage.objects RLS as the calling user, not through our RPCs).
--
-- Fix: move the authorization check into SECURITY DEFINER helper functions
-- (owned by the same bypass-RLS role as every other helper in this project),
-- so the check itself runs without depending on the caller having direct
-- read access to job_applications/job_requisitions/interviews.
create or replace function public.requisition_entity_for_interview(p_interview_id uuid)
returns uuid
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select jr.entity_id
  from public.interviews iv
  join public.job_applications ja on ja.id = iv.application_id
  join public.job_requisitions jr on jr.id = ja.requisition_id
  where iv.id = p_interview_id;
$$;

revoke all on function public.requisition_entity_for_interview(uuid) from public, anon;
grant execute on function public.requisition_entity_for_interview(uuid) to authenticated;

create or replace function public.interviewer_can_access_candidate_file(p_candidate_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select exists (
    select 1
    from public.job_applications ja
    join public.interviews iv on iv.application_id = ja.id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.candidate_id = p_candidate_id
      and iv.interviewer_id = auth.uid()
      and iv.cancelled_at is null
      and jr.entity_id = public.my_entity()
      and public.is_active_employee(public.my_employee_id())
      and public.is_interview_within_visibility_window(
        iv.scheduled_at,
        public.interview_feedback_status_for(iv.id)
      )
  );
$$;

revoke all on function public.interviewer_can_access_candidate_file(uuid) from public, anon;
grant execute on function public.interviewer_can_access_candidate_file(uuid) to authenticated;

drop policy if exists interviews_interviewer_select on public.interviews;
create policy interviews_interviewer_select on public.interviews
  for select
  to authenticated
  using (
    interviewer_id = auth.uid()
    and is_active_employee(my_employee_id())
    and public.requisition_entity_for_interview(interviews.id) = my_entity()
    and is_interview_within_visibility_window(
      scheduled_at,
      public.interview_feedback_status_for(interviews.id)
    )
  );

drop policy if exists candidate_files_interviewer_select on public.candidate_files;
create policy candidate_files_interviewer_select on public.candidate_files
  for select
  to authenticated
  using (
    visible_to_interviewers = true
    and public.interviewer_can_access_candidate_file(candidate_id)
  );

drop policy if exists candidate_files_bucket_interviewer_read on storage.objects;
create policy candidate_files_bucket_interviewer_read on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'candidate-files'
    and exists (
      select 1 from public.candidate_files cf
      where cf.storage_path = objects.name
        and cf.visible_to_interviewers = true
    )
  );
