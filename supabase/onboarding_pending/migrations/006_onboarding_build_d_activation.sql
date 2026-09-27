-- =====================================================================
-- Migration 006 — Build D: approve and activate (one transaction).
-- Readiness is recomputed on the server at the moment of approval; the
-- client's view of "ready" is never trusted. Everything below happens
-- or nothing does: status, start date, pay version, probation, day-one
-- tasks, notifications, audit. A retry after success returns the first
-- result (idempotent on activation_operation_id).
-- Depends on: 001–005, set_employee_status, payroll_set_compensation.
-- =====================================================================

begin;

create or replace function public.approve_and_activate_employee(p_instance_id uuid, p_expected_version integer, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  e public.employees;
  s public.onboarding_settings;
  c public.onboarding_pending_compensation;
  r jsonb;
  v_op uuid;
  v_start date;
  v_prob_end date;
  v_prob_id uuid;
  v_tasks integer;
  v_comp jsonb;
  v_mgr_user uuid;
  v_user uuid;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  perform public._onb_require(i.id, 'approve');

  -- Idempotent retry.
  if i.activation_operation_id is not null then
    return jsonb_build_object('ok', true, 'already_activated', true, 'operation_id', i.activation_operation_id,
      'employee_id', i.employee_id, 'status', i.status, 'activated_at', i.activated_at);
  end if;
  if i.status <> 'ready_for_activation' then
    -- Status may be stale; recompute once before refusing.
    perform public._onb_recompute(i.id);
    select * into i from public.onboarding_instances where id = p_instance_id;
  end if;
  if p_expected_version is distinct from i.row_version then
    raise exception 'This onboarding changed since you opened it; reload and check again' using errcode = '40001';
  end if;

  select * into e from public.employees where id = i.employee_id for update;
  if e.id = public.my_employee_id() then raise exception 'You cannot activate yourself' using errcode = '42501'; end if;
  if e.employment_status <> 'pre_boarding' then
    raise exception 'Employee is % (expected pre-boarding)', e.employment_status using errcode = '22023';
  end if;

  s := public._onb_settings(i.entity_id);
  select * into c from public.onboarding_pending_compensation where instance_id = i.id for update;
  if s.require_distinct_activation_approver and public.my_role() <> 'owner'
     and (c.set_by = auth.uid() or c.reviewed_by = auth.uid()) then
    raise exception 'You entered or reviewed this employee''s pay; a different approver must activate' using errcode = '42501';
  end if;

  r := public._onb_readiness(i.id, 'full');
  if not (r ->> 'ready')::boolean then
    raise exception 'Not ready to activate: %', (select string_agg(b ->> 'message', ' | ') from jsonb_array_elements(r -> 'blockers') b)
      using errcode = '22023', hint = 'Resolve the blocking items, then approve again.';
  end if;
  if i.status <> 'ready_for_activation' then
    raise exception 'Onboarding is % (expected ready for activation)', i.status using errcode = '22023';
  end if;

  v_op := public._onb_op();
  v_start := i.proposed_start_date;

  -- 1. Employee master: start date, then status through the existing gate
  --    (it re-checks the key documents). The flag lets 010's guard pass.
  update public.employees set join_date = v_start, home_location_id = i.home_location_id, position_id = i.position_id,
         employment_type = i.employment_type, reporting_manager_employee_id = i.reporting_manager_employee_id, updated_at = now()
   where id = e.id;
  perform set_config('app.onboarding_activation', i.id::text, true);
  perform public.set_employee_status(e.id, 'active', coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Activated from onboarding'));
  perform set_config('app.onboarding_activation', '', true);

  -- 2. Pay: the approved pending pay becomes the first compensation version.
  v_comp := public.payroll_set_compensation(e.id, coalesce(c.effective_from, v_start), c.pay_type, c.basic_monthly, c.hourly_rate,
    c.overtime_eligible, coalesce(c.reason, 'Starting pay (onboarding)'));

  -- 3. Probation (Decree-Law 33/2021 Art. 9: at most six months).
  if s.probation_months > 0 then
    v_prob_end := (v_start + make_interval(months => s.probation_months))::date - 1;
    insert into public.employee_probation_periods (employee_id, onboarding_instance_id, start_date, end_date, review_due_date)
    values (e.id, i.id, v_start, v_prob_end, greatest(v_start, v_prob_end - s.probation_review_days_before))
    on conflict do nothing
    returning id into v_prob_id;
    update public.employees set probation_end_date = v_prob_end where id = e.id;
  end if;

  -- 4. Day-one and first-weeks tasks.
  update public.onboarding_instances set actual_start_date = v_start where id = i.id;
  v_tasks := public._onb_generate_tasks(i.id, 'day_one') + public._onb_generate_tasks(i.id, 'initial_period');
  perform public._onb_sync_derived(i.id);  -- e.g. a policy already acknowledged completes its day-one task

  -- 5. Instance.
  perform public._onb_set_status(i.id, 'activated', p_reason);
  update public.onboarding_instances set activation_operation_id = v_op, activated_at = now(), activated_by = auth.uid(),
         activation_reason = nullif(btrim(coalesce(p_reason, '')), '') where id = i.id;

  -- 6. Notifications (deduped; no pay in any message).
  perform public.create_notification(i.entity_id, null, e.id, 'onboarding_activated', 'Welcome to the team',
    format('Your start date is %s. Your first-day checklist is in the app.', to_char(v_start, 'DD Mon YYYY')),
    'onboarding_instance', i.id, 'normal', format('onb:%s:activated:employee', i.id));
  select m.auth_user_id into v_mgr_user from public.employees m where m.id = i.reporting_manager_employee_id;
  if v_mgr_user is not null then
    perform public.create_notification(i.entity_id, v_mgr_user, null, 'onboarding_activated', 'New starter activated',
      format('%s starts on %s.', e.full_name, to_char(v_start, 'DD Mon YYYY')), 'onboarding_instance', i.id, 'normal',
      format('onb:%s:activated:manager', i.id));
  end if;
  for v_user in select p.id from public.profiles p where p.is_active and p.entity_id = i.entity_id and p.role = 'entity_admin'
                  and p.id <> auth.uid() loop
    perform public.create_notification(i.entity_id, v_user, null, 'onboarding_activated', 'New starter activated',
      format('%s starts on %s.', e.full_name, to_char(v_start, 'DD Mon YYYY')), 'onboarding_instance', i.id, 'normal',
      format('onb:%s:activated:hr:%s', i.id, v_user));
  end loop;

  perform public._onb_audit(i.id, 'employees', e.id, 'employee_activated', jsonb_build_object('employment_status', 'pre_boarding'),
    jsonb_build_object('employment_status', 'active', 'join_date', v_start, 'probation_end_date', v_prob_end,
      'probation_period_id', v_prob_id, 'compensation_version_id', v_comp ->> 'version_id', 'post_start_tasks', v_tasks,
      'readiness', r, 'reason', p_reason));

  return jsonb_build_object('ok', true, 'already_activated', false, 'operation_id', v_op, 'employee_id', e.id,
    'status', 'activated', 'join_date', v_start, 'probation_end_date', v_prob_end, 'post_start_tasks', v_tasks);
end;
$$;

revoke all on function public.approve_and_activate_employee(uuid, integer, text) from public, anon;
grant execute on function public.approve_and_activate_employee(uuid, integer, text) to authenticated;

commit;
