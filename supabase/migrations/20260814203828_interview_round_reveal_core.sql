
-- Phase 3.12: interview feedback reveal gating.
--
-- A "round" is the set of (non-cancelled) interviews sharing the same
-- (application_id, stage_id). Feedback content stays private to its author
-- and to Recruiting Admin/Owner until either every required interviewer in
-- the round has submitted, or a Recruiting Admin/Owner explicitly closes the
-- round (e.g. a straggler never submits). This table records that explicit
-- closure; the "all submitted" path needs no storage — it's computed live.
create table if not exists public.interview_round_closures (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.job_applications(id) on delete cascade,
  stage_id uuid not null references public.interview_stages(id) on delete cascade,
  closed_by uuid not null,
  closed_at timestamptz not null default now(),
  reason text not null,
  unique (application_id, stage_id)
);

alter table public.interview_round_closures enable row level security;

-- Read-only visibility mirrors interviews_admin_all / applications_access:
-- owner sees everything, entity_admin scoped to their entity, location_manager
-- scoped to their location. This is just process metadata (who closed a
-- round and why) — not feedback content — so no extra gating needed here.
create policy interview_round_closures_select on public.interview_round_closures
  for select
  using (
    exists (
      select 1
      from public.job_applications ja
      join public.job_requisitions jr on jr.id = ja.requisition_id
      where ja.id = interview_round_closures.application_id
        and (
          my_role() = 'owner'
          or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
          or (my_role() = 'location_manager' and jr.location_id = my_location())
        )
    )
  );

-- Writes only ever happen through close_interview_round(), which runs as the
-- table-owning role and bypasses RLS — no INSERT/UPDATE/DELETE policy needed
-- or wanted here.

-- Live "is this round revealed" check: true if an explicit closure exists
-- (sticky — persists even if an interviewer's feedback is later reopened),
-- OR every non-cancelled interview in the round has submitted feedback (and
-- there's at least one such interview). Used both inside RLS and inside the
-- curated get_application_interview_feedback() RPC.
create or replace function public.is_interview_round_revealed(p_application_id uuid, p_stage_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select
    exists (
      select 1 from public.interview_round_closures c
      where c.application_id = p_application_id and c.stage_id = p_stage_id
    )
    or (
      exists (
        select 1 from public.interviews iv
        where iv.application_id = p_application_id and iv.stage_id = p_stage_id and iv.cancelled_at is null
      )
      and not exists (
        select 1
        from public.interviews iv
        left join public.interview_feedback f on f.interview_id = iv.id
        where iv.application_id = p_application_id and iv.stage_id = p_stage_id and iv.cancelled_at is null
          and coalesce(f.status, '') <> 'submitted'
      )
    );
$function$;

revoke all on function public.is_interview_round_revealed(uuid, uuid) from public, anon;
grant execute on function public.is_interview_round_revealed(uuid, uuid) to authenticated;

-- Tighten interview_feedback RLS: location_manager previously had the same
-- unconditional ALL access as owner/entity_admin via interview_feedback_admin_all,
-- which meant every interviewer's draft feedback was visible to any
-- location_manager immediately — no privacy, no reveal gating, and a write
-- path (ALL, not just SELECT) that bypassed the save/submit/reopen RPCs
-- entirely. Split into: owner/entity_admin keep full ALL access (they are
-- the "Recruiting Admin/Owner" the spec exempts from gating); location_manager
-- gets a new, SELECT-only, reveal-gated policy below.
drop policy if exists interview_feedback_admin_all on public.interview_feedback;

create policy interview_feedback_owner_admin_all on public.interview_feedback
  for all
  using (
    exists (
      select 1
      from public.interviews iv
      join public.job_applications ja on ja.id = iv.application_id
      join public.job_requisitions jr on jr.id = ja.requisition_id
      where iv.id = interview_feedback.interview_id
        and (my_role() = 'owner' or (my_role() = 'entity_admin' and jr.entity_id = my_entity()))
    )
  )
  with check (
    exists (
      select 1
      from public.interviews iv
      join public.job_applications ja on ja.id = iv.application_id
      join public.job_requisitions jr on jr.id = ja.requisition_id
      where iv.id = interview_feedback.interview_id
        and (my_role() = 'owner' or (my_role() = 'entity_admin' and jr.entity_id = my_entity()))
    )
  );

-- location_manager may only ever see a feedback row once its round is
-- revealed, and only once that specific row is itself submitted (a reopened
-- row drops back out of view immediately, matching "after reveal show only
-- submitted feedback").
create policy interview_feedback_location_manager_revealed_select on public.interview_feedback
  for select
  using (
    interview_feedback.status = 'submitted'
    and exists (
      select 1
      from public.interviews iv
      join public.job_applications ja on ja.id = iv.application_id
      join public.job_requisitions jr on jr.id = ja.requisition_id
      where iv.id = interview_feedback.interview_id
        and my_role() = 'location_manager'
        and jr.location_id = my_location()
        and public.is_interview_round_revealed(ja.id, iv.stage_id)
    )
  );

