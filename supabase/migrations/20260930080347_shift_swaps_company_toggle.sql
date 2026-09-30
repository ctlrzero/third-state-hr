-- Shift swaps can be switched on or off per company (owner request 2026-09-30).
--
-- Setting: app_settings key 'shift_swaps_enabled:<entity_id>'; no row = on
-- (the previous behaviour). Owner or entity admin of that company can change it.
-- When off:
--   - request_shift_swap and claim_shift_swap refuse (22023)
--   - staff no longer see the open swap board (_open_swap_in_staff_scope)
--   - the staff screen hides all swap controls (UI reads shift_swaps_enabled)
-- Swaps already open or claimed stay visible to managers/admins, who can still
-- approve or reject them.

create or replace function public.shift_swaps_enabled(p_entity_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((select s.value from public.app_settings s where s.key = 'shift_swaps_enabled:' || p_entity_id::text), true);
$$;
revoke all on function public.shift_swaps_enabled(uuid) from public, anon;
grant execute on function public.shift_swaps_enabled(uuid) to authenticated;

create or replace function public.set_shift_swaps_enabled(p_entity_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_old boolean;
begin
  if not exists (select 1 from public.entities where id = p_entity_id) then
    raise exception using errcode = 'P0002', message = 'Company not found';
  end if;
  perform public._require_entity_admin(p_entity_id);
  v_old := public.shift_swaps_enabled(p_entity_id);
  insert into public.app_settings (key, value, updated_by, updated_at)
  values ('shift_swaps_enabled:' || p_entity_id::text, coalesce(p_enabled, true), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id)
  values ('app_settings', p_entity_id, auth.uid(), 'shift_swaps_enabled_set',
    jsonb_build_object('enabled', v_old), jsonb_build_object('enabled', coalesce(p_enabled, true)), p_entity_id);
end;
$$;
revoke all on function public.set_shift_swaps_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_shift_swaps_enabled(uuid, boolean) to authenticated;

do $patch$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('public.request_shift_swap(uuid, text)'::regprocedure);
  v_new := replace(v_def,
    E'  if v_shift.id is null then raise exception ''Shift not found or not assigned to you''; end if;\n',
    E'  if v_shift.id is null then raise exception ''Shift not found or not assigned to you''; end if;\n'
    || E'  if not public.shift_swaps_enabled(v_shift.entity_id) then\n'
    || E'    raise exception using errcode = ''22023'', message = ''Shift swaps are turned off for your company'';\n'
    || E'  end if;\n');
  if v_new = v_def then raise exception 'request_shift_swap: insertion point not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('public.claim_shift_swap(uuid)'::regprocedure);
  v_new := replace(v_def,
    E'  if v_shift.status = ''cancelled'' then raise exception ''Cannot claim a swap for a cancelled shift''; end if;\n',
    E'  if v_shift.status = ''cancelled'' then raise exception ''Cannot claim a swap for a cancelled shift''; end if;\n'
    || E'  if not public.shift_swaps_enabled(v_shift.entity_id) then\n'
    || E'    raise exception using errcode = ''22023'', message = ''Shift swaps are turned off for your company'';\n'
    || E'  end if;\n');
  if v_new = v_def then raise exception 'claim_shift_swap: insertion point not found'; end if;
  execute v_new;
end
$patch$;

create or replace function public._open_swap_in_staff_scope(p_shift_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.shifts s
     where s.id = p_shift_id and s.status <> 'cancelled' and s.is_published
       and public.shift_swaps_enabled(s.entity_id)
       and exists (select 1 from public.shift_swap_requests r where r.shift_id = s.id and r.status = 'open')
       and public._staff_can_claim_at(s.entity_id, s.location_id));
$$;
