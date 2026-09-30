-- Activate a new starter before their onboarding is complete (owner / company admin only).
-- activate_employee_with_open_items runs the normal approve_and_activate_employee flow but lets it pass
-- while documents, tasks, pay review or contract acceptance are still open. It never skips the basics
-- that activation cannot work without: home branch, a sensible start date, and no duplicate person.
-- Starting pay is applied only if payroll has approved it (otherwise payroll readiness shows "No pay set").
-- The instance is flagged; the open items stay on the onboarding, the employee keeps getting reminders,
-- HR gets a weekly summary and a banner/tab in Onboarding until everything is done.

alter table public.onboarding_instances
  add column activated_with_open_items boolean not null default false,
  add column open_items_at_activation jsonb,
  add column open_items_cleared_at timestamptz;

-- Open items for an instance (same sources as readiness, minus the structural checks). Side-effect free.
create or replace function public._onb_open_items(p_instance_id uuid)
returns integer
language sql
stable
security definer
set search_path to ''
as $function$
  select
    (select count(*) from public.onboarding_tasks t
      where t.instance_id = i.id and t.phase = 'pre_activation' and t.is_required
        and t.status not in ('approved', 'waived', 'cancelled'))::int
    + (select count(*) from public.onboarding_exceptions x where x.instance_id = i.id and x.status = 'open' and x.is_blocking)::int
    + case when cardinality(public.employee_missing_key_documents(i.employee_id)) > 0 then 1 else 0 end
    + case when not exists (select 1 from public.onboarding_pending_compensation c
                             where c.instance_id = i.id and c.status = 'approved') then 1 else 0 end
    + case when not exists (select 1 from public.employee_contract_acceptances a
                              join public.employee_documents d on d.id = a.document_id
                             where a.onboarding_instance_id = i.id and d.is_current and d.review_status = 'approved') then 1 else 0 end
  from public.onboarding_instances i where i.id = p_instance_id;
$function$;
revoke all on function public._onb_open_items(uuid) from public, anon, authenticated;

-- approve_and_activate_employee: allow the override path when called from activate_employee_with_open_items.
do $patch$
declare
  v_def text := pg_get_functiondef('public.approve_and_activate_employee(uuid, integer, text)'::regprocedure);
  v_new text := v_def;
  v_parts text[][] := array[
    array[$a$  r := public._onb_readiness(i.id, 'full');
  if not (r ->> 'ready')::boolean then$a$,
          $a$  r := public._onb_readiness(i.id, 'full');
  v_override := coalesce(current_setting('app.onboarding_override', true), '') = i.id::text;
  if v_override then
    if exists (select 1 from jsonb_array_elements(r -> 'blockers') bl
                where bl ->> 'code' in ('no_branch', 'no_start_date', 'start_date_invalid', 'duplicate_identity')) then
      raise exception 'Cannot activate yet: %', (select string_agg(bl ->> 'message', ' | ') from jsonb_array_elements(r -> 'blockers') bl
                                                  where bl ->> 'code' in ('no_branch', 'no_start_date', 'start_date_invalid', 'duplicate_identity'))
        using errcode = '22023', hint = 'These must be fixed even when activating with open items.';
    end if;
  elsif not (r ->> 'ready')::boolean then$a$],
    array[$a$  if i.status <> 'ready_for_activation' then
    raise exception 'Onboarding is % (expected ready for activation)', i.status using errcode = '22023';
  end if;$a$,
          $a$  if i.status <> 'ready_for_activation' and not v_override then
    raise exception 'Onboarding is % (expected ready for activation)', i.status using errcode = '22023';
  end if;
  if v_override and i.status not in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation') then
    raise exception 'Onboarding is % and cannot be activated', i.status using errcode = '22023';
  end if;$a$],
    array[$a$  v_comp := public.payroll_set_compensation($a$,
          $a$  -- Starting pay only once payroll has approved it (always true on the normal path).
  if c.instance_id is not null and c.status = 'approved' then
  v_comp := public.payroll_set_compensation($a$],
    array[$a$    c.overtime_eligible, coalesce(c.reason, 'Starting pay (onboarding)'));
$a$,
          $a$    c.overtime_eligible, coalesce(c.reason, 'Starting pay (onboarding)'));
  end if;
$a$],
    array[$a$  perform public._onb_set_status(i.id, 'activated', p_reason);$a$,
          $a$  if v_override and i.status <> 'ready_for_activation' then
    update public.onboarding_instances
       set status = 'activated', status_changed_at = now(), row_version = row_version + 1, updated_at = now()
     where id = i.id;
    perform public._onb_audit(i.id, 'onboarding_instances', i.id, 'onboarding_status_changed',
      jsonb_build_object('status', i.status), jsonb_build_object('status', 'activated', 'reason', p_reason, 'open_items', r -> 'blockers'));
  else
    perform public._onb_set_status(i.id, 'activated', p_reason);
  end if;
  if v_override then
    update public.onboarding_instances
       set activated_with_open_items = true, open_items_at_activation = r -> 'blockers', open_items_cleared_at = null
     where id = i.id;
  end if;$a$],
    array[$a$  v_user uuid;
begin$a$, $a$  v_user uuid;
  v_override boolean := false;
begin$a$]
  ];
  k int;
begin
  for k in 1 .. array_length(v_parts, 1) loop
    if position(v_parts[k][1] in v_new) = 0 then
      raise exception 'approve_and_activate_employee patch point % not found', k;
    end if;
    v_new := replace(v_new, v_parts[k][1], v_parts[k][2]);
  end loop;
  execute v_new;
end
$patch$;

-- set_employee_status: the override path may activate before readiness and key documents are complete.
do $patch$
declare
  v_def text := pg_get_functiondef('public.set_employee_status(uuid, public.employee_status, text)'::regprocedure);
  v_new text := v_def;
  v_parts text[][] := array[
    array[$a$         and oi.id::text = coalesce(current_setting('app.onboarding_activation', true), '')
         and oi.status = 'ready_for_activation'$a$,
          $a$         and oi.id::text = coalesce(current_setting('app.onboarding_activation', true), '')
         and (oi.status = 'ready_for_activation'
              or oi.id::text = coalesce(current_setting('app.onboarding_override', true), ''))$a$],
    array[$a$  if p_new_status = 'active' then
    v_missing_docs := public.employee_missing_key_documents(p_employee_id);$a$,
          $a$  if p_new_status = 'active' and not exists (
       select 1 from public.onboarding_instances oo
        where oo.employee_id = p_employee_id
          and oo.id::text = coalesce(current_setting('app.onboarding_override', true), '')) then
    v_missing_docs := public.employee_missing_key_documents(p_employee_id);$a$]
  ];
  k int;
begin
  for k in 1 .. array_length(v_parts, 1) loop
    if position(v_parts[k][1] in v_new) = 0 then
      raise exception 'set_employee_status patch point % not found', k;
    end if;
    v_new := replace(v_new, v_parts[k][1], v_parts[k][2]);
  end loop;
  execute v_new;
end
$patch$;

create or replace function public.activate_employee_with_open_items(p_instance_id uuid, p_expected_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  i public.onboarding_instances;
  v_name text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_res jsonb;
  v_open int;
  v_user uuid;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.id is null then
    raise exception using errcode = 'P0002', message = 'Onboarding not found';
  end if;
  if not (v_role = 'owner' or (v_role = 'entity_admin' and i.entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'Only the owner or a company admin can activate with open items';
  end if;
  if v_reason is null then
    raise exception using errcode = '22023', message = 'Give a reason for activating before onboarding is complete';
  end if;

  perform set_config('app.onboarding_override', i.id::text, true);
  v_res := public.approve_and_activate_employee(p_instance_id, p_expected_version, 'Activated with open items: ' || v_reason);
  perform set_config('app.onboarding_override', '', true);

  v_open := coalesce(public._onb_open_items(i.id), 0);
  select full_name into v_name from public.employees where id = i.employee_id;

  if v_open > 0 then
    perform public.create_notification(i.entity_id, null, i.employee_id, 'onboarding_open_items',
      'Please finish your onboarding',
      format('You''re active, but %s onboarding item(s) are still open (documents, forms or contract). Complete them in the app.', v_open),
      'onboarding_instance', i.id, 'high', format('onb:%s:open_items:employee', i.id));
    for v_user in
      select p.id from public.profiles p
       where p.is_active and p.id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)
         and (p.role = 'owner' or (p.role = 'entity_admin' and p.entity_id = i.entity_id))
    loop
      perform public.create_notification(i.entity_id, v_user, null, 'onboarding_open_items',
        'Activated with onboarding open',
        format('%s was activated with %s onboarding item(s) still open. Reason: %s', v_name, v_open, v_reason),
        'onboarding_instance', i.id, 'normal', format('onb:%s:open_items:hr:%s', i.id, v_user));
    end loop;
  end if;

  return v_res || jsonb_build_object('open_items', v_open);
end;
$function$;
revoke all on function public.activate_employee_with_open_items(uuid, integer, text) from public, anon;
grant execute on function public.activate_employee_with_open_items(uuid, integer, text) to authenticated, service_role;

-- Dashboard + list: count and show people activated with items still open.
do $patch$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.onboarding_dashboard_summary(uuid)'::regprocedure);
  if position($a$    'ready_for_activation', count(*) filter (where status = 'ready_for_activation'),$a$ in v_def) = 0 then
    raise exception 'onboarding_dashboard_summary patch point not found';
  end if;
  execute replace(v_def, $a$    'ready_for_activation', count(*) filter (where status = 'ready_for_activation'),$a$,
    $a$    'ready_for_activation', count(*) filter (where status = 'ready_for_activation'),
    'activated_incomplete', count(*) filter (where activated_with_open_items and status not in ('cancelled', 'withdrawn')
                                              and public._onb_open_items(id) > 0),$a$);

  v_def := pg_get_functiondef('public.list_onboarding(uuid, text)'::regprocedure);
  if position($a$          'row_version', i.row_version,$a$ in v_def) = 0
     or position($a$                 when 'in_progress' then$a$ in v_def) = 0 then
    raise exception 'list_onboarding patch point not found';
  end if;
  v_def := replace(v_def, $a$          'row_version', i.row_version,$a$,
    $a$          'row_version', i.row_version,
          'activated_with_open_items', i.activated_with_open_items,
          'open_items', case when i.activated_with_open_items then public._onb_open_items(i.id) end,$a$);
  v_def := replace(v_def, $a$                 when 'in_progress' then$a$,
    $a$                 when 'incomplete' then i.activated_with_open_items and i.status not in ('cancelled', 'withdrawn')
                                        and public._onb_open_items(i.id) > 0
                 when 'in_progress' then$a$);
  execute v_def;
end
$patch$;

-- Reminders: employees activated with open items keep getting daily reminders; HR gets a Monday summary;
-- when everything is done the flag clears and HR is told once.
do $patch$
declare
  v_def text := pg_get_functiondef('public.onboarding_send_reminders()'::regprocedure);
  v_new text := v_def;
begin
  if position($a$            where i.status in ('initiated', 'awaiting_employee', 'changes_required') and t.owner_role = 'employee'$a$ in v_new) = 0
     or position($a$  return jsonb_build_object('ok', true, 'invitations_expired', v_expired,$a$ in v_new) = 0 then
    raise exception 'onboarding_send_reminders patch point not found';
  end if;
  v_new := replace(v_new, $a$            where i.status in ('initiated', 'awaiting_employee', 'changes_required') and t.owner_role = 'employee'$a$,
    $a$            where (i.status in ('initiated', 'awaiting_employee', 'changes_required')
                   or (i.activated_with_open_items and i.open_items_cleared_at is null
                       and i.status not in ('completed', 'cancelled', 'withdrawn')))
              and t.owner_role = 'employee'$a$);
  v_new := replace(v_new, $a$  return jsonb_build_object('ok', true, 'invitations_expired', v_expired,$a$,
    $a$  -- Activated with open items: clear the flag once everything is done; otherwise a Monday summary to HR.
  for r in select i.id, i.entity_id, e.full_name from public.onboarding_instances i join public.employees e on e.id = i.employee_id
            where i.activated_with_open_items and i.open_items_cleared_at is null and public._onb_open_items(i.id) = 0 loop
    update public.onboarding_instances set open_items_cleared_at = now() where id = r.id;
    for x in select p.id from public.profiles p where p.is_active and (p.role = 'owner' or (p.role = 'entity_admin' and p.entity_id = r.entity_id)) loop
      perform public.create_notification(r.entity_id, x.id, null, 'onboarding_open_items', 'Onboarding items complete',
        format('%s has now finished the onboarding items that were open at activation.', r.full_name),
        'onboarding_instance', r.id, 'normal', format('onb:%s:open_items_cleared:%s', r.id, x.id));
      v_sent := v_sent + 1;
    end loop;
  end loop;
  if extract(isodow from v_today) = 1 then
    for r in select i.entity_id, count(*) n, (array_agg(i.id order by i.activated_at))[1] first_instance,
                    string_agg(e.full_name, ', ' order by e.full_name) names
               from public.onboarding_instances i join public.employees e on e.id = i.employee_id
              where i.activated_with_open_items and i.open_items_cleared_at is null
                and i.status not in ('completed', 'cancelled', 'withdrawn')
              group by i.entity_id loop
      for x in select p.id from public.profiles p where p.is_active and (p.role = 'owner' or (p.role = 'entity_admin' and p.entity_id = r.entity_id)) loop
        perform public.create_notification(r.entity_id, x.id, null, 'onboarding_open_items',
          format('%s staff working with onboarding not finished', r.n),
          format('Activated before onboarding was complete: %s. Open Onboarding → Incomplete.', r.names),
          'onboarding_instance', r.first_instance, 'normal', format('onb:open_items:weekly:%s:%s:%s', r.entity_id, x.id, v_today));
        v_sent := v_sent + 1;
      end loop;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'invitations_expired', v_expired,$a$);
  execute v_new;
end
$patch$;
