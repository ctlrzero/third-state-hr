
-- Bug fix: interviews_interviewer_select and candidate_files_interviewer_select
-- both computed feedback status via a correlated subquery directly against
-- interview_feedback. Because interview_feedback's own RLS policies reference
-- interviews (to check interviewer_id/entity scope), Postgres's policy planner
-- had to expand interviews' RLS -> interview_feedback's RLS -> interviews'
-- RLS -> ... indefinitely, raising "infinite recursion detected in policy for
-- relation interviews" for ANY authenticated query against interviews or
-- candidate_files (not just the interviewer role - the planner must expand
-- every permissive policy on a table regardless of which one ultimately
-- matches the caller).
--
-- Fix: resolve feedback status through a SECURITY DEFINER helper function.
-- This project's SECURITY DEFINER functions are owned by a role that bypasses
-- RLS, so the lookup inside the function never re-triggers interview_feedback's
-- policies, breaking the cycle while preserving the exact same visibility rule.
create or replace function public.interview_feedback_status_for(p_interview_id uuid)
returns text
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select status from public.interview_feedback where interview_id = p_interview_id;
$$;

revoke all on function public.interview_feedback_status_for(uuid) from public, anon;
grant execute on function public.interview_feedback_status_for(uuid) to authenticated;

drop policy if exists interviews_interviewer_select on public.interviews;
create policy interviews_interviewer_select on public.interviews
  for select
  to authenticated
  using (
    interviewer_id = auth.uid()
    and is_active_employee(my_employee_id())
    and exists (
      select 1 from job_applications ja
      join job_requisitions jr on jr.id = ja.requisition_id
      where ja.id = interviews.application_id and jr.entity_id = my_entity()
    )
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
    and is_active_employee(my_employee_id())
    and exists (
      select 1
      from interviews iv
      join job_applications ja on ja.id = iv.application_id
      join job_requisitions jr on jr.id = ja.requisition_id
      where ja.candidate_id = candidate_files.candidate_id
        and iv.interviewer_id = auth.uid()
        and iv.cancelled_at is null
        and jr.entity_id = my_entity()
        and is_interview_within_visibility_window(
          iv.scheduled_at,
          public.interview_feedback_status_for(iv.id)
        )
    )
  );
