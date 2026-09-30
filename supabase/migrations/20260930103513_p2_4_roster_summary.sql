-- P2-4: "Why this roster" — the roster-assistant Edge Function stores each AI summary of an auto-schedule
-- preview here, with its inputs and model. Same access as the auto-scheduler itself.
alter table public.ai_suggestions drop constraint ai_suggestions_kind_check;
alter table public.ai_suggestions add constraint ai_suggestions_kind_check check (kind in ('cover_offer', 'roster_summary'));

create or replace function public.log_roster_summary(p_entity_id uuid, p_inputs jsonb, p_output jsonb, p_model text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  v_id uuid;
begin
  if auth.uid() is null or v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'Not authorized to plan schedules for this company';
  end if;
  insert into public.ai_suggestions (entity_id, location_id, kind, target_type, target_id, inputs, output, model)
  values (p_entity_id, case when v_role = 'location_manager' then public.my_location() end, 'roster_summary',
          'entities', p_entity_id, coalesce(p_inputs, '{}'::jsonb), coalesce(p_output, '{}'::jsonb), p_model)
  returning id into v_id;
  return v_id;
end;
$function$;
revoke all on function public.log_roster_summary(uuid, jsonb, jsonb, text) from public, anon;
grant execute on function public.log_roster_summary(uuid, jsonb, jsonb, text) to authenticated;
