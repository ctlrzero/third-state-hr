
-- feedback_visible must always be a clean boolean, never NULL. The previous
-- body used `f.status = 'submitted'`, which is NULL (not false) when there's
-- no feedback row at all (f.status is null via the left join), so
-- `... and f.status = 'submitted'` silently propagated NULL into the `show`
-- flag for any never-submitted interview. The CASE-gated content columns
-- still came out correctly hidden (CASE WHEN NULL falls to the ELSE branch),
-- but the boolean flag itself leaked as null instead of false, which the
-- frontend types as `boolean` and would trip up on. Wrap with coalesce().
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
        or (v_is_location_manager and public.is_interview_round_revealed(p_application_id, iv.stage_id) and coalesce(f.status, '') = 'submitted')
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

