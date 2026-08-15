
create or replace function public.interview_state_for(p_cancelled_at timestamptz, p_scheduled_at timestamptz, p_feedback_status text)
returns text
language sql
immutable
set search_path to 'public', 'pg_temp'
as $$
  select case
    when p_cancelled_at is not null then 'cancelled'
    when p_feedback_status = 'reopened' then 'reopened'
    when p_feedback_status = 'submitted' then 'feedback_submitted'
    when p_scheduled_at <= now() then 'completed'
    else 'upcoming'
  end;
$$;

create or replace function public.has_interview_assignments()
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select exists (select 1 from public.interviews iv where iv.interviewer_id = auth.uid());
$$;

-- Curated, minimum-necessary column set only -- never a raw select on
-- candidates/job_applications for this role. Re-validates assignment,
-- active-employee, entity, and visibility window itself (this function is
-- SECURITY DEFINER and therefore bypasses RLS internally; the WHERE clause
-- is the actual enforcement here, mirrored by, not replaced by, the RLS
-- policies on the underlying tables).
create or replace function public.get_my_interviews()
returns table (
  interview_id uuid,
  candidate_name text,
  position_title text,
  scheduled_at timestamptz,
  format text,
  meeting_location text,
  stage_name text,
  state text,
  feedback_status text
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select
    iv.id,
    c.full_name,
    p.title,
    iv.scheduled_at,
    iv.format,
    case when iv.cancelled_at is null then iv.meeting_location else null end,
    ist.name,
    public.interview_state_for(iv.cancelled_at, iv.scheduled_at, f.status),
    f.status
  from public.interviews iv
  join public.job_applications ja on ja.id = iv.application_id
  join public.job_requisitions jr on jr.id = ja.requisition_id
  join public.candidates c on c.id = ja.candidate_id
  join public.positions p on p.id = jr.position_id
  join public.interview_stages ist on ist.id = iv.stage_id
  left join public.interview_feedback f on f.interview_id = iv.id
  where iv.interviewer_id = auth.uid()
    and public.is_active_employee(my_employee_id())
    and jr.entity_id = my_entity()
    and public.is_interview_within_visibility_window(iv.scheduled_at, f.status)
  order by iv.scheduled_at desc;
$$;

create or replace function public.get_interview_detail(p_interview_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
  v_result jsonb;
begin
  select iv.id, iv.scheduled_at, iv.format, iv.meeting_location, iv.cancelled_at, iv.cancellation_reason,
         c.full_name as candidate_name, p.title as position_title,
         ist.name as stage_name, ist.guide as interview_guide,
         f.id as feedback_id, f.status as feedback_status, f.recommendation, f.competency_ratings,
         f.strengths, f.concerns, f.notes, f.submitted_at, f.reopen_reason, f.reopened_at
    into v_row
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    join public.candidates c on c.id = ja.candidate_id
    join public.positions p on p.id = jr.position_id
    join public.interview_stages ist on ist.id = iv.stage_id
    left join public.interview_feedback f on f.interview_id = iv.id
    where iv.id = p_interview_id
      and iv.interviewer_id = auth.uid()
      and public.is_active_employee(my_employee_id())
      and jr.entity_id = my_entity()
      and public.is_interview_within_visibility_window(iv.scheduled_at, f.status);

  if v_row.id is null then
    raise exception 'Interview not found or not accessible';
  end if;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('interviews', p_interview_id, auth.uid(), 'interview_viewed', jsonb_build_object('via', 'my_interviews'));

  v_result := jsonb_build_object(
    'id', v_row.id,
    'candidate_name', v_row.candidate_name,
    'position_title', v_row.position_title,
    'scheduled_at', v_row.scheduled_at,
    'format', v_row.format,
    'meeting_location', case when v_row.cancelled_at is null then v_row.meeting_location else null end,
    'stage_name', v_row.stage_name,
    'interview_guide', v_row.interview_guide,
    'cancelled_at', v_row.cancelled_at,
    'cancellation_reason', v_row.cancellation_reason,
    'state', public.interview_state_for(v_row.cancelled_at, v_row.scheduled_at, v_row.feedback_status),
    'feedback', case when v_row.feedback_id is null then null else jsonb_build_object(
      'status', v_row.feedback_status,
      'recommendation', v_row.recommendation,
      'competency_ratings', v_row.competency_ratings,
      'strengths', v_row.strengths,
      'concerns', v_row.concerns,
      'notes', v_row.notes,
      'submitted_at', v_row.submitted_at,
      'reopen_reason', v_row.reopen_reason,
      'reopened_at', v_row.reopened_at
    ) end
  );

  return v_result;
end;
$$;

create or replace function public.save_interview_feedback_draft(
  p_interview_id uuid,
  p_recommendation text default null,
  p_competency_ratings jsonb default null,
  p_strengths text default null,
  p_concerns text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_iv record;
  v_feedback_id uuid;
  v_current_status text;
begin
  select iv.id, iv.cancelled_at
    into v_iv
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id
      and iv.interviewer_id = auth.uid()
      and public.is_active_employee(my_employee_id())
      and jr.entity_id = my_entity();

  if v_iv.id is null then
    raise exception 'Interview not found or not accessible';
  end if;

  if v_iv.cancelled_at is not null then
    raise exception 'Cannot save feedback for a cancelled interview';
  end if;

  select status into v_current_status from public.interview_feedback where interview_id = p_interview_id;

  if v_current_status = 'submitted' then
    raise exception 'Feedback has already been submitted and is read-only. Ask a recruiting admin to reopen it.';
  end if;

  insert into public.interview_feedback (interview_id, submitted_by, status, recommendation, competency_ratings, strengths, concerns, notes)
  values (p_interview_id, auth.uid(), 'draft', p_recommendation, p_competency_ratings, p_strengths, p_concerns, p_notes)
  on conflict (interview_id) do update
    set recommendation = excluded.recommendation,
        competency_ratings = excluded.competency_ratings,
        strengths = excluded.strengths,
        concerns = excluded.concerns,
        notes = excluded.notes,
        status = case when interview_feedback.status = 'reopened' then 'reopened' else 'draft' end
  returning id into v_feedback_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('interview_feedback', v_feedback_id, auth.uid(), 'feedback_draft_saved', jsonb_build_object('interview_id', p_interview_id));

  return v_feedback_id;
end;
$$;

create or replace function public.submit_interview_feedback(p_interview_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_iv record;
  v_feedback record;
begin
  select iv.id, iv.cancelled_at
    into v_iv
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id
      and iv.interviewer_id = auth.uid()
      and public.is_active_employee(my_employee_id())
      and jr.entity_id = my_entity();

  if v_iv.id is null then
    raise exception 'Interview not found or not accessible';
  end if;

  if v_iv.cancelled_at is not null then
    raise exception 'Cannot submit feedback for a cancelled interview';
  end if;

  select * into v_feedback from public.interview_feedback where interview_id = p_interview_id and submitted_by = auth.uid();

  if v_feedback.id is null then
    raise exception 'Save a draft before submitting';
  end if;

  if v_feedback.status = 'submitted' then
    raise exception 'Feedback has already been submitted';
  end if;

  if v_feedback.recommendation is null then
    raise exception 'A recommendation is required before submitting';
  end if;

  update public.interview_feedback
    set status = 'submitted', submitted_at = now()
    where id = v_feedback.id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('interview_feedback', v_feedback.id, auth.uid(), 'feedback_submitted', jsonb_build_object('interview_id', p_interview_id));
end;
$$;

create or replace function public.reopen_interview_feedback(p_interview_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_feedback record;
  v_entity_id uuid;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required to reopen feedback';
  end if;

  select jr.entity_id into v_entity_id
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id;

  if v_entity_id is null then
    raise exception 'Interview % not found', p_interview_id;
  end if;

  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Only a Recruiting Admin or Owner may reopen submitted feedback';
  end if;

  select * into v_feedback from public.interview_feedback where interview_id = p_interview_id;

  if v_feedback.id is null then
    raise exception 'No feedback exists for this interview yet';
  end if;

  if v_feedback.status <> 'submitted' then
    raise exception 'Only submitted feedback can be reopened (current status: %)', v_feedback.status;
  end if;

  update public.interview_feedback
    set status = 'reopened', reopened_by = auth.uid(), reopened_at = now(), reopen_reason = p_reason
    where id = v_feedback.id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('interview_feedback', v_feedback.id, auth.uid(), 'feedback_reopened', jsonb_build_object('interview_id', p_interview_id, 'reason', p_reason));
end;
$$;

create or replace function public.cancel_interview(p_interview_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A cancellation reason is required';
  end if;

  select jr.entity_id, jr.location_id into v_entity_id, v_location_id
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id;

  if v_entity_id is null then
    raise exception 'Interview % not found', p_interview_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then
    raise exception 'Not authorized to cancel this interview';
  end if;

  update public.interviews
    set cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_interview_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('interviews', p_interview_id, auth.uid(), 'interview_cancelled', jsonb_build_object('reason', p_reason));
end;
$$;

create or replace function public.list_candidate_files_for_interview(p_interview_id uuid)
returns table(id uuid, file_type text, storage_path text)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select cf.id, cf.file_type, cf.storage_path
  from public.candidate_files cf
  join public.job_applications ja on ja.candidate_id = cf.candidate_id
  join public.interviews iv on iv.application_id = ja.id
  join public.job_requisitions jr on jr.id = ja.requisition_id
  where iv.id = p_interview_id
    and iv.interviewer_id = auth.uid()
    and iv.cancelled_at is null
    and cf.visible_to_interviewers = true
    and jr.entity_id = my_entity()
    and public.is_active_employee(my_employee_id())
    and public.is_interview_within_visibility_window(
      iv.scheduled_at,
      (select f.status from public.interview_feedback f where f.interview_id = iv.id)
    );
$$;

create or replace function public.log_candidate_file_access(p_interview_id uuid, p_file_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.candidate_files cf
  join public.job_applications ja on ja.candidate_id = cf.candidate_id
  join public.interviews iv on iv.application_id = ja.id
  join public.job_requisitions jr on jr.id = ja.requisition_id
  where cf.id = p_file_id
    and iv.id = p_interview_id
    and iv.interviewer_id = auth.uid()
    and iv.cancelled_at is null
    and cf.visible_to_interviewers = true
    and jr.entity_id = my_entity()
    and public.is_active_employee(my_employee_id())
    and public.is_interview_within_visibility_window(
      iv.scheduled_at,
      (select f.status from public.interview_feedback f where f.interview_id = iv.id)
    );

  if v_count = 0 then
    insert into audit_log (table_name, record_id, changed_by, action, new_value)
    values ('candidate_files', p_file_id, auth.uid(), 'unauthorized_access_attempt', jsonb_build_object('interview_id', p_interview_id));
    raise exception 'Not authorized to access this file';
  end if;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('candidate_files', p_file_id, auth.uid(), 'candidate_file_accessed', jsonb_build_object('interview_id', p_interview_id));
end;
$$;

revoke all on function public.interview_state_for(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.interview_state_for(timestamptz, timestamptz, text) to authenticated;

revoke all on function public.has_interview_assignments() from public, anon;
grant execute on function public.has_interview_assignments() to authenticated;

revoke all on function public.get_my_interviews() from public, anon;
grant execute on function public.get_my_interviews() to authenticated;

revoke all on function public.get_interview_detail(uuid) from public, anon;
grant execute on function public.get_interview_detail(uuid) to authenticated;

revoke all on function public.save_interview_feedback_draft(uuid, text, jsonb, text, text, text) from public, anon;
grant execute on function public.save_interview_feedback_draft(uuid, text, jsonb, text, text, text) to authenticated;

revoke all on function public.submit_interview_feedback(uuid) from public, anon;
grant execute on function public.submit_interview_feedback(uuid) to authenticated;

revoke all on function public.reopen_interview_feedback(uuid, text) from public, anon;
grant execute on function public.reopen_interview_feedback(uuid, text) to authenticated;

revoke all on function public.cancel_interview(uuid, text) from public, anon;
grant execute on function public.cancel_interview(uuid, text) to authenticated;

revoke all on function public.list_candidate_files_for_interview(uuid) from public, anon;
grant execute on function public.list_candidate_files_for_interview(uuid) to authenticated;

revoke all on function public.log_candidate_file_access(uuid, uuid) from public, anon;
grant execute on function public.log_candidate_file_access(uuid, uuid) to authenticated;
