
-- ============================================================
-- FN-09 Workflow Builder & Run History
-- Entity-scoped trigger/condition/action rules with deterministic
-- evaluation, test mode, and immutable run history.
-- Mirrors existing conventions: my_entity()/my_role() scoping,
-- SECURITY DEFINER writes only, audit_log entries on config changes.
-- ============================================================

create table public.workflow_rules (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  name text not null,
  module text not null check (module in ('leave','document','attendance','schedule','payroll','recruitment')),
  trigger_event text not null,
  condition_field text,
  condition_operator text check (condition_operator in ('eq','neq','gt','gte','lt','lte','contains')),
  condition_value text,
  action_type text not null check (action_type in ('notify_role','notify_employee')),
  action_target_role public.user_role,
  action_message_template text not null,
  is_active boolean not null default false,
  is_starter boolean not null default false,
  version_number integer not null default 1,
  supersedes_rule_id uuid references public.workflow_rules(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  activated_at timestamptz,
  deactivated_at timestamptz,
  constraint condition_fields_together check (
    (condition_field is null and condition_operator is null and condition_value is null)
    or (condition_field is not null and condition_operator is not null and condition_value is not null)
  )
);

comment on table public.workflow_rules is 'FN-09: entity-scoped automation rules. Writes only via create/update/activate/deactivate_workflow_rule() -- no direct DML grant, matching the attendance_adjustments precedent.';

create table public.workflow_runs (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references public.workflow_rules(id),
  entity_id uuid not null references public.entities(id),
  source_table text not null,
  source_record_id uuid not null,
  event_type text not null,
  result text not null check (result in ('matched','skipped','failed')),
  details jsonb,
  ran_at timestamptz not null default now()
);

comment on table public.workflow_runs is 'FN-09: immutable evaluation history. Test runs (test_workflow_rule) never write here, per BR-WFL and the UX requirement that testing must not create production evidence.';

create index workflow_rules_entity_module_trigger_idx on public.workflow_rules(entity_id, module, trigger_event) where is_active;
create index workflow_runs_rule_idx on public.workflow_runs(rule_id, ran_at desc);

alter table public.workflow_rules enable row level security;
alter table public.workflow_runs enable row level security;

create policy workflow_rules_select on public.workflow_rules
  for select using (entity_id = my_entity() and my_role() in ('owner','entity_admin'));

create policy workflow_runs_select on public.workflow_runs
  for select using (entity_id = my_entity() and my_role() in ('owner','entity_admin'));

-- No insert/update/delete policies: all writes go through SECURITY DEFINER
-- functions below, matching the attendance_adjustments pattern already in use.

-- ------------------------------------------------------------
-- Rule management (Owner/Admin only)
-- ------------------------------------------------------------

create or replace function public.create_workflow_rule(
  p_name text,
  p_module text,
  p_trigger_event text,
  p_condition_field text,
  p_condition_operator text,
  p_condition_value text,
  p_action_type text,
  p_action_target_role public.user_role,
  p_action_message_template text
) returns uuid
language plpgsql security definer
as $$
declare
  v_entity uuid := my_entity();
  v_id uuid;
begin
  if my_role() not in ('owner','entity_admin') then
    raise exception 'Only owner/entity_admin can create workflow rules';
  end if;

  insert into public.workflow_rules(
    entity_id, name, module, trigger_event,
    condition_field, condition_operator, condition_value,
    action_type, action_target_role, action_message_template, created_by
  ) values (
    v_entity, p_name, p_module, p_trigger_event,
    p_condition_field, p_condition_operator, p_condition_value,
    p_action_type, p_action_target_role, p_action_message_template, auth.uid()
  ) returning id into v_id;

  insert into public.audit_log(table_name, record_id, changed_by, action, new_value, entity_id)
  values ('workflow_rules', v_id, auth.uid(), 'create',
          jsonb_build_object('name', p_name, 'module', p_module, 'trigger_event', p_trigger_event),
          v_entity);

  return v_id;
end;
$$;

create or replace function public.activate_workflow_rule(p_rule_id uuid) returns void
language plpgsql security definer
as $$
declare
  v_entity uuid;
begin
  select entity_id into v_entity from public.workflow_rules where id = p_rule_id;
  if v_entity is null or v_entity <> my_entity() or my_role() not in ('owner','entity_admin') then
    raise exception 'Not authorized to activate this rule';
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
as $$
declare
  v_entity uuid;
begin
  select entity_id into v_entity from public.workflow_rules where id = p_rule_id;
  if v_entity is null or v_entity <> my_entity() or my_role() not in ('owner','entity_admin') then
    raise exception 'Not authorized to deactivate this rule';
  end if;

  update public.workflow_rules
    set is_active = false, deactivated_at = now(), updated_at = now()
    where id = p_rule_id;

  insert into public.audit_log(table_name, record_id, changed_by, action, entity_id)
  values ('workflow_rules', p_rule_id, auth.uid(), 'deactivate', v_entity);
end;
$$;

-- ------------------------------------------------------------
-- Deterministic condition evaluation (shared by real + test paths)
-- ------------------------------------------------------------

create or replace function public.evaluate_workflow_condition(
  p_condition_field text,
  p_condition_operator text,
  p_condition_value text,
  p_event_data jsonb
) returns boolean
language plpgsql immutable
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

-- ------------------------------------------------------------
-- Real evaluation: matches active rules, fires action, logs run
-- ------------------------------------------------------------

create or replace function public.evaluate_workflow_rules(
  p_module text,
  p_trigger_event text,
  p_entity_id uuid,
  p_source_table text,
  p_source_record_id uuid,
  p_event_data jsonb
) returns void
language plpgsql security definer
as $$
declare
  r record;
  v_matched boolean;
begin
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
          where p.entity_id = r.entity_id and p.role = r.action_target_role;
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

-- ------------------------------------------------------------
-- Test mode: evaluates against a sample event, writes NOTHING
-- ------------------------------------------------------------

create or replace function public.test_workflow_rule(
  p_rule_id uuid,
  p_sample_event jsonb
) returns text
language plpgsql security definer
as $$
declare
  r public.workflow_rules;
begin
  select * into r from public.workflow_rules where id = p_rule_id;
  if r.id is null or r.entity_id <> my_entity() or my_role() not in ('owner','entity_admin') then
    raise exception 'Not authorized to test this rule';
  end if;

  if public.evaluate_workflow_condition(r.condition_field, r.condition_operator, r.condition_value, p_sample_event) then
    return 'matched';
  else
    return 'skipped';
  end if;
end;
$$;

-- ------------------------------------------------------------
-- Read helpers
-- ------------------------------------------------------------

create or replace function public.get_workflow_rules(p_module text default null)
returns setof public.workflow_rules
language sql security definer
as $$
  select * from public.workflow_rules
  where entity_id = my_entity()
    and my_role() in ('owner','entity_admin')
    and (p_module is null or module = p_module)
  order by created_at desc;
$$;

create or replace function public.get_workflow_runs(p_rule_id uuid default null, p_limit integer default 50)
returns setof public.workflow_runs
language sql security definer
as $$
  select * from public.workflow_runs
  where entity_id = my_entity()
    and my_role() in ('owner','entity_admin')
    and (p_rule_id is null or rule_id = p_rule_id)
  order by ran_at desc
  limit greatest(p_limit, 1);
$$;

-- ------------------------------------------------------------
-- Trigger hooks: leave_submitted, schedule_published
-- (the two BR-WFL-003 starter events)
-- ------------------------------------------------------------

create or replace function public.trg_workflow_on_leave_submitted() returns trigger
language plpgsql security definer
as $$
declare
  v_entity uuid;
begin
  if new.status = 'pending' then
    select entity_id into v_entity from public.employees where id = new.employee_id;
    perform public.evaluate_workflow_rules(
      'leave', 'leave_submitted', v_entity,
      'leave_requests', new.id,
      jsonb_build_object('employee_id', new.employee_id, 'leave_type_id', new.leave_type_id, 'days_requested', new.days_requested)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists workflow_on_leave_submitted on public.leave_requests;
create trigger workflow_on_leave_submitted
  after insert on public.leave_requests
  for each row execute function public.trg_workflow_on_leave_submitted();

create or replace function public.trg_workflow_on_schedule_published() returns trigger
language plpgsql security definer
as $$
begin
  if new.is_published and (tg_op = 'INSERT' or old.is_published is distinct from new.is_published) then
    perform public.evaluate_workflow_rules(
      'schedule', 'schedule_published', new.entity_id,
      'shifts', new.id,
      jsonb_build_object('employee_id', new.employee_id, 'location_id', new.location_id, 'shift_date', new.shift_date)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists workflow_on_schedule_published on public.shifts;
create trigger workflow_on_schedule_published
  after insert or update on public.shifts
  for each row execute function public.trg_workflow_on_schedule_published();

-- ------------------------------------------------------------
-- BR-DOC-003: automated T-30 document expiry check.
-- Callable on demand now; wire to a daily pg_cron job once approved.
-- Idempotent: skips documents already alerted in the last 7 days.
-- ------------------------------------------------------------

create or replace function public.run_document_expiry_workflow_check()
returns integer
language plpgsql security definer
as $$
declare
  d record;
  v_count integer := 0;
begin
  for d in
    select ed.*, e.entity_id
    from public.employee_documents ed
    join public.employees e on e.id = ed.employee_id
    where ed.is_current = true
      and ed.expiry_date is not null
      and ed.expiry_date <= (current_date + interval '30 days')
      and ed.expiry_date >= current_date
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
      jsonb_build_object('employee_id', d.employee_id, 'doc_type', d.doc_type, 'expiry_date', d.expiry_date)
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.run_document_expiry_workflow_check() is 'BR-DOC-003: finds is_current documents expiring within 30 days and fires the document_expiring_soon workflow trigger. Run manually or via a scheduled job (pg_cron) once approved -- not yet scheduled automatically.';

-- ------------------------------------------------------------
-- Seed the two BR-WFL-003 starter rules for the two real entities
-- (skips the UAT test entities)
-- ------------------------------------------------------------

insert into public.workflow_rules (entity_id, name, module, trigger_event, action_type, action_target_role, action_message_template, is_active, is_starter)
select e.id, 'Notify managers on leave request', 'leave', 'leave_submitted', 'notify_role', 'location_manager', 'A new leave request needs your review.', true, true
from public.entities e
where e.name in ('Third State Cafe', 'Ateej Tea Brew')
on conflict do nothing;

insert into public.workflow_rules (entity_id, name, module, trigger_event, action_type, action_target_role, action_message_template, is_active, is_starter)
select e.id, 'Alert on document expiring within 30 days', 'document', 'document_expiring_soon', 'notify_role', 'entity_admin', 'A staff document is expiring within 30 days and needs renewal.', true, true
from public.entities e
where e.name in ('Third State Cafe', 'Ateej Tea Brew')
on conflict do nothing;
