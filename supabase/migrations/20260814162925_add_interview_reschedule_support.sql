
-- Closes the "no reschedule RPC" known limitation documented for My
-- Interviews/Recruiting: previously a cancelled interview just stayed
-- cancelled, and scheduling a follow-up meant manually creating a brand
-- new, unlinked interviews row. rescheduled_from_interview_id links the
-- new row back to the one it replaces (mirrors the
-- supersedes_document_id pattern already used for document renewals), so
-- the reschedule chain is visible without any extra querying.
alter table public.interviews
  add column rescheduled_from_interview_id uuid references public.interviews(id);

create index if not exists interviews_rescheduled_from_idx
  on public.interviews (rescheduled_from_interview_id)
  where rescheduled_from_interview_id is not null;

-- reschedule_interview(): atomically cancels the source interview (if not
-- already cancelled) and creates a new interview row in the same stage,
-- carrying over the interviewer/format/meeting_location unless the caller
-- explicitly overrides them. Re-checks the same authorization
-- cancel_interview() already enforces (owner any; entity_admin own
-- entity; location_manager own location) rather than trusting the RLS
-- grant on a raw insert, and blocks rescheduling an interview a second
-- time from the same source row (idempotency: only one reschedule chain
-- per source interview, so a duplicate click can't spawn two follow-ups).
create or replace function public.reschedule_interview(
  p_interview_id uuid,
  p_new_scheduled_at timestamptz,
  p_new_interviewer_id uuid default null,
  p_format text default null,
  p_meeting_location text default null,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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

  if v_old.application_id is null then
    raise exception 'Interview % not found', p_interview_id;
  end if;

  v_entity_id := v_old.entity_id;
  v_location_id := v_old.location_id;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then
    raise exception 'Not authorized to reschedule this interview';
  end if;

  if exists (select 1 from public.interviews where rescheduled_from_interview_id = p_interview_id) then
    raise exception 'Interview % has already been rescheduled', p_interview_id;
  end if;

  if v_old.cancelled_at is null then
    update public.interviews
      set cancelled_at = now(), cancelled_by = auth.uid(),
          cancellation_reason = coalesce(p_reason, 'Rescheduled')
      where id = p_interview_id;
  end if;

  insert into public.interviews (
    application_id, stage_id, scheduled_at, interviewer_id, outcome, format, meeting_location,
    rescheduled_from_interview_id
  ) values (
    v_old.application_id, v_old.stage_id, p_new_scheduled_at,
    coalesce(p_new_interviewer_id, v_old.interviewer_id), 'pending',
    coalesce(p_format, v_old.format), coalesce(p_meeting_location, v_old.meeting_location),
    p_interview_id
  )
  returning id into v_new_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('interviews', v_new_id, auth.uid(), 'interview_rescheduled',
    jsonb_build_object('rescheduled_from', p_interview_id, 'reason', p_reason));

  return v_new_id;
end;
$function$;

revoke all on function public.reschedule_interview(uuid, timestamptz, uuid, text, text, text) from public, anon;
grant execute on function public.reschedule_interview(uuid, timestamptz, uuid, text, text, text) to authenticated;

