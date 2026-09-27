-- =====================================================================
-- Migration 013 — offboarding (end of employment).
-- One case per leaver: separation type, notice and last working day,
-- a role-based checklist (branch handover, access, final settlement,
-- work permit / visa cancellation or pension notice), and a controlled
-- finish that inactivates the employee through set_employee_status.
--
-- UAE rules applied (Federal Decree-Law 33/2021; check the contract):
--   * Probation, employer ends it: at least 14 days' written notice (Art. 9(1)).
--   * Probation, employee resigns: 14 days if leaving the UAE, one month
--     if joining another UAE employer (Art. 9(2)–(3)).
--   * After probation: at least 30 days (contract may say up to 90) (Art. 43).
--   * Dismissal without notice only under Art. 44 (recorded as its own type).
--   * Final settlement within 14 days of the last day (Art. 53).
--   * Gratuity from payroll_gratuity_preview (none under one year; UAE
--     nationals get pension instead).
-- A shorter notice is allowed only with a recorded reason (e.g. pay in lieu,
-- notice waived in writing).
-- Depends on: 001–012, payroll v2 (payroll_set_last_working_date, payroll_gratuity_preview).
-- =====================================================================

begin;

create table public.offboarding_cases (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  entity_id uuid not null references public.entities(id),
  location_id uuid references public.locations(id),
  separation_type text not null check (separation_type in ('resignation', 'termination', 'dismissal_art44', 'end_of_contract',
    'mutual_agreement', 'probation_not_confirmed', 'no_show', 'retirement', 'death', 'other')),
  initiated_by text not null check (initiated_by in ('employee', 'employer', 'mutual', 'none')),
  notice_date date not null,
  last_working_date date not null,
  in_probation boolean not null default false,
  leaving_uae boolean not null default false,
  min_notice_days integer not null default 0,
  notice_shortfall_reason text,
  reason text not null,
  status text not null default 'open' check (status in ('open', 'completed', 'cancelled')),
  settlement_due_date date not null,
  source_onboarding_instance_id uuid references public.onboarding_instances(id),
  source_exception_id uuid references public.onboarding_exceptions(id),
  row_version integer not null default 1,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  closed_by uuid references auth.users(id),
  closed_at timestamptz,
  close_notes text,
  updated_at timestamptz not null default now(),
  check (last_working_date >= notice_date)
);
create unique index offboarding_cases_one_open on public.offboarding_cases (employee_id) where status = 'open';
create index offboarding_cases_entity_idx on public.offboarding_cases (entity_id, status);

create table public.offboarding_tasks (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.offboarding_cases(id) on delete cascade,
  item_key text not null,
  label text not null,
  owner_role text not null check (owner_role in ('location_manager', 'hr', 'payroll')),
  is_required boolean not null default true,
  status text not null default 'not_started' check (status in ('not_started', 'done', 'not_needed')),
  due_date date,
  notes text,
  completed_by uuid references auth.users(id),
  completed_at timestamptz,
  sort_order integer not null default 0,
  unique (case_id, item_key)
);

-- ---------------------------------------------------------- helpers
create or replace function public._off_min_notice_days(p_type text, p_initiated_by text, p_in_probation boolean, p_leaving_uae boolean)
returns integer language sql immutable set search_path to '' as $$
  select case
    when p_type in ('no_show', 'death', 'dismissal_art44', 'end_of_contract', 'mutual_agreement') then 0
    when p_type = 'probation_not_confirmed' then 14
    when p_in_probation and p_initiated_by = 'employer' then 14
    when p_in_probation and p_initiated_by = 'employee' then case when p_leaving_uae then 14 else 30 end
    else 30 end;
$$;

-- Scope on one case: manage (owner / entity admin), payroll (payroll approver),
-- operate (branch manager of the case's branch, or manage).
create or replace function public._off_can(p_case_id uuid, p_cap text)
returns boolean language plpgsql stable security definer set search_path to '' as $$
declare c public.offboarding_cases; v_role public.user_role := public.my_role();
begin
  select * into c from public.offboarding_cases where id = p_case_id;
  if c.id is null or v_role is null or not public.is_active_user() then return false; end if;
  if c.employee_id = public.my_employee_id() then return false; end if;
  if p_cap = 'manage' then return v_role = 'owner' or (v_role = 'entity_admin' and c.entity_id = public.my_entity()); end if;
  if p_cap = 'payroll' then return public.payroll_can(c.entity_id, 'approve'); end if;
  if p_cap = 'operate' then
    return v_role = 'owner' or (v_role = 'entity_admin' and c.entity_id = public.my_entity())
        or (v_role = 'location_manager' and c.location_id = public.my_location());
  end if;
  if p_cap = 'view' then
    return public._off_can(p_case_id, 'operate') or public._off_can(p_case_id, 'payroll');
  end if;
  return false;
end;
$$;

create or replace function public._off_audit(p_case public.offboarding_cases, p_record uuid, p_action text, p_old jsonb, p_new jsonb)
returns void language sql security definer set search_path to '' as $$
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('offboarding_cases', p_record, auth.uid(), p_action, p_old,
          coalesce(p_new, '{}'::jsonb) || jsonb_build_object('offboarding_case_id', p_case.id), p_case.entity_id, p_case.location_id, p_case.employee_id);
$$;

create or replace function public._off_generate_tasks(p_case_id uuid)
returns integer language plpgsql security definer set search_path to '' as $$
declare c public.offboarding_cases; v_track text; v_national boolean; n integer;
begin
  select * into c from public.offboarding_cases where id = p_case_id;
  v_track := public.suggest_immigration_track(c.employee_id);
  v_national := v_track in ('uae_national', 'gcc_national');
  insert into public.offboarding_tasks (case_id, item_key, label, owner_role, is_required, due_date, sort_order)
  select c.id, k, l, o, r, d, s from (values
    ('notice_letter', 'Resignation / termination letter on file', 'hr', c.separation_type not in ('no_show', 'death'), c.notice_date, 1),
    ('handover', 'Handover of duties and open work', 'location_manager', false, c.last_working_date, 2),
    ('reassign_shifts', 'Future shifts reassigned', 'location_manager', true, c.last_working_date, 3),
    ('return_items', 'Uniform, keys and equipment returned', 'location_manager', c.separation_type <> 'death', c.last_working_date, 4),
    ('system_access', 'POS, till and other logins removed', 'location_manager', true, c.last_working_date, 5),
    ('exit_interview', 'Exit interview', 'hr', false, c.last_working_date, 6),
    ('final_settlement', 'Final settlement paid (wages, leave, gratuity)', 'payroll', true, c.settlement_due_date, 7),
    ('work_permit_cancellation', 'Work permit cancelled with MOHRE', 'hr', true, c.last_working_date + 14, 8),
    ('visa_cancellation', 'Residence visa cancelled (or transfer confirmed)', 'hr', true, c.last_working_date + 14, 9),
    ('health_insurance_cancellation', 'Health insurance cancelled after visa cancellation', 'hr', false, c.last_working_date + 30, 10),
    ('pension_notice', 'End of service notified to the pension authority (GPSSA / GCC)', 'hr', true, c.last_working_date + 14, 11),
    ('service_certificate', 'Service certificate issued (on request, Art. 13)', 'hr', false, c.last_working_date + 14, 12)
  ) as t(k, l, o, r, d, s)
  where (k not in ('work_permit_cancellation', 'visa_cancellation', 'health_insurance_cancellation') or not v_national)
    and (k <> 'pension_notice' or v_national)
    and (k <> 'exit_interview' or c.separation_type not in ('no_show', 'death', 'dismissal_art44'))
  on conflict (case_id, item_key) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ------------------------------------------------------------- start
create or replace function public.start_offboarding(p_employee_id uuid, p_type text, p_initiated_by text, p_notice_date date,
  p_last_working_date date, p_reason text, p_leaving_uae boolean default false, p_notice_shortfall_reason text default null,
  p_source_exception_id uuid default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  e public.employees;
  c public.offboarding_cases;
  v_role public.user_role := public.my_role();
  v_in_prob boolean;
  v_min integer;
  v_days integer;
  v_inst uuid;
  x public.onboarding_exceptions;
  v_user uuid;
begin
  select * into e from public.employees where id = p_employee_id for update;
  if e.id is null then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  if not public.is_active_user() or not (v_role = 'owner' or (v_role = 'entity_admin' and e.entity_id = public.my_entity())) then
    raise exception 'Only the owner or entity admin can start offboarding' using errcode = '42501';
  end if;
  if e.id = public.my_employee_id() then raise exception 'You cannot offboard yourself' using errcode = '42501'; end if;
  if e.employment_status <> 'active' then
    raise exception 'Only active employees are offboarded. For someone who has not started, withdraw or cancel their onboarding.'
      using errcode = '22023';
  end if;
  if exists (select 1 from public.offboarding_cases where employee_id = e.id and status = 'open') then
    raise exception 'This employee already has an open offboarding' using errcode = '23505';
  end if;
  if p_type is null or p_initiated_by is null or p_notice_date is null or p_last_working_date is null then
    raise exception 'Type, who ended it, notice date and last working day are required' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if p_last_working_date < p_notice_date then raise exception 'The last working day cannot be before the notice date' using errcode = '22023'; end if;
  if e.join_date is not null and p_last_working_date < e.join_date - 1 then
    raise exception 'The last working day is before the start date' using errcode = '22023';
  end if;

  v_in_prob := exists (select 1 from public.employee_probation_periods pp where pp.employee_id = e.id and pp.status = 'active'
                        and pp.end_date >= p_notice_date);
  v_min := public._off_min_notice_days(p_type, p_initiated_by, v_in_prob, coalesce(p_leaving_uae, false));
  v_days := p_last_working_date - p_notice_date;
  if v_days < v_min and nullif(btrim(coalesce(p_notice_shortfall_reason, '')), '') is null then
    raise exception 'The minimum notice here is % days (you gave %). Move the last working day, or record why the notice is shorter (e.g. pay in lieu, waived in writing).', v_min, v_days
      using errcode = '22023';
  end if;

  if p_source_exception_id is not null then
    select * into x from public.onboarding_exceptions where id = p_source_exception_id for update;
    if x.id is null or not exists (select 1 from public.onboarding_instances i where i.id = x.instance_id and i.employee_id = e.id) then
      raise exception 'That onboarding problem belongs to someone else' using errcode = '22023';
    end if;
    v_inst := x.instance_id;
  else
    select id into v_inst from public.onboarding_instances where employee_id = e.id and status not in ('completed', 'cancelled', 'withdrawn')
     order by created_at desc limit 1;
  end if;

  insert into public.offboarding_cases (employee_id, entity_id, location_id, separation_type, initiated_by, notice_date, last_working_date,
    in_probation, leaving_uae, min_notice_days, notice_shortfall_reason, reason, settlement_due_date, source_onboarding_instance_id,
    source_exception_id, created_by)
  values (e.id, e.entity_id, e.home_location_id, p_type, p_initiated_by, p_notice_date, p_last_working_date, v_in_prob,
    coalesce(p_leaving_uae, false), v_min, nullif(btrim(coalesce(p_notice_shortfall_reason, '')), ''), btrim(p_reason),
    p_last_working_date + 14, v_inst, p_source_exception_id, auth.uid())
  returning * into c;
  perform public._off_generate_tasks(c.id);
  -- Payroll uses the last working day for proration and final settlement.
  perform public.payroll_set_last_working_date(e.id, p_last_working_date, 'Offboarding: ' || replace(p_type, '_', ' '));

  if x.id is not null and x.status = 'open' then
    update public.onboarding_exceptions set status = 'resolved', resolution = 'Offboarding started', resolved_by = auth.uid(), resolved_at = now()
     where id = x.id;
  end if;

  perform public._off_audit(c, c.id, 'offboarding_started', null,
    jsonb_build_object('type', p_type, 'initiated_by', p_initiated_by, 'notice_date', p_notice_date, 'last_working_date', p_last_working_date,
      'notice_days', v_days, 'min_notice_days', v_min, 'in_probation', v_in_prob, 'shortfall_reason', p_notice_shortfall_reason));

  -- Branch manager(s) of the branch; no pay, no reason in the message.
  for v_user in select p.id from public.profiles p where p.is_active and p.role = 'location_manager' and p.location_id = e.home_location_id loop
    perform public.create_notification(e.entity_id, v_user, null, 'offboarding_started', 'Employee leaving',
      format('%s''s last working day is %s. Your checklist is in Offboarding.', e.full_name, to_char(p_last_working_date, 'DD Mon YYYY')),
      'offboarding_case', c.id, 'normal', format('off:%s:started:%s', c.id, v_user));
  end loop;
  begin
    perform public.evaluate_workflow_rules('offboarding', 'offboarding_started', e.entity_id, 'offboarding_cases', c.id,
      jsonb_build_object('employee_id', e.id, 'location_id', e.home_location_id, 'offboarding_case_id', c.id,
                         'separation_type', p_type, 'last_working_date', p_last_working_date));
  exception when others then raise warning 'workflow offboarding_started failed: %', sqlerrm;
  end;

  return jsonb_build_object('ok', true, 'case_id', c.id, 'notice_days', v_days, 'min_notice_days', v_min, 'in_probation', v_in_prob,
    'settlement_due_date', c.settlement_due_date);
end;
$$;

-- Change the notice date / last working day (e.g. garden leave, agreed earlier exit).
create or replace function public.update_offboarding_dates(p_case_id uuid, p_notice_date date, p_last_working_date date, p_reason text,
  p_expected_version integer, p_notice_shortfall_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.offboarding_cases; v_days integer;
begin
  select * into c from public.offboarding_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  if not public._off_can(c.id, 'manage') then raise exception 'Not authorized' using errcode = '42501'; end if;
  if c.status <> 'open' then raise exception 'This offboarding is closed' using errcode = '22023'; end if;
  if p_expected_version is distinct from c.row_version then raise exception 'This offboarding changed; reload and try again' using errcode = '40001'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if p_last_working_date < p_notice_date then raise exception 'The last working day cannot be before the notice date' using errcode = '22023'; end if;
  v_days := p_last_working_date - p_notice_date;
  if v_days < c.min_notice_days and nullif(btrim(coalesce(p_notice_shortfall_reason, c.notice_shortfall_reason, '')), '') is null then
    raise exception 'The minimum notice here is % days. Record why the notice is shorter.', c.min_notice_days using errcode = '22023';
  end if;
  update public.offboarding_cases set notice_date = p_notice_date, last_working_date = p_last_working_date,
         settlement_due_date = p_last_working_date + 14,
         notice_shortfall_reason = coalesce(nullif(btrim(coalesce(p_notice_shortfall_reason, '')), ''), notice_shortfall_reason),
         row_version = row_version + 1, updated_at = now()
   where id = c.id;
  update public.offboarding_tasks t set due_date = t.due_date + (p_last_working_date - c.last_working_date)
   where t.case_id = c.id and t.status = 'not_started' and t.item_key <> 'notice_letter';
  perform public.payroll_set_last_working_date(c.employee_id, p_last_working_date, 'Offboarding dates changed: ' || btrim(p_reason));
  perform public._off_audit(c, c.id, 'offboarding_dates_changed',
    jsonb_build_object('notice_date', c.notice_date, 'last_working_date', c.last_working_date),
    jsonb_build_object('notice_date', p_notice_date, 'last_working_date', p_last_working_date, 'reason', p_reason));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.complete_offboarding_task(p_task_id uuid, p_status text, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.offboarding_tasks; c public.offboarding_cases; v_ok boolean;
begin
  select * into t from public.offboarding_tasks where id = p_task_id for update;
  if t.id is null then raise exception 'Task not found' using errcode = 'P0002'; end if;
  select * into c from public.offboarding_cases where id = t.case_id;
  if c.status <> 'open' then raise exception 'This offboarding is closed' using errcode = '22023'; end if;
  v_ok := case t.owner_role when 'location_manager' then public._off_can(c.id, 'operate')
                            when 'payroll' then public._off_can(c.id, 'payroll')
                            else public._off_can(c.id, 'manage') end;
  if not v_ok then raise exception 'This task belongs to %', replace(t.owner_role, '_', ' ') using errcode = '42501'; end if;
  if p_status not in ('done', 'not_needed', 'not_started') then raise exception 'Status must be done, not_needed or not_started' using errcode = '22023'; end if;
  if p_status = 'not_needed' and nullif(btrim(coalesce(p_notes, '')), '') is null then raise exception 'Say why it is not needed' using errcode = '22023'; end if;
  if p_status = 'not_needed' and t.is_required and not public._off_can(c.id, 'manage') then
    raise exception 'Only HR can skip a required step' using errcode = '42501';
  end if;
  update public.offboarding_tasks set status = p_status, notes = coalesce(nullif(btrim(coalesce(p_notes, '')), ''), notes),
         completed_by = case when p_status = 'not_started' then null else auth.uid() end,
         completed_at = case when p_status = 'not_started' then null else now() end
   where id = t.id;
  update public.offboarding_cases set row_version = row_version + 1, updated_at = now() where id = c.id;
  perform public._off_audit(c, t.id, 'offboarding_task_updated', jsonb_build_object('task', t.item_key, 'status', t.status),
    jsonb_build_object('task', t.item_key, 'status', p_status, 'notes', p_notes));
  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- -------------------------------------------------------------- read
create or replace function public.get_offboarding_case(p_case_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  c public.offboarding_cases;
  e public.employees;
  v_hr boolean;
  v_pay boolean;
  v_grat jsonb;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  select * into c from public.offboarding_cases where id = p_case_id;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  if not public._off_can(c.id, 'view') then raise exception 'Not authorized' using errcode = '42501'; end if;
  v_hr := public._off_can(c.id, 'manage');
  v_pay := public._off_can(c.id, 'payroll');
  select * into e from public.employees where id = c.employee_id;
  if v_pay then
    begin
      v_grat := public.payroll_gratuity_preview(e.id, c.last_working_date);
    exception when others then v_grat := jsonb_build_object('ok', false, 'reason', sqlerrm);
    end;
  end if;
  return jsonb_build_object(
    'case', (to_jsonb(c) - 'reason' - 'notice_shortfall_reason')
            || case when v_hr then jsonb_build_object('reason', c.reason, 'notice_shortfall_reason', c.notice_shortfall_reason) else '{}'::jsonb end,
    'employee', jsonb_build_object('id', e.id, 'name', e.full_name, 'employee_number', e.employee_number, 'join_date', e.join_date,
      'employment_status', e.employment_status,
      'branch', (select name from public.locations where id = e.home_location_id),
      'position', (select title from public.positions where id = e.position_id)),
    'permissions', jsonb_build_object('manage', v_hr, 'payroll', v_pay, 'operate', public._off_can(c.id, 'operate')),
    'notice_days', c.last_working_date - c.notice_date,
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'item_key', t.item_key, 'label', t.label, 'owner_role', t.owner_role,
        'is_required', t.is_required, 'status', t.status, 'due_date', t.due_date, 'notes', t.notes, 'completed_at', t.completed_at,
        'overdue', t.status = 'not_started' and t.due_date < v_today) order by t.sort_order)
      from public.offboarding_tasks t where t.case_id = c.id
       and (v_hr or v_pay or t.owner_role = 'location_manager')), '[]'::jsonb),
    'future_published_shifts', (select count(*) from public.shifts s where s.employee_id = e.id and s.shift_date > c.last_working_date
                                  and s.is_published and s.status <> 'cancelled'),
    'settlement', case when v_pay then jsonb_build_object('due_date', c.settlement_due_date, 'gratuity', v_grat,
      'leave_balances', coalesce((select jsonb_agg(jsonb_build_object('leave_type', lt.name, 'balance_days', lb.balance_days))
                                    from public.leave_balances lb join public.leave_types lt on lt.id = lb.leave_type_id
                                   where lb.employee_id = e.id and lb.balance_days <> 0), '[]'::jsonb)) end,
    'timeline', case when v_hr then coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'at', a.changed_at, 'by', pr.full_name) order by a.changed_at desc)
       from public.audit_log a left join public.profiles pr on pr.id = a.changed_by
      where a.new_value ->> 'offboarding_case_id' = c.id::text), '[]'::jsonb) end);
end;
$$;

create or replace function public.list_offboarding(p_entity_id uuid, p_status text default 'open')
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_role public.user_role := public.my_role(); v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())
          or public.payroll_can(p_entity_id, 'approve')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('case_id', c.id, 'employee_id', e.id, 'name', e.full_name,
      'branch', (select name from public.locations where id = c.location_id), 'separation_type', c.separation_type,
      'notice_date', c.notice_date, 'last_working_date', c.last_working_date, 'settlement_due_date', c.settlement_due_date,
      'status', c.status, 'row_version', c.row_version,
      'open_tasks', (select count(*) from public.offboarding_tasks t where t.case_id = c.id and t.is_required and t.status = 'not_started'),
      'overdue_tasks', (select count(*) from public.offboarding_tasks t where t.case_id = c.id and t.status = 'not_started' and t.due_date < v_today))
      order by c.last_working_date)
    from public.offboarding_cases c join public.employees e on e.id = c.employee_id
   where c.entity_id = p_entity_id and (p_status = 'all' or c.status = p_status)
     and (v_role <> 'location_manager' or c.location_id = public.my_location())), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------ finish / cancel
create or replace function public.complete_offboarding(p_case_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  c public.offboarding_cases;
  e public.employees;
  v_open text;
  v_inst public.onboarding_instances;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  select * into c from public.offboarding_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  if not public._off_can(c.id, 'manage') then raise exception 'Only the owner or entity admin can finish offboarding' using errcode = '42501'; end if;
  if c.status <> 'open' then return jsonb_build_object('ok', true, 'already', true); end if;
  if c.last_working_date > v_today then
    raise exception 'The last working day (%) has not passed yet', to_char(c.last_working_date, 'DD Mon YYYY') using errcode = '22023';
  end if;
  select string_agg(label, ', ' order by sort_order) into v_open from public.offboarding_tasks
   where case_id = c.id and is_required and status = 'not_started';
  if v_open is not null then raise exception 'Still open: %', v_open using errcode = '22023'; end if;

  select * into e from public.employees where id = c.employee_id;
  if e.employment_status = 'active' then
    perform public.set_employee_status(e.id, 'inactive', 'End of employment (' || replace(c.separation_type, '_', ' ') || ')');
  end if;
  -- An onboarding still running ends with the employment.
  select * into v_inst from public.onboarding_instances where employee_id = e.id and status not in ('completed', 'cancelled', 'withdrawn');
  if v_inst.id is not null then
    perform public._onb_set_status(v_inst.id, 'cancelled', 'Employment ended');
    update public.onboarding_instances set ended_at = now(), ended_by = auth.uid(), end_reason = 'Employment ended (offboarding)' where id = v_inst.id;
    update public.onboarding_tasks set status = 'cancelled', updated_at = now()
     where instance_id = v_inst.id and status not in ('approved', 'waived', 'cancelled');
  end if;
  update public.employee_immigration_cases set status = 'cancelled', closed_by = auth.uid(), closed_at = now(),
         close_reason = 'Employment ended', updated_at = now()
   where employee_id = e.id and status = 'open';

  update public.offboarding_cases set status = 'completed', closed_by = auth.uid(), closed_at = now(),
         close_notes = nullif(btrim(coalesce(p_notes, '')), ''), row_version = row_version + 1, updated_at = now()
   where id = c.id;
  perform public._off_audit(c, c.id, 'offboarding_completed', null, jsonb_build_object('notes', p_notes));
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

create or replace function public.cancel_offboarding(p_case_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.offboarding_cases;
begin
  select * into c from public.offboarding_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  if not public._off_can(c.id, 'manage') then raise exception 'Not authorized' using errcode = '42501'; end if;
  if c.status <> 'open' then return jsonb_build_object('ok', true, 'already', true); end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  update public.offboarding_cases set status = 'cancelled', closed_by = auth.uid(), closed_at = now(), close_notes = btrim(p_reason),
         row_version = row_version + 1, updated_at = now() where id = c.id;
  perform public.payroll_set_last_working_date(c.employee_id, null, 'Offboarding cancelled: ' || btrim(p_reason));
  perform public._off_audit(c, c.id, 'offboarding_cancelled', null, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

-- --------------------------------------------------------- reminders
create or replace function public._off_reminders(p_today date)
returns integer language plpgsql security definer set search_path to '' as $$
declare r record; x record; n integer := 0;
begin
  -- Overdue checklist items, per branch and owner.
  for r in select c.entity_id, c.location_id, t.owner_role, count(*) cnt, max(p_today - t.due_date) worst, (array_agg(c.id))[1] first_case
             from public.offboarding_tasks t join public.offboarding_cases c on c.id = t.case_id
            where c.status = 'open' and t.status = 'not_started' and t.due_date < p_today
            group by 1, 2, 3 loop
    for x in select p.id from public.profiles p where p.is_active
               and ((r.owner_role = 'location_manager' and p.role = 'location_manager' and p.location_id = r.location_id)
                 or (p.role = 'entity_admin' and p.entity_id = r.entity_id and (r.owner_role <> 'location_manager' or r.worst >= 2))) loop
      perform public.create_notification(r.entity_id, x.id, null, 'offboarding_task_overdue', 'Offboarding tasks overdue',
        format('%s overdue %s task(s), oldest %s day(s).', r.cnt, replace(r.owner_role, '_', ' '), r.worst),
        'offboarding_case', r.first_case, 'normal', format('off:overdue:%s:%s:%s:%s', r.location_id, r.owner_role, x.id, p_today));
      n := n + 1;
    end loop;
  end loop;
  -- Final settlement due within 3 days and not yet marked paid.
  for r in select c.*, e.full_name from public.offboarding_cases c join public.employees e on e.id = c.employee_id
            where c.status = 'open' and c.settlement_due_date <= p_today + 3
              and exists (select 1 from public.offboarding_tasks t where t.case_id = c.id and t.item_key = 'final_settlement' and t.status = 'not_started') loop
    for x in select p.id from public.profiles p where p.is_active and p.role = 'entity_admin' and p.entity_id = r.entity_id loop
      perform public.create_notification(r.entity_id, x.id, null, 'final_settlement_due', 'Final settlement due',
        format('%s: final settlement is due by %s (14 days after the last day).', r.full_name, to_char(r.settlement_due_date, 'DD Mon')),
        'offboarding_case', r.id, 'high', format('off:%s:settlement:%s', r.id, x.id));
      n := n + 1;
    end loop;
    begin
      perform public.evaluate_workflow_rules('offboarding', 'final_settlement_due', r.entity_id, 'offboarding_cases', r.id,
        jsonb_build_object('employee_id', r.employee_id, 'location_id', r.location_id, 'offboarding_case_id', r.id,
                           'settlement_due_date', r.settlement_due_date, 'days_to_due', r.settlement_due_date - p_today));
    exception when others then raise warning 'workflow final_settlement_due failed: %', sqlerrm;
    end;
  end loop;
  return n;
end;
$$;

create or replace function public._onb_extension_reminders(p_today date)
returns integer language sql security definer set search_path to '' as $$
  select public._imm_reminders(p_today) + public._off_reminders(p_today);
$$;

-- --------------------------------------------------------------- RLS
alter table public.offboarding_cases enable row level security;
alter table public.offboarding_tasks enable row level security;
revoke all on public.offboarding_cases, public.offboarding_tasks from anon, authenticated;
grant select on public.offboarding_cases, public.offboarding_tasks to authenticated;
-- Direct reads: HR and payroll approvers. Branch managers use the RPCs
-- (which leave out the reason).
create policy offboarding_cases_select on public.offboarding_cases for select to authenticated
  using ((select public.is_active_user()) and employee_id is distinct from (select public.my_employee_id())
         and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))
              or public.payroll_can(entity_id, 'approve')));
create policy offboarding_tasks_select on public.offboarding_tasks for select to authenticated
  using (exists (select 1 from public.offboarding_cases c where c.id = case_id));

do $$
declare f text;
begin
  foreach f in array array['_off_min_notice_days(text, text, boolean, boolean)', '_off_can(uuid, text)',
    '_off_audit(public.offboarding_cases, uuid, text, jsonb, jsonb)', '_off_generate_tasks(uuid)', '_off_reminders(date)',
    '_onb_extension_reminders(date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['start_offboarding(uuid, text, text, date, date, text, boolean, text, uuid)',
    'update_offboarding_dates(uuid, date, date, text, integer, text)', 'complete_offboarding_task(uuid, text, text)',
    'get_offboarding_case(uuid)', 'list_offboarding(uuid, text)', 'complete_offboarding(uuid, text)', 'cancel_offboarding(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

commit;
