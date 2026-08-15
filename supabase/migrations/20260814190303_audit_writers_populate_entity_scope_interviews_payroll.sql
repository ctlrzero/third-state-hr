
create or replace function public.get_interview_detail(p_interview_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
  v_result jsonb;
begin
  select iv.id, iv.scheduled_at, iv.format, iv.meeting_location, iv.cancelled_at, iv.cancellation_reason,
         c.full_name as candidate_name, p.title as position_title,
         ist.name as stage_name, ist.guide as interview_guide,
         f.id as feedback_id, f.status as feedback_status, f.recommendation, f.competency_ratings,
         f.strengths, f.concerns, f.notes, f.submitted_at, f.reopen_reason, f.reopened_at,
         jr.entity_id, jr.location_id
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

  if v_row.id is null then raise exception 'Interview not found or not accessible'; end if;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interviews', p_interview_id, auth.uid(), 'interview_viewed', jsonb_build_object('via', 'my_interviews'), v_row.entity_id, v_row.location_id);

  v_result := jsonb_build_object(
    'id', v_row.id, 'candidate_name', v_row.candidate_name, 'position_title', v_row.position_title,
    'scheduled_at', v_row.scheduled_at, 'format', v_row.format,
    'meeting_location', case when v_row.cancelled_at is null then v_row.meeting_location else null end,
    'stage_name', v_row.stage_name, 'interview_guide', v_row.interview_guide,
    'cancelled_at', v_row.cancelled_at, 'cancellation_reason', v_row.cancellation_reason,
    'state', public.interview_state_for(v_row.cancelled_at, v_row.scheduled_at, v_row.feedback_status),
    'feedback', case when v_row.feedback_id is null then null else jsonb_build_object(
      'status', v_row.feedback_status, 'recommendation', v_row.recommendation, 'competency_ratings', v_row.competency_ratings,
      'strengths', v_row.strengths, 'concerns', v_row.concerns, 'notes', v_row.notes,
      'submitted_at', v_row.submitted_at, 'reopen_reason', v_row.reopen_reason, 'reopened_at', v_row.reopened_at
    ) end
  );
  return v_result;
end;
$$;

create or replace function public.reopen_interview_feedback(p_interview_id uuid, p_reason text) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_feedback record;
  v_entity_id uuid;
  v_location_id uuid;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'A reason is required to reopen feedback'; end if;

  select jr.entity_id, jr.location_id into v_entity_id, v_location_id
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id;

  if v_entity_id is null then raise exception 'Interview % not found', p_interview_id; end if;
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Only a Recruiting Admin or Owner may reopen submitted feedback';
  end if;

  select * into v_feedback from public.interview_feedback where interview_id = p_interview_id;
  if v_feedback.id is null then raise exception 'No feedback exists for this interview yet'; end if;
  if v_feedback.status <> 'submitted' then raise exception 'Only submitted feedback can be reopened (current status: %)', v_feedback.status; end if;

  update public.interview_feedback set status = 'reopened', reopened_by = auth.uid(), reopened_at = now(), reopen_reason = p_reason
    where id = v_feedback.id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interview_feedback', v_feedback.id, auth.uid(), 'feedback_reopened', jsonb_build_object('interview_id', p_interview_id, 'reason', p_reason), v_entity_id, v_location_id);
end;
$$;

create or replace function public.reschedule_interview(p_interview_id uuid, p_new_scheduled_at timestamptz, p_new_interviewer_id uuid default null, p_format text default null, p_meeting_location text default null, p_reason text default null) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
  v_old record;
  v_new_id uuid;
begin
  select iv.application_id, iv.stage_id, iv.interviewer_id, iv.format, iv.meeting_location,
         iv.cancelled_at, jr.entity_id, jr.location_id
    into v_old
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id;

  if v_old.application_id is null then raise exception 'Interview % not found', p_interview_id; end if;
  v_entity_id := v_old.entity_id;
  v_location_id := v_old.location_id;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then raise exception 'Not authorized to reschedule this interview'; end if;

  if exists (select 1 from public.interviews where rescheduled_from_interview_id = p_interview_id) then
    raise exception 'Interview % has already been rescheduled', p_interview_id;
  end if;

  if v_old.cancelled_at is null then
    update public.interviews set cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = coalesce(p_reason, 'Rescheduled')
      where id = p_interview_id;
  end if;

  insert into public.interviews (
    application_id, stage_id, scheduled_at, interviewer_id, outcome, format, meeting_location, rescheduled_from_interview_id
  ) values (
    v_old.application_id, v_old.stage_id, p_new_scheduled_at, coalesce(p_new_interviewer_id, v_old.interviewer_id), 'pending',
    coalesce(p_format, v_old.format), coalesce(p_meeting_location, v_old.meeting_location), p_interview_id
  ) returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interviews', v_new_id, auth.uid(), 'interview_rescheduled', jsonb_build_object('rescheduled_from', p_interview_id, 'reason', p_reason), v_entity_id, v_location_id);

  return v_new_id;
end;
$$;

create or replace function public.save_interview_feedback_draft(p_interview_id uuid, p_recommendation text default null, p_competency_ratings jsonb default null, p_strengths text default null, p_concerns text default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_iv record;
  v_feedback_id uuid;
  v_current_status text;
begin
  select iv.id, iv.cancelled_at, jr.entity_id, jr.location_id
    into v_iv
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id
      and iv.interviewer_id = auth.uid()
      and public.is_active_employee(my_employee_id())
      and jr.entity_id = my_entity();

  if v_iv.id is null then raise exception 'Interview not found or not accessible'; end if;
  if v_iv.cancelled_at is not null then raise exception 'Cannot save feedback for a cancelled interview'; end if;

  select status into v_current_status from public.interview_feedback where interview_id = p_interview_id;
  if v_current_status = 'submitted' then
    raise exception 'Feedback has already been submitted and is read-only. Ask a recruiting admin to reopen it.';
  end if;

  insert into public.interview_feedback (interview_id, submitted_by, status, recommendation, competency_ratings, strengths, concerns, notes)
  values (p_interview_id, auth.uid(), 'draft', p_recommendation, p_competency_ratings, p_strengths, p_concerns, p_notes)
  on conflict (interview_id) do update
    set recommendation = excluded.recommendation, competency_ratings = excluded.competency_ratings,
        strengths = excluded.strengths, concerns = excluded.concerns, notes = excluded.notes,
        status = case when interview_feedback.status = 'reopened' then 'reopened' else 'draft' end
  returning id into v_feedback_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interview_feedback', v_feedback_id, auth.uid(), 'feedback_draft_saved', jsonb_build_object('interview_id', p_interview_id), v_iv.entity_id, v_iv.location_id);

  return v_feedback_id;
end;
$$;

create or replace function public.submit_interview_feedback(p_interview_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_iv record;
  v_feedback record;
begin
  select iv.id, iv.cancelled_at, jr.entity_id, jr.location_id
    into v_iv
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id
      and iv.interviewer_id = auth.uid()
      and public.is_active_employee(my_employee_id())
      and jr.entity_id = my_entity();

  if v_iv.id is null then raise exception 'Interview not found or not accessible'; end if;
  if v_iv.cancelled_at is not null then raise exception 'Cannot submit feedback for a cancelled interview'; end if;

  select * into v_feedback from public.interview_feedback where interview_id = p_interview_id and submitted_by = auth.uid();
  if v_feedback.id is null then raise exception 'Save a draft before submitting'; end if;
  if v_feedback.status = 'submitted' then raise exception 'Feedback has already been submitted'; end if;
  if v_feedback.recommendation is null then raise exception 'A recommendation is required before submitting'; end if;

  update public.interview_feedback set status = 'submitted', submitted_at = now() where id = v_feedback.id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interview_feedback', v_feedback.id, auth.uid(), 'feedback_submitted', jsonb_build_object('interview_id', p_interview_id), v_iv.entity_id, v_iv.location_id);
end;
$$;

create or replace function public.log_candidate_file_access(p_interview_id uuid, p_file_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_count int;
  v_entity_id uuid;
begin
  select jr.entity_id into v_entity_id
    from public.candidate_files cf
    join public.job_applications ja on ja.candidate_id = cf.candidate_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where cf.id = p_file_id;

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
    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
    values ('candidate_files', p_file_id, auth.uid(), 'unauthorized_access_attempt', jsonb_build_object('interview_id', p_interview_id), v_entity_id);
    raise exception 'Not authorized to access this file';
  end if;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id)
  values ('candidate_files', p_file_id, auth.uid(), 'candidate_file_accessed', jsonb_build_object('interview_id', p_interview_id), v_entity_id);
end;
$$;

create or replace function public.run_payroll_calculation(p_payroll_run_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_status text;
  v_ot_confirmed boolean;
  v_tips_confirmed boolean;
  v_total_tips numeric;
  v_eligible_count int;
  v_tips_per_employee numeric;
  v_prior_snapshot jsonb;
begin
  select entity_id, status, overtime_holiday_pay_confirmed, tips_distribution_confirmed
    into v_entity_id, v_status, v_ot_confirmed, v_tips_confirmed
  from payroll_runs where id = p_payroll_run_id;

  if v_entity_id is null then raise exception 'Payroll run % not found', p_payroll_run_id; end if;
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity_id = my_entity())) then
    raise exception 'Not authorized to run payroll for this entity';
  end if;
  if v_status not in ('draft', 'in_review') then
    raise exception 'Payroll run % is % -- recalculation is blocked once a run is approved or paid. Create a revision run for corrections instead.', p_payroll_run_id, v_status;
  end if;

  select coalesce(sum(total_amount), 0) into v_total_tips from tips_pools where payroll_run_id = p_payroll_run_id;
  select count(*) into v_eligible_count from timesheet_entries where payroll_run_id = p_payroll_run_id;

  v_tips_per_employee := case when v_eligible_count = 0 or not v_tips_confirmed then 0 else v_total_tips / v_eligible_count end;

  select jsonb_agg(to_jsonb(p)) into v_prior_snapshot from payslips p where payroll_run_id = p_payroll_run_id;
  if v_prior_snapshot is not null then
    insert into audit_log(table_name, record_id, changed_by, action, old_value, entity_id)
    values ('payslips', p_payroll_run_id, auth.uid(), 'recalculate_draft', v_prior_snapshot, v_entity_id);
  end if;

  delete from payslips where payroll_run_id = p_payroll_run_id;

  insert into payslips (payroll_run_id, employee_id, base_pay, overtime_pay, holiday_pay, tips_share, total_deductions, net_pay)
  select p_payroll_run_id, t.employee_id, calc.base_pay, calc.overtime_pay, calc.holiday_pay, v_tips_per_employee,
    coalesce(d.total_deductions, 0),
    calc.base_pay + calc.overtime_pay + calc.holiday_pay + v_tips_per_employee - coalesce(d.total_deductions, 0)
  from timesheet_entries t
  join employee_compensation c on c.employee_id = t.employee_id
  cross join lateral (
    select
      case when c.pay_type = 'hourly' then t.regular_hours * coalesce(c.pay_rate, 0) else coalesce(c.pay_rate, 0) end as base_pay,
      case when c.pay_type = 'hourly' and v_ot_confirmed then t.overtime_hours * coalesce(c.pay_rate, 0) * c.overtime_multiplier else 0 end as overtime_pay,
      case when c.pay_type = 'hourly' and v_ot_confirmed then t.holiday_hours * coalesce(c.pay_rate, 0) * c.holiday_multiplier else 0 end as holiday_pay
  ) calc
  left join (
    select employee_id, sum(amount) as total_deductions from payslip_deductions where payroll_run_id = p_payroll_run_id group by employee_id
  ) d on d.employee_id = t.employee_id
  where t.payroll_run_id = p_payroll_run_id;

  insert into audit_log(table_name, record_id, changed_by, action, new_value, entity_id)
  values ('payroll_runs', p_payroll_run_id, auth.uid(), 'calculated',
    jsonb_build_object('overtime_holiday_pay_confirmed', v_ot_confirmed, 'tips_distribution_confirmed', v_tips_confirmed), v_entity_id);
end;
$$;

create or replace function public.set_entity_admin_self_approval(p_enabled boolean) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if my_role() <> 'owner' then raise exception 'Only the owner can change this setting'; end if;

  update public.app_settings set value = p_enabled, updated_by = auth.uid(), updated_at = now()
    where key = 'entity_admin_self_approval_enabled';

  -- app_settings is the one legitimate entity_id-less table (a global setting, not owned
  -- by any single entity) -- the audit_log_entity_id_required_check constraint explicitly
  -- allows this table_name with entity_id null.
  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('app_settings', gen_random_uuid(), auth.uid(), 'setting_changed',
    jsonb_build_object('key', 'entity_admin_self_approval_enabled', 'value', p_enabled));
end;
$$;
