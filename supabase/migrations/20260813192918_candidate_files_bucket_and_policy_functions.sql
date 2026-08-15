
insert into storage.buckets (id, name, public) values ('candidate-files', 'candidate-files', false)
on conflict (id) do nothing;

-- POLICY DECISION (visibility window), documented in README:
-- an assigned interviewer may see an interview and its candidate context
-- from assignment until 30 days after scheduled_at. Inside that window,
-- feedback status doesn't matter. Once the window closes, access remains
-- open ONLY if their feedback is still unfinished (no feedback row yet, or
-- status draft/reopened) -- so pending work is never silently locked out --
-- otherwise (feedback already submitted, or none ever required) it drops
-- out of view. This constant is the single tunable knob for that rule.
create or replace function public.interview_visibility_window_days()
returns int
language sql
immutable
set search_path to 'public', 'pg_temp'
as $$
  select 30;
$$;

create or replace function public.is_interview_within_visibility_window(
  p_scheduled_at timestamptz,
  p_feedback_status text
)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select
    p_feedback_status is null
    or p_feedback_status in ('draft', 'reopened')
    or now() <= p_scheduled_at + (public.interview_visibility_window_days() || ' days')::interval;
$$;

revoke all on function public.interview_visibility_window_days() from public, anon;
grant execute on function public.interview_visibility_window_days() to authenticated;
revoke all on function public.is_interview_within_visibility_window(timestamptz, text) from public, anon;
grant execute on function public.is_interview_within_visibility_window(timestamptz, text) to authenticated;

-- Split interviews_access: the admin branch keeps full ALL access; the
-- interviewer-self branch becomes SELECT-only (no insert/update/delete),
-- so an interviewer can never reassign, reschedule, or change the
-- panel's outcome on their own interview row -- their only write surface
-- is interview_feedback, via RPC. The interviewer branch also requires an
-- active employee record, an entity match, and the visibility window.
drop policy if exists interviews_access on public.interviews;

create policy interviews_admin_all on public.interviews
for all
using (
  exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
)
with check (
  exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
);

create policy interviews_interviewer_select on public.interviews
for select
using (
  interviewer_id = auth.uid()
  and public.is_active_employee(my_employee_id())
  and exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and jr.entity_id = my_entity()
  )
  and public.is_interview_within_visibility_window(
    interviews.scheduled_at,
    (select f.status from public.interview_feedback f where f.interview_id = interviews.id)
  )
);
