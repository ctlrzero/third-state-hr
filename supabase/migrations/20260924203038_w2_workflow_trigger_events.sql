-- ============================================================
-- W2 Workflow trigger events.
--  New events: attendance/late_clock_in, document/submitted_for_review,
--  payroll/payslip_published, schedule/shift_adjusted.
--  * workflow_trigger_catalog(): the single source of truth for the
--    allowed module -> trigger_event -> condition_field lists; the
--    create RPC validates against it.
--  * Owner support: the rule RPCs take an optional p_entity_id (owner
--    has no home entity); entity_admin is always pinned to own entity.
--  * evaluate_workflow_rules is internal-only (no client EXECUTE),
--    notifies only ACTIVE profiles, and scopes location_manager/staff
--    role notifications to the event's location.
--  * Event data never carries pay amounts, bank data or document
--    numbers - only ids, dates, types and minute counts.
--  * The staff "payslip available" notification now fires when a run
--    is approved (published), not when a draft is calculated.
-- ============================================================

create or replace function public.workflow_trigger_catalog()
returns jsonb
language sql immutable
set search_path = ''
as $$
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
    'recruitment', jsonb_build_object()
  );
$$;

revoke all on function public.workflow_trigger_catalog() from public, anon;
grant execute on function public.workflow_trigger_catalog() to authenticated;

-- ------------------------------------------------------------
-- Visibility: owner sees every entity's rules/runs.
-- ------------------------------------------------------------
drop policy if exists workflow_rules_select on public.workflow_rules;
create policy workflow_rules_select on public.workflow_rules
  for select using (
    (select public.my_role()) = 'owner'::public.user_role
    or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  );

drop policy if exists workflow_runs_select on public.workflow_runs;
create policy workflow_runs_select on public.workflow_runs
  for select using (
    (select public.my_role()) = 'owner'::public.user_role
    or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  );

-- Internal: resolve the entity a rule RPC acts on.
create or replace function public._workflow_scope_entity(p_entity_id uuid)
returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
begin
  if v_role = 'owner' then
    if p_entity_id is null then
      raise exception 'Owner must specify p_entity_id' using errcode = '22023';
    end if;
    if not exists (select 1 from public.entities e where e.id = p_entity_id) then
      raise exception 'Entity not found' using errcode = 'P0002';
    end if;
    return p_entity_id;
  elsif v_role = 'entity_admin' then
    if p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
      raise exception 'Entity admins can only manage their own entity''s workflow rules' using errcode = '42501';
    end if;
    return public.my_entity();
  end if;
  raise exception 'Only owner/entity_admin can manage workflow rules' using errcode = '42501';
end;
$$;

revoke all on function public._workflow_scope_entity(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Rule management
-- ------------------------------------------------------------
drop function if exists public.create_workflow_rule(text, text, text, text, text, text, text, public.user_role, text);

create or replace function public.create_workflow_rule(
  p_name text,
  p_module text,
  p_trigger_event text,
  p_condition_field text,
  p_condition_operator text,
  p_condition_value text,
  p_action_type text,
  p_action_target_role public.user_role,
  p_action_message_template text,
  p_entity_id uuid default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entity uuid := public._workflow_scope_entity(p_entity_id);
  v_catalog jsonb := public.workflow_trigger_catalog();
  v_id uuid;
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'Rule name is required' using errcode = '22023';
  end if;
  if nullif(btrim(p_action_message_template), '') is null then
    raise exception 'A notification message is required' using errcode = '22023';
  end if;
  if not (v_catalog ? p_module) then
    raise exception 'Unknown module %', p_module using errcode = '22023';
  end if;
  if not ((v_catalog -> p_module) ? p_trigger_event) then
    raise exception 'Trigger % is not available for module %', p_trigger_event, p_module using errcode = '22023';
  end if;
  if p_condition_field is not null and not ((v_catalog -> p_module -> p_trigger_event) ? p_condition_field) then
    raise exception 'Condition field % is not available for trigger %', p_condition_field, p_trigger_event using errcode = '22023';
  end if;
  if p_action_type = 'notify_role' and p_action_target_role is null then
    raise exception 'notify_role requires a target role' using errcode = '22023';
  end if;
  if p_action_type = 'notify_employee' and p_action_target_role is not null then
    raise exception 'notify_employee does not take a target role' using errcode = '22023';
  end if;

  insert into public.workflow_rules(
    entity_id, name, module, trigger_event,
    condition_field, condition_operator, condition_value,
    action_type, action_target_role, action_message_template, created_by
  ) values (
    v_entity, btrim(p_name), p_module, p_trigger_event,
    p_condition_field, p_condition_operator, p_condition_value,
    p_action_type, p_action_target_role, btrim(p_action_message_template), auth.uid()
  ) returning id into v_id;

  insert into public.audit_log(table_name, record_id, changed_by, action, new_value, entity_id)
  values ('workflow_rules', v_id, auth.uid(), 'create',
          jsonb_build_object('name', p_name, 'module', p_module, 'trigger_event', p_trigger_event,
                             'condition_field', p_condition_field, 'condition_operator', p_condition_operator,
                             'condition_value', p_condition_value, 'action_type', p_action_type,
                             'action_target_role', p_action_target_role),
          v_entity);

  return v_id;
end;
$$;

create or replace function public.activate_workflow_rule(p_rule_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entity uuid;
begin
  select entity_id into v_entity from public.workflow_rules where id = p_rule_id;
  if v_entity is null or not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and v_entity = public.my_entity())) then
    raise exception 'Not authorized to activate this rule' using errcode = '42501';
  end if;

  update public.workflow_rules
    set is_active = true, activated_at = now(), deactivated_at = null, updated_at = now()
    where id = p_rule_id;

  insert into public.audit_log(table_name, record_id, changed_by, action, entity_id)
  values ('workflow_rules', p_rule_id, auth.uid(), 'activate', v_entity);
end;
$$;

create or replace function public.deactivate_workflow_rule(p_rule_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entity uuid;
begin
  select entity_id into v_entity from public.workflow_rules where id = p_rule_id;
  if v_entity is null or not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and v_entity = public.my_entity())) then
    raise exception 'Not authorized to deactivate this rule' using errcode = '42501';
  end if;

  update public.workflow_rules
    set is_active = false, deactivated_at = now(), updated_at = now()
    where id = p_rule_id;

  insert into public.audit_log(table_name, record_id, changed_by, action, entity_id)
  values ('workflow_rules', p_rule_id, auth.uid(), 'deactivate', v_entity);
end;
$$;

create or replace function public.evaluate_workflow_condition(
  p_condition_field text,
  p_condition_operator text,
  p_condition_value text,
  p_event_data jsonb
) returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  v_field_value text;
begin
  if p_condition_field is null then
    return true;
  end if;

  v_field_value := p_event_data ->> p_condition_field;
  if v_field_value is null then
    return false;
  end if;

  return case p_condition_operator
    when 'eq' then v_field_value = p_condition_value
    when 'neq' then v_field_value is distinct from p_condition_value
    when 'gt' then (v_field_value)::numeric > (p_condition_value)::numeric
    when 'gte' then (v_field_value)::numeric >= (p_condition_value)::numeric
    when 'lt' then (v_field_value)::numeric < (p_condition_value)::numeric
    when 'lte' then (v_field_value)::numeric <= (p_condition_value)::numeric
    when 'contains' then v_field_value ilike '%' || p_condition_value || '%'
    else true
  end;
exception when others then
  return false;
end;
$$;

create or replace function public.evaluate_workflow_rules(
  p_module text,
  p_trigger_event text,
  p_entity_id uuid,
  p_source_table text,
  p_source_record_id uuid,
  p_event_data jsonb
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  r record;
  v_matched boolean;
  v_location uuid := nullif(p_event_data->>'location_id', '')::uuid;
begin
  if p_entity_id is null then
    return;
  end if;

  for r in
    select * from public.workflow_rules
    where module = p_module
      and trigger_event = p_trigger_event
      and entity_id = p_entity_id
      and is_active = true
  loop
    v_matched := public.evaluate_workflow_condition(r.condition_field, r.condition_operator, r.condition_value, p_event_data);

    if v_matched then
      begin
        if r.action_type = 'notify_role' then
          insert into public.notifications(entity_id, recipient_user_id, employee_id, notification_type, title, message, target_type, target_id, priority)
          select r.entity_id, p.id, null, p_trigger_event, r.name, r.action_message_template, p_source_table, p_source_record_id, 'normal'
          from public.profiles p
          where p.entity_id = r.entity_id
            and p.role = r.action_target_role
            and p.is_active
            and (r.action_target_role not in ('location_manager', 'staff') or v_location is null or p.location_id = v_location);
        elsif r.action_type = 'notify_employee' then
          insert into public.notifications(entity_id, recipient_user_id, employee_id, notification_type, title, message, target_type, target_id, priority)
          values (
            r.entity_id,
            nullif(p_event_data->>'recipient_user_id','')::uuid,
            nullif(p_event_data->>'employee_id','')::uuid,
            p_trigger_event, r.name, r.action_message_template, p_source_table, p_source_record_id, 'normal'
          );
        end if;

        insert into public.workflow_runs(rule_id, entity_id, source_table, source_record_id, event_type, result, details)
        values (r.id, r.entity_id, p_source_table, p_source_record_id, p_trigger_event, 'matched', p_event_data);
      exception when others then
        insert into public.workflow_runs(rule_id, entity_id, source_table, source_record_id, event_type, result, details)
        values (r.id, r.entity_id, p_source_table, p_source_record_id, p_trigger_event, 'failed',
                p_event_data || jsonb_build_object('error', SQLERRM));
      end;
    else
      insert into public.workflow_runs(rule_id, entity_id, source_table, source_record_id, event_type, result, details)
      values (r.id, r.entity_id, p_source_table, p_source_record_id, p_trigger_event, 'skipped', p_event_data);
    end if;
  end loop;
end;
$$;

create or replace function public.test_workflow_rule(
  p_rule_id uuid,
  p_sample_event jsonb
) returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  r public.workflow_rules;
begin
  select * into r from public.workflow_rules where id = p_rule_id;
  if r.id is null or not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and r.entity_id = public.my_entity())) then
    raise exception 'Not authorized to test this rule' using errcode = '42501';
  end if;

  if public.evaluate_workflow_condition(r.condition_field, r.condition_operator, r.condition_value, p_sample_event) then
    return 'matched';
  else
    return 'skipped';
  end if;
end;
$$;

drop function if exists public.get_workflow_rules(text);
create or replace function public.get_workflow_rules(p_module text default null, p_entity_id uuid default null)
returns setof public.workflow_rules
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
begin
  if v_role = 'entity_admin' and p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
    raise exception 'Entity admins can only view their own entity''s workflow rules' using errcode = '42501';
  end if;
  return query
  select * from public.workflow_rules w
  where (
      (v_role = 'owner' and (p_entity_id is null or w.entity_id = p_entity_id))
      or (v_role = 'entity_admin' and w.entity_id = public.my_entity())
    )
    and (p_module is null or w.module = p_module)
  order by w.created_at desc;
end;
$$;

drop function if exists public.get_workflow_runs(uuid, integer);
create or replace function public.get_workflow_runs(p_rule_id uuid default null, p_limit integer default 50, p_entity_id uuid default null)
returns setof public.workflow_runs
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
begin
  if v_role = 'entity_admin' and p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
    raise exception 'Entity admins can only view their own entity''s workflow runs' using errcode = '42501';
  end if;
  return query
  select * from public.workflow_runs w
  where (
      (v_role = 'owner' and (p_entity_id is null or w.entity_id = p_entity_id))
      or (v_role = 'entity_admin' and w.entity_id = public.my_entity())
    )
    and (p_rule_id is null or w.rule_id = p_rule_id)
  order by w.ran_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 500);
end;
$$;

-- ------------------------------------------------------------
-- Trigger hooks (existing, hardened) + new events
-- A workflow failure must never break the business transaction.
-- ------------------------------------------------------------
create or replace function public.trg_workflow_on_leave_submitted() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entity uuid;
  v_location uuid;
begin
  if new.status = 'pending' then
    select e.entity_id, e.home_location_id into v_entity, v_location from public.employees e where e.id = new.employee_id;
    begin
      perform public.evaluate_workflow_rules(
        'leave', 'leave_submitted', v_entity,
        'leave_requests', new.id,
        jsonb_build_object('employee_id', new.employee_id, 'location_id', v_location,
                           'leave_type_id', new.leave_type_id, 'days_requested', new.days_requested)
      );
    exception when others then
      raise warning 'workflow leave_submitted failed: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

create or replace function public.trg_workflow_on_schedule_published() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.is_published and (tg_op = 'INSERT' or old.is_published is distinct from new.is_published) then
    begin
      perform public.evaluate_workflow_rules(
        'schedule', 'schedule_published', new.entity_id,
        'shifts', new.id,
        jsonb_build_object('employee_id', new.employee_id, 'location_id', new.location_id, 'shift_date', new.shift_date)
      );
    exception when others then
      raise warning 'workflow schedule_published failed: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

-- schedule / shift_adjusted: a change to an already-published shift.
create or replace function public.trg_workflow_on_shift_adjusted() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_change text;
begin
  if not old.is_published then
    return new;
  end if;

  v_change := case
    when new.status = 'cancelled' and old.status <> 'cancelled' then 'cancelled'
    when not new.is_published then 'unpublished'
    when new.employee_id is distinct from old.employee_id then 'reassigned'
    when new.shift_date is distinct from old.shift_date then 'date_changed'
    when new.location_id is distinct from old.location_id then 'location_changed'
    when new.start_time is distinct from old.start_time or new.end_time is distinct from old.end_time then 'time_changed'
    else null
  end;

  if v_change is not null then
    begin
      perform public.evaluate_workflow_rules(
        'schedule', 'shift_adjusted', new.entity_id,
        'shifts', new.id,
        jsonb_build_object('employee_id', new.employee_id, 'previous_employee_id', old.employee_id,
                           'location_id', new.location_id, 'shift_date', new.shift_date, 'change_type', v_change)
      );
    exception when others then
      raise warning 'workflow shift_adjusted failed: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists workflow_on_shift_adjusted on public.shifts;
create trigger workflow_on_shift_adjusted
  after update on public.shifts
  for each row execute function public.trg_workflow_on_shift_adjusted();

-- attendance / late_clock_in
create or replace function public.trg_workflow_on_late_clock_in() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_planned timestamptz;
  v_late integer;
begin
  if new.shift_id is null then
    return new;
  end if;

  select b.planned_start into v_planned
    from public.shifts s
    cross join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b
   where s.id = new.shift_id;

  v_late := floor(extract(epoch from (new.clock_in_at - v_planned)) / 60)::integer;

  if v_late is not null and v_late > 0 then
    begin
      perform public.evaluate_workflow_rules(
        'attendance', 'late_clock_in', new.entity_id,
        'attendance_records', new.id,
        jsonb_build_object('employee_id', new.employee_id, 'location_id', new.location_id,
                           'shift_id', new.shift_id, 'attendance_id', new.id, 'late_minutes', v_late)
      );
    exception when others then
      raise warning 'workflow late_clock_in failed: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists workflow_on_late_clock_in on public.attendance_records;
create trigger workflow_on_late_clock_in
  after insert on public.attendance_records
  for each row execute function public.trg_workflow_on_late_clock_in();

-- document / submitted_for_review: a confirmed upload now awaiting review.
create or replace function public.trg_workflow_on_document_submitted() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entity uuid;
  v_location uuid;
begin
  if new.review_status = 'pending_review' and new.upload_confirmed
     and (tg_op = 'INSERT' or not old.upload_confirmed or old.review_status is distinct from 'pending_review') then
    select e.entity_id, e.home_location_id into v_entity, v_location from public.employees e where e.id = new.employee_id;
    begin
      perform public.evaluate_workflow_rules(
        'document', 'submitted_for_review', v_entity,
        'employee_documents', new.id,
        jsonb_build_object('employee_id', new.employee_id, 'location_id', v_location, 'document_id', new.id,
                           'doc_type', new.doc_type, 'is_renewal', new.supersedes_document_id is not null)
      );
    exception when others then
      raise warning 'workflow submitted_for_review failed: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists workflow_on_document_submitted on public.employee_documents;
create trigger workflow_on_document_submitted
  after insert or update on public.employee_documents
  for each row execute function public.trg_workflow_on_document_submitted();

-- payroll / payslip_published: run moves into approved/paid.
create or replace function public.trg_workflow_on_payslip_published() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  p record;
begin
  if new.status in ('approved', 'paid') and old.status not in ('approved', 'paid') then
    for p in select ps.id, ps.employee_id from public.payslips ps where ps.payroll_run_id = new.id loop
      perform public.create_notification(
        new.entity_id, null, p.employee_id, 'payslip_available', 'Payslip ready',
        format('Your payslip for %s to %s is ready to view.', new.period_start, new.period_end),
        'payslips', new.id, 'normal',
        'payslip_available:' || new.id::text || ':' || p.employee_id::text
      );
      begin
        perform public.evaluate_workflow_rules(
          'payroll', 'payslip_published', new.entity_id,
          'payslips', p.id,
          jsonb_build_object('employee_id', p.employee_id, 'payroll_run_id', new.id,
                             'period_start', new.period_start, 'period_end', new.period_end,
                             'is_revision', new.revises_payroll_run_id is not null)
        );
      exception when others then
        raise warning 'workflow payslip_published failed: %', sqlerrm;
      end;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists workflow_on_payslip_published on public.payroll_runs;
create trigger workflow_on_payslip_published
  after update of status on public.payroll_runs
  for each row execute function public.trg_workflow_on_payslip_published();

-- Draft calculation no longer tells staff a payslip is "ready":
-- identical to the previous body minus the notification loop.
create or replace function public.run_payroll_calculation(p_payroll_run_id uuid)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_entity_id uuid;
  v_status text;
  v_ot_confirmed boolean;
  v_tips_confirmed boolean;
  v_total_tips numeric;
  v_eligible_count int;
  v_tips_per_employee numeric;
  v_prior_snapshot jsonb;
  v_period_start date;
  v_period_end date;
begin
  select entity_id, status, overtime_holiday_pay_confirmed, tips_distribution_confirmed, period_start, period_end
    into v_entity_id, v_status, v_ot_confirmed, v_tips_confirmed, v_period_start, v_period_end
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
$function$;

-- document / document_expiring_soon: add location_id + days_to_expiry.
create or replace function public.run_document_expiry_workflow_check()
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  d record;
  v_count integer := 0;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  for d in
    select ed.id, ed.employee_id, ed.doc_type, ed.expiry_date, e.entity_id, e.home_location_id
    from public.employee_documents ed
    join public.employees e on e.id = ed.employee_id
    where ed.is_current = true
      and e.employment_status <> 'inactive'
      and ed.expiry_date is not null
      and ed.expiry_date <= v_today + 30
      and ed.expiry_date >= v_today
      and not exists (
        select 1 from public.workflow_runs wr
        where wr.source_table = 'employee_documents'
          and wr.source_record_id = ed.id
          and wr.event_type = 'document_expiring_soon'
          and wr.ran_at > now() - interval '7 days'
      )
  loop
    perform public.evaluate_workflow_rules(
      'document', 'document_expiring_soon', d.entity_id,
      'employee_documents', d.id,
      jsonb_build_object('employee_id', d.employee_id, 'location_id', d.home_location_id, 'document_id', d.id,
                         'doc_type', d.doc_type, 'expiry_date', d.expiry_date, 'days_to_expiry', d.expiry_date - v_today)
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ------------------------------------------------------------
-- Grants: rule RPCs callable by authenticated (they self-authorise);
-- engine + trigger functions are internal only.
-- ------------------------------------------------------------
revoke all on function public.create_workflow_rule(text, text, text, text, text, text, text, public.user_role, text, uuid) from public, anon;
revoke all on function public.activate_workflow_rule(uuid) from public, anon;
revoke all on function public.deactivate_workflow_rule(uuid) from public, anon;
revoke all on function public.test_workflow_rule(uuid, jsonb) from public, anon;
revoke all on function public.get_workflow_rules(text, uuid) from public, anon;
revoke all on function public.get_workflow_runs(uuid, integer, uuid) from public, anon;
grant execute on function public.create_workflow_rule(text, text, text, text, text, text, text, public.user_role, text, uuid) to authenticated;
grant execute on function public.activate_workflow_rule(uuid) to authenticated;
grant execute on function public.deactivate_workflow_rule(uuid) to authenticated;
grant execute on function public.test_workflow_rule(uuid, jsonb) to authenticated;
grant execute on function public.get_workflow_rules(text, uuid) to authenticated;
grant execute on function public.get_workflow_runs(uuid, integer, uuid) to authenticated;

revoke all on function public.evaluate_workflow_condition(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.evaluate_workflow_rules(text, text, uuid, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.run_document_expiry_workflow_check() from public, anon, authenticated;
revoke all on function public.trg_workflow_on_leave_submitted() from public, anon, authenticated;
revoke all on function public.trg_workflow_on_schedule_published() from public, anon, authenticated;
revoke all on function public.trg_workflow_on_shift_adjusted() from public, anon, authenticated;
revoke all on function public.trg_workflow_on_late_clock_in() from public, anon, authenticated;
revoke all on function public.trg_workflow_on_document_submitted() from public, anon, authenticated;
revoke all on function public.trg_workflow_on_payslip_published() from public, anon, authenticated;
