alter table public.workflow_rules drop constraint if exists workflow_rules_module_check;
alter table public.workflow_rules add constraint workflow_rules_module_check
  check (module = any (array['leave', 'document', 'attendance', 'schedule', 'payroll', 'recruitment', 'onboarding', 'offboarding']));

create or replace function public.workflow_trigger_catalog()
returns jsonb language sql immutable set search_path to '' as $$
  select jsonb_build_object(
    'leave', jsonb_build_object(
      'leave_submitted', jsonb_build_array('employee_id', 'location_id', 'leave_type_id', 'days_requested')),
    'document', jsonb_build_object(
      'document_expiring_soon', jsonb_build_array('employee_id', 'location_id', 'document_id', 'doc_type', 'expiry_date', 'days_to_expiry'),
      'submitted_for_review', jsonb_build_array('employee_id', 'location_id', 'document_id', 'doc_type', 'is_renewal')),
    'attendance', jsonb_build_object(
      'late_clock_in', jsonb_build_array('employee_id', 'location_id', 'shift_id', 'attendance_id', 'late_minutes')),
    'schedule', jsonb_build_object(
      'schedule_published', jsonb_build_array('employee_id', 'location_id', 'shift_date'),
      'shift_adjusted', jsonb_build_array('employee_id', 'previous_employee_id', 'location_id', 'shift_date', 'change_type')),
    'payroll', jsonb_build_object(
      'payslip_published', jsonb_build_array('employee_id', 'payroll_run_id', 'period_start', 'period_end', 'is_revision')),
    'recruitment', jsonb_build_object(),
    'onboarding', jsonb_build_object(
      'onboarding_started', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'source', 'proposed_start_date'),
      'onboarding_section_submitted', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'section'),
      'onboarding_changes_required', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id'),
      'onboarding_ready_for_activation', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'proposed_start_date'),
      'employee_activated', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'join_date'),
      'onboarding_task_overdue', jsonb_build_array('employee_id', 'location_id', 'onboarding_instance_id', 'task_id', 'owner_role', 'days_overdue'),
      'probation_review_due', jsonb_build_array('employee_id', 'location_id', 'probation_period_id', 'review_due_date', 'days_to_due'),
      'immigration_step_overdue', jsonb_build_array('employee_id', 'location_id', 'immigration_case_id', 'step_key', 'days_overdue')),
    'offboarding', jsonb_build_object(
      'offboarding_started', jsonb_build_array('employee_id', 'location_id', 'offboarding_case_id', 'separation_type', 'last_working_date'),
      'final_settlement_due', jsonb_build_array('employee_id', 'location_id', 'offboarding_case_id', 'settlement_due_date', 'days_to_due'))
  );
$$;

create or replace function public.trg_onb_workflow_status()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_event text;
begin
  v_event := case
    when tg_op = 'INSERT' then 'onboarding_started'
    when new.status = 'changes_required' and old.status <> 'changes_required' then 'onboarding_changes_required'
    when new.status = 'ready_for_activation' and old.status <> 'ready_for_activation' then 'onboarding_ready_for_activation'
    when new.status = 'activated' and old.status <> 'activated' then 'employee_activated'
    else null end;
  if v_event is null then return new; end if;
  begin
    perform public.evaluate_workflow_rules('onboarding', v_event, new.entity_id, 'onboarding_instances', new.id,
      jsonb_build_object('employee_id', new.employee_id, 'location_id', new.home_location_id, 'onboarding_instance_id', new.id,
                         'source', new.source, 'proposed_start_date', new.proposed_start_date,
                         'join_date', coalesce(new.actual_start_date, new.proposed_start_date)));
  exception when others then
    raise warning 'workflow % failed: %', v_event, sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists workflow_on_onboarding_status on public.onboarding_instances;
create trigger workflow_on_onboarding_status after insert or update of status on public.onboarding_instances
  for each row execute function public.trg_onb_workflow_status();

create or replace function public.trg_onb_workflow_section()
returns trigger language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances;
begin
  if new.status <> 'submitted' then return new; end if;
  select * into i from public.onboarding_instances where id = new.instance_id;
  begin
    perform public.evaluate_workflow_rules('onboarding', 'onboarding_section_submitted', i.entity_id, 'onboarding_section_submissions', new.id,
      jsonb_build_object('employee_id', i.employee_id, 'location_id', i.home_location_id, 'onboarding_instance_id', i.id, 'section', new.section));
  exception when others then
    raise warning 'workflow onboarding_section_submitted failed: %', sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists workflow_on_onboarding_section on public.onboarding_section_submissions;
create trigger workflow_on_onboarding_section after insert on public.onboarding_section_submissions
  for each row execute function public.trg_onb_workflow_section();

create or replace function public._onb_extension_reminders(p_today date)
returns integer language sql security definer set search_path to '' as $$ select 0; $$;

create or replace function public.onboarding_send_reminders()
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_expired integer := 0;
  v_sent integer := 0;
  r record;
  x record;
begin
  if auth.uid() is not null or coalesce(current_setting('request.jwt.claims', true), '') not in ('', 'null') then
    raise exception 'System job only' using errcode = '42501';
  end if;

  update public.onboarding_invitations set status = 'expired' where status = 'issued' and expires_at < now();
  get diagnostics v_expired = row_count;

  for r in select i.id, i.entity_id, i.employee_id, count(*) n, min(t.due_date) first_due
             from public.onboarding_instances i join public.onboarding_tasks t on t.instance_id = i.id
            where i.status in ('initiated', 'awaiting_employee', 'changes_required') and t.owner_role = 'employee'
              and t.is_required and t.status in ('not_started', 'in_progress', 'changes_required')
            group by i.id loop
    perform public.create_notification(r.entity_id, null, r.employee_id, 'onboarding_reminder', 'Finish your onboarding',
      format('%s item(s) left%s.', r.n, case when r.first_due < v_today then ', some overdue' else '' end),
      'onboarding_instance', r.id, case when r.first_due < v_today then 'high' else 'normal' end,
      format('onb:%s:remind:employee:%s', r.id, v_today));
    v_sent := v_sent + 1;
  end loop;

  for r in select i.entity_id, i.home_location_id, t.owner_role, count(*) n, max(v_today - t.due_date) worst,
                  (array_agg(i.id order by t.due_date))[1] first_instance
             from public.onboarding_tasks t join public.onboarding_instances i on i.id = t.instance_id
            where t.status not in ('approved', 'waived', 'cancelled', 'submitted') and t.due_date < v_today
              and t.owner_role <> 'employee' and i.status not in ('completed', 'cancelled', 'withdrawn')
            group by 1, 2, 3 loop
    for x in select p.id from public.profiles p
              where p.is_active and ((r.owner_role = 'location_manager' and p.role = 'location_manager' and p.location_id = r.home_location_id)
                 or (p.role = 'entity_admin' and p.entity_id = r.entity_id
                     and (r.owner_role in ('hr', 'approver', 'payroll') or r.worst >= 2))) loop
      perform public.create_notification(r.entity_id, x.id, null, 'onboarding_task_overdue', 'Onboarding tasks overdue',
        format('%s overdue %s task(s), oldest %s day(s).', r.n, replace(r.owner_role, '_', ' '), r.worst),
        'onboarding_instance', r.first_instance, case when r.worst >= 2 then 'high' else 'normal' end,
        format('onb:overdue:%s:%s:%s:%s', r.home_location_id, r.owner_role, x.id, v_today));
      v_sent := v_sent + 1;
    end loop;
    begin
      perform public.evaluate_workflow_rules('onboarding', 'onboarding_task_overdue', r.entity_id, 'onboarding_instances', r.first_instance,
        jsonb_build_object('location_id', r.home_location_id, 'onboarding_instance_id', r.first_instance, 'owner_role', r.owner_role,
                           'days_overdue', r.worst));
    exception when others then raise warning 'workflow onboarding_task_overdue failed: %', sqlerrm;
    end;
  end loop;

  for r in select pp.id, pp.employee_id, pp.review_due_date, e.entity_id, e.home_location_id
             from public.employee_probation_periods pp join public.employees e on e.id = pp.employee_id
            where pp.status = 'active' and e.employment_status = 'active'
              and pp.review_due_date in (v_today, v_today + 7) loop
    begin
      perform public.evaluate_workflow_rules('onboarding', 'probation_review_due', r.entity_id, 'employee_probation_periods', r.id,
        jsonb_build_object('employee_id', r.employee_id, 'location_id', r.home_location_id, 'probation_period_id', r.id,
                           'review_due_date', r.review_due_date, 'days_to_due', r.review_due_date - v_today));
    exception when others then raise warning 'workflow probation_review_due failed: %', sqlerrm;
    end;
  end loop;

  v_sent := v_sent + public._onb_extension_reminders(v_today);

  return jsonb_build_object('ok', true, 'invitations_expired', v_expired, 'notifications', v_sent, 'run_at', now());
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['trg_onb_workflow_status()', 'trg_onb_workflow_section()', 'onboarding_send_reminders()',
    '_onb_extension_reminders(date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;;
