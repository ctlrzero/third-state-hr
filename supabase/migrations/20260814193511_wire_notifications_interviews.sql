
create or replace function public.cancel_interview(p_interview_id uuid, p_reason text) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
  v_interviewer_id uuid;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'A cancellation reason is required'; end if;

  select jr.entity_id, jr.location_id, iv.interviewer_id into v_entity_id, v_location_id, v_interviewer_id
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id;

  if v_entity_id is null then raise exception 'Interview % not found', p_interview_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then raise exception 'Not authorized to cancel this interview'; end if;

  update public.interviews set cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_interview_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interviews', p_interview_id, auth.uid(), 'interview_cancelled', jsonb_build_object('reason', p_reason), v_entity_id, v_location_id);

  if v_interviewer_id is not null and v_interviewer_id <> auth.uid() then
    perform public.create_notification(
      v_entity_id, v_interviewer_id, null, 'interview_cancelled', 'Interview cancelled',
      format('An interview you were assigned to has been cancelled: %s', p_reason),
      'interviews', p_interview_id, 'high', 'interview_cancelled:' || p_interview_id::text
    );
  end if;
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
  v_final_interviewer uuid;
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

  v_final_interviewer := coalesce(p_new_interviewer_id, v_old.interviewer_id);

  insert into public.interviews (
    application_id, stage_id, scheduled_at, interviewer_id, outcome, format, meeting_location, rescheduled_from_interview_id
  ) values (
    v_old.application_id, v_old.stage_id, p_new_scheduled_at, v_final_interviewer, 'pending',
    coalesce(p_format, v_old.format), coalesce(p_meeting_location, v_old.meeting_location), p_interview_id
  ) returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interviews', v_new_id, auth.uid(), 'interview_rescheduled', jsonb_build_object('rescheduled_from', p_interview_id, 'reason', p_reason), v_entity_id, v_location_id);

  if v_final_interviewer is not null and v_final_interviewer <> auth.uid() then
    perform public.create_notification(
      v_entity_id, v_final_interviewer, null, 'interview_rescheduled', 'Interview rescheduled',
      format('An interview has been rescheduled to %s.', p_new_scheduled_at),
      'interviews', v_new_id, 'high', 'interview_rescheduled:' || v_new_id::text
    );
  end if;

  return v_new_id;
end;
$$;

revoke all on function public.cancel_interview(uuid, text) from public, anon;
grant execute on function public.cancel_interview(uuid, text) to authenticated;
revoke all on function public.reschedule_interview(uuid, timestamptz, uuid, text, text, text) from public, anon;
grant execute on function public.reschedule_interview(uuid, timestamptz, uuid, text, text, text) to authenticated;

-- New interview scheduled (freshly created, not via reschedule -- reschedule already sends
-- its own more specific notification, so skip when rescheduled_from_interview_id is set).
create or replace function public.notify_new_interview() returns trigger
security definer set search_path to 'public', 'pg_temp'
language plpgsql
as $$
declare
  v_entity_id uuid;
begin
  if new.rescheduled_from_interview_id is not null then
    return new;
  end if;
  if new.interviewer_id is null then
    return new;
  end if;
  select jr.entity_id into v_entity_id
    from public.job_applications ja join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = new.application_id;

  if v_entity_id is not null and new.interviewer_id <> auth.uid() then
    perform public.create_notification(
      v_entity_id, new.interviewer_id, null, 'interview_scheduled', 'New interview assigned',
      format('You have been assigned an interview on %s.', new.scheduled_at),
      'interviews', new.id, 'normal', 'interview_scheduled:' || new.id::text
    );
  end if;
  return new;
end;
$$;

revoke all on function public.notify_new_interview() from public, anon, authenticated;

drop trigger if exists trg_notify_new_interview on public.interviews;
create trigger trg_notify_new_interview
  after insert on public.interviews
  for each row execute function public.notify_new_interview();

