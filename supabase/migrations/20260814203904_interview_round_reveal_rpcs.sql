
-- Recruiting Admin (entity_admin) or Owner forces a round's reveal even when
-- not every interviewer has submitted (e.g. a straggler never will). Sticky:
-- recorded with a reason and audited, and — unlike the natural "all
-- submitted" path — does not un-reveal if a submitted row is later reopened.
create or replace function public.close_interview_round(p_application_id uuid, p_stage_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_entity_id uuid;
  v_location_id uuid;
  v_requisition_id uuid;
  v_stage_requisition_id uuid;
  v_existing record;
  v_closure_id uuid;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required to close an interview round';
  end if;

  select jr.id, jr.entity_id, jr.location_id
    into v_requisition_id, v_entity_id, v_location_id
    from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = p_application_id;

  if v_requisition_id is null then
    raise exception 'Application % not found', p_application_id;
  end if;

  select requisition_id into v_stage_requisition_id from public.interview_stages where id = p_stage_id;
  if v_stage_requisition_id is null or v_stage_requisition_id <> v_requisition_id then
    raise exception 'Stage does not belong to this application''s requisition';
  end if;

  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Only a Recruiting Admin or Owner may close an interview round';
  end if;

  select * into v_existing
    from public.interview_round_closures
    where application_id = p_application_id and stage_id = p_stage_id;

  insert into public.interview_round_closures (application_id, stage_id, closed_by, reason)
  values (p_application_id, p_stage_id, auth.uid(), p_reason)
  on conflict (application_id, stage_id) do update
    set closed_by = excluded.closed_by, closed_at = now(), reason = excluded.reason
  returning id into v_closure_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values (
    'interview_round_closures', v_closure_id, auth.uid(), 'interview_round_closed',
    jsonb_build_object('application_id', p_application_id, 'stage_id', p_stage_id, 'reason', p_reason, 'already_closed', v_existing.id is not null),
    v_entity_id, v_location_id
  );

  return jsonb_build_object('ok', true, 'already_closed', v_existing.id is not null, 'closed_at', now());
end;
$function$;

revoke all on function public.close_interview_round(uuid, uuid, text) from public, anon;
grant execute on function public.close_interview_round(uuid, uuid, text) to authenticated;

-- Curated, reveal-gated replacement for the Recruiting UI's previous direct
-- `interviews.select('*, interview_feedback(*)')` — that nested embed had no
-- gating at all (see interview_feedback_owner_admin_all history above). This
-- RPC returns every interview for an application plus its feedback, but
-- content columns (recommendation/ratings/strengths/concerns/notes/status/
-- submitted_at/reopened_at/reopen_reason) are null'd out for anyone who
-- isn't owner/entity_admin unless the row's round is revealed AND that row
-- is itself status = 'submitted'. Returns an empty set (not an error) for an
-- application the caller has no access to, or one that doesn't exist.
create or replace function public.get_application_interview_feedback(p_application_id uuid)
returns table (
  interview_id uuid,
  stage_id uuid,
  stage_name text,
  sequence integer,
  scheduled_at timestamptz,
  interviewer_id uuid,
  interviewer_name text,
  cancelled_at timestamptz,
  outcome text,
  feedback_id uuid,
  feedback_status text,
  feedback_visible boolean,
  recommendation text,
  competency_ratings jsonb,
  strengths text,
  concerns text,
  notes text,
  submitted_at timestamptz,
  reopened_at timestamptz,
  reopen_reason text,
  round_revealed boolean,
  round_closed boolean,
  round_closed_by_name text,
  round_closed_at timestamptz,
  round_closed_reason text,
  round_required_count integer,
  round_submitted_count integer
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_entity_id uuid;
  v_location_id uuid;
  v_can_see_all boolean;
  v_is_location_manager boolean;
begin
  select jr.entity_id, jr.location_id into v_entity_id, v_location_id
    from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = p_application_id;

  if v_entity_id is null then
    return;
  end if;

  v_can_see_all := (my_role() = 'owner') or (my_role() = 'entity_admin' and v_entity_id = my_entity());
  v_is_location_manager := (my_role() = 'location_manager' and v_location_id = my_location());

  if not (v_can_see_all or v_is_location_manager) then
    return;
  end if;

  return query
  select
    base.interview_id,
    base.stage_id,
    base.stage_name,
    base.sequence,
    base.scheduled_at,
    base.interviewer_id,
    base.interviewer_name,
    base.cancelled_at,
    base.outcome,
    case when base.show then base.feedback_id else null end,
    case when base.show then base.feedback_status else null end,
    base.show,
    case when base.show then base.recommendation else null end,
    case when base.show then base.competency_ratings else null end,
    case when base.show then base.strengths else null end,
    case when base.show then base.concerns else null end,
    case when base.show then base.notes else null end,
    case when base.show then base.submitted_at else null end,
    case when base.show then base.reopened_at else null end,
    case when base.show then base.reopen_reason else null end,
    base.revealed,
    base.round_closed,
    base.round_closed_by_name,
    base.round_closed_at,
    base.round_closed_reason,
    base.round_required_count,
    base.round_submitted_count
  from (
    select
      iv.id as interview_id,
      iv.stage_id,
      ist.name as stage_name,
      ist.sequence,
      iv.scheduled_at,
      iv.interviewer_id,
      emp.full_name as interviewer_name,
      iv.cancelled_at,
      iv.outcome,
      f.id as feedback_id,
      f.status as feedback_status,
      f.recommendation,
      f.competency_ratings,
      f.strengths,
      f.concerns,
      f.notes,
      f.submitted_at,
      f.reopened_at,
      f.reopen_reason,
      public.is_interview_round_revealed(p_application_id, iv.stage_id) as revealed,
      (rc.id is not null) as round_closed,
      rc_emp.full_name as round_closed_by_name,
      rc.closed_at as round_closed_at,
      rc.reason as round_closed_reason,
      (
        select count(*)::int from public.interviews iv2
        where iv2.application_id = iv.application_id and iv2.stage_id = iv.stage_id and iv2.cancelled_at is null
      ) as round_required_count,
      (
        select count(*)::int from public.interviews iv2
        join public.interview_feedback f2 on f2.interview_id = iv2.id
        where iv2.application_id = iv.application_id and iv2.stage_id = iv.stage_id and iv2.cancelled_at is null and f2.status = 'submitted'
      ) as round_submitted_count,
      (
        v_can_see_all
        or (v_is_location_manager and public.is_interview_round_revealed(p_application_id, iv.stage_id) and f.status = 'submitted')
      ) as show
    from public.interviews iv
    join public.interview_stages ist on ist.id = iv.stage_id
    left join public.interview_feedback f on f.interview_id = iv.id
    left join public.employees emp on emp.auth_user_id = iv.interviewer_id
    left join public.interview_round_closures rc on rc.application_id = iv.application_id and rc.stage_id = iv.stage_id
    left join public.employees rc_emp on rc_emp.auth_user_id = rc.closed_by
    where iv.application_id = p_application_id
  ) base
  order by base.scheduled_at;
end;
$function$;

revoke all on function public.get_application_interview_feedback(uuid) from public, anon;
grant execute on function public.get_application_interview_feedback(uuid) to authenticated;

