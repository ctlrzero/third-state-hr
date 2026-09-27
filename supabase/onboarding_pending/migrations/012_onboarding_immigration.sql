-- =====================================================================
-- Migration 012 — work permit and visa processing (MOHRE / ICP / GDRFA).
-- One case per hire, with steps chosen by the person's situation (track).
-- Steps marked blocking stop activation until done or marked not needed;
-- the defaults block on the work permit and the MOHRE labour contract
-- (or MOHRE registration for UAE / GCC nationals). HR can change which
-- steps block, with a reason. Everything is HR-only (owner / entity
-- admin); branch managers only see "work permit paperwork outstanding"
-- through readiness. Check the step list against current MOHRE / ICP /
-- emirate rules before relying on it.
-- Depends on: 001–008.
-- =====================================================================

begin;

create table public.employee_immigration_cases (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  entity_id uuid not null references public.entities(id),
  onboarding_instance_id uuid references public.onboarding_instances(id),
  track text not null check (track in ('outside_uae', 'inside_uae', 'transfer', 'own_visa', 'uae_national', 'gcc_national')),
  status text not null default 'open' check (status in ('open', 'completed', 'cancelled')),
  mohre_person_code text,
  work_permit_number text,
  uid_number text,
  visa_file_number text,
  notes text,
  opened_by uuid references auth.users(id),
  opened_at timestamptz not null default now(),
  closed_by uuid references auth.users(id),
  closed_at timestamptz,
  close_reason text,
  updated_at timestamptz not null default now()
);
create unique index employee_immigration_cases_one_open on public.employee_immigration_cases (employee_id) where status = 'open';
create index employee_immigration_cases_entity_idx on public.employee_immigration_cases (entity_id, status);

create table public.employee_immigration_steps (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.employee_immigration_cases(id) on delete cascade,
  step_key text not null,
  label text not null,
  sort_order integer not null default 0,
  status text not null default 'not_started' check (status in ('not_started', 'in_progress', 'done', 'not_needed', 'failed')),
  is_blocking boolean not null default false,
  due_date date,
  started_at timestamptz,
  completed_at timestamptz,
  reference_number text,
  expiry_date date,
  notes text,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  unique (case_id, step_key)
);

-- Default steps per track: key, label, blocking, days from case start, tracks.
create or replace function public._imm_step_catalog()
returns table (step_key text, label text, is_blocking boolean, due_days integer, tracks text[], sort_order integer)
language sql immutable set search_path to '' as $$
  select * from (values
    ('mohre_offer_letter', 'MOHRE offer letter signed by the employee', false, 3, array['outside_uae','inside_uae','transfer','own_visa'], 1),
    ('previous_permit_cancelled', 'Previous work permit cancelled / transfer approved', false, 7, array['transfer'], 2),
    ('work_permit', 'Work permit approved (MOHRE)', true, 10, array['outside_uae','inside_uae','transfer','own_visa'], 3),
    ('labour_contract', 'MOHRE labour contract signed', true, 10, array['outside_uae','inside_uae','transfer','own_visa'], 4),
    ('mohre_registration', 'Registered with MOHRE', true, 5, array['uae_national','gcc_national'], 5),
    ('entry_permit', 'Entry permit issued', false, 12, array['outside_uae'], 6),
    ('entered_uae', 'Employee entered the UAE (record the date)', false, 20, array['outside_uae'], 7),
    ('change_of_status', 'Change of visa status done inside the UAE', false, 14, array['inside_uae'], 8),
    ('medical_fitness', 'Medical fitness test passed', false, 25, array['outside_uae','inside_uae','transfer'], 9),
    ('health_insurance', 'Health insurance issued', false, 25, array['outside_uae','inside_uae','transfer','own_visa'], 10),
    ('emirates_id_biometrics', 'Emirates ID application and biometrics', false, 30, array['outside_uae','inside_uae','transfer'], 11),
    ('residence_visa', 'Residence visa issued', false, 45, array['outside_uae','inside_uae','transfer'], 12),
    ('emirates_id_issued', 'Emirates ID received', false, 45, array['outside_uae','inside_uae','transfer'], 13),
    ('pension_registration', 'Pension registration (GPSSA / GCC scheme)', false, 30, array['uae_national','gcc_national'], 14),
    ('wps_registration', 'Added to WPS salary payments', false, 30, array['outside_uae','inside_uae','transfer','own_visa','uae_national','gcc_national'], 15)
  ) as c(step_key, label, is_blocking, due_days, tracks, sort_order);
$$;

create or replace function public._imm_require(p_entity_id uuid)
returns void language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.is_active_user() or not (public.my_role() = 'owner' or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())) then
    raise exception 'Only the owner or entity admin can manage work permits and visas' using errcode = '42501';
  end if;
end;
$$;

create or replace function public._imm_audit(p_case public.employee_immigration_cases, p_record uuid, p_action text, p_old jsonb, p_new jsonb)
returns void language sql security definer set search_path to '' as $$
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values ('employee_immigration_cases', p_record, auth.uid(), p_action, p_old,
          coalesce(p_new, '{}'::jsonb) || jsonb_build_object('immigration_case_id', p_case.id, 'onboarding_instance_id', p_case.onboarding_instance_id),
          p_case.entity_id, p_case.employee_id);
$$;

-- Suggested track from nationality (HR confirms it).
create or replace function public.suggest_immigration_track(p_employee_id uuid)
returns text language sql stable security definer set search_path to '' as $$
  select case
    when lower(btrim(coalesce(e.nationality, ''))) in ('uae', 'emirati', 'united arab emirates') then 'uae_national'
    when lower(btrim(coalesce(e.nationality, ''))) in ('saudi arabia', 'saudi', 'kuwait', 'kuwaiti', 'bahrain', 'bahraini', 'oman', 'omani', 'qatar', 'qatari') then 'gcc_national'
    else 'outside_uae' end
  from public.employees e where e.id = p_employee_id;
$$;

create or replace function public.open_immigration_case(p_employee_id uuid, p_track text, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  e public.employees;
  c public.employee_immigration_cases;
  v_inst uuid;
begin
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  perform public._imm_require(e.entity_id);
  if p_track not in ('outside_uae', 'inside_uae', 'transfer', 'own_visa', 'uae_national', 'gcc_national') then
    raise exception 'Unknown track %', p_track using errcode = '22023';
  end if;
  select * into c from public.employee_immigration_cases where employee_id = e.id and status = 'open';
  if c.id is not null then
    return jsonb_build_object('ok', true, 'already_open', true, 'case_id', c.id);
  end if;
  select id into v_inst from public.onboarding_instances where employee_id = e.id and status not in ('completed', 'cancelled', 'withdrawn')
   order by created_at desc limit 1;
  insert into public.employee_immigration_cases (employee_id, entity_id, onboarding_instance_id, track, notes, opened_by)
  values (e.id, e.entity_id, v_inst, p_track, nullif(btrim(coalesce(p_notes, '')), ''), auth.uid())
  returning * into c;
  insert into public.employee_immigration_steps (case_id, step_key, label, sort_order, is_blocking, due_date)
  select c.id, k.step_key, k.label, k.sort_order, k.is_blocking, (now() at time zone 'Asia/Dubai')::date + k.due_days
    from public._imm_step_catalog() k where p_track = any(k.tracks);
  perform public._imm_audit(c, c.id, 'immigration_case_opened', null, jsonb_build_object('track', p_track));
  if v_inst is not null then perform public._onb_touch(v_inst); perform public._onb_recompute(v_inst); end if;
  return jsonb_build_object('ok', true, 'already_open', false, 'case_id', c.id);
end;
$$;

-- Change the track: steps for the new track are added; steps that no
-- longer apply and were not started are marked not needed.
create or replace function public.change_immigration_track(p_case_id uuid, p_track text, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.employee_immigration_cases;
begin
  select * into c from public.employee_immigration_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  perform public._imm_require(c.entity_id);
  if c.status <> 'open' then raise exception 'This case is closed' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  update public.employee_immigration_cases set track = p_track, updated_at = now() where id = c.id;
  insert into public.employee_immigration_steps (case_id, step_key, label, sort_order, is_blocking, due_date)
  select c.id, k.step_key, k.label, k.sort_order, k.is_blocking, (now() at time zone 'Asia/Dubai')::date + k.due_days
    from public._imm_step_catalog() k where p_track = any(k.tracks)
  on conflict (case_id, step_key) do update set status = case when public.employee_immigration_steps.status = 'not_needed' then 'not_started'
                                                            else public.employee_immigration_steps.status end;
  update public.employee_immigration_steps s set status = 'not_needed', updated_by = auth.uid(), updated_at = now(),
         notes = coalesce(s.notes || ' · ', '') || 'Not needed after track change'
   where s.case_id = c.id and s.status = 'not_started'
     and not exists (select 1 from public._imm_step_catalog() k where k.step_key = s.step_key and p_track = any(k.tracks));
  perform public._imm_audit(c, c.id, 'immigration_track_changed', jsonb_build_object('track', c.track), jsonb_build_object('track', p_track, 'reason', p_reason));
  if c.onboarding_instance_id is not null then perform public._onb_recompute(c.onboarding_instance_id); end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.update_immigration_step(p_step_id uuid, p_status text, p_reference text default null,
  p_expiry_date date default null, p_due_date date default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare s public.employee_immigration_steps; c public.employee_immigration_cases;
begin
  select * into s from public.employee_immigration_steps where id = p_step_id for update;
  if s.id is null then raise exception 'Step not found' using errcode = 'P0002'; end if;
  select * into c from public.employee_immigration_cases where id = s.case_id;
  perform public._imm_require(c.entity_id);
  if c.status <> 'open' then raise exception 'This case is closed' using errcode = '22023'; end if;
  if p_status not in ('not_started', 'in_progress', 'done', 'not_needed', 'failed') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if p_status in ('not_needed', 'failed') and nullif(btrim(coalesce(p_notes, '')), '') is null then
    raise exception 'Add a note saying why' using errcode = '22023';
  end if;
  update public.employee_immigration_steps set status = p_status,
         reference_number = coalesce(nullif(btrim(coalesce(p_reference, '')), ''), reference_number),
         expiry_date = coalesce(p_expiry_date, expiry_date), due_date = coalesce(p_due_date, due_date),
         notes = coalesce(nullif(btrim(coalesce(p_notes, '')), ''), notes),
         started_at = case when p_status = 'in_progress' and started_at is null then now() else started_at end,
         completed_at = case when p_status = 'done' then now() when p_status in ('not_started', 'in_progress') then null else completed_at end,
         updated_by = auth.uid(), updated_at = now()
   where id = s.id;
  -- Key references also live on the case for search.
  if p_status = 'done' and nullif(btrim(coalesce(p_reference, '')), '') is not null then
    update public.employee_immigration_cases set
      work_permit_number = case when s.step_key = 'work_permit' then btrim(p_reference) else work_permit_number end,
      uid_number = case when s.step_key in ('entry_permit', 'residence_visa') and uid_number is null then btrim(p_reference) else uid_number end,
      visa_file_number = case when s.step_key = 'residence_visa' then btrim(p_reference) else visa_file_number end,
      updated_at = now()
     where id = c.id;
  end if;
  perform public._imm_audit(c, s.id, 'immigration_step_updated', jsonb_build_object('step', s.step_key, 'status', s.status),
    jsonb_build_object('step', s.step_key, 'status', p_status, 'reference', p_reference, 'expiry_date', p_expiry_date, 'notes', p_notes));
  if c.onboarding_instance_id is not null then perform public._onb_touch(c.onboarding_instance_id); perform public._onb_recompute(c.onboarding_instance_id); end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

create or replace function public.set_immigration_step_blocking(p_step_id uuid, p_is_blocking boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare s public.employee_immigration_steps; c public.employee_immigration_cases;
begin
  select * into s from public.employee_immigration_steps where id = p_step_id for update;
  if s.id is null then raise exception 'Step not found' using errcode = 'P0002'; end if;
  select * into c from public.employee_immigration_cases where id = s.case_id;
  perform public._imm_require(c.entity_id);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  update public.employee_immigration_steps set is_blocking = p_is_blocking, updated_by = auth.uid(), updated_at = now() where id = s.id;
  perform public._imm_audit(c, s.id, 'immigration_step_blocking_changed', jsonb_build_object('step', s.step_key, 'is_blocking', s.is_blocking),
    jsonb_build_object('step', s.step_key, 'is_blocking', p_is_blocking, 'reason', p_reason));
  if c.onboarding_instance_id is not null then perform public._onb_recompute(c.onboarding_instance_id); end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.update_immigration_case(p_case_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.employee_immigration_cases;
begin
  select * into c from public.employee_immigration_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  perform public._imm_require(c.entity_id);
  update public.employee_immigration_cases set
    mohre_person_code = case when p ? 'mohre_person_code' then nullif(btrim(p ->> 'mohre_person_code'), '') else mohre_person_code end,
    work_permit_number = case when p ? 'work_permit_number' then nullif(btrim(p ->> 'work_permit_number'), '') else work_permit_number end,
    uid_number = case when p ? 'uid_number' then nullif(btrim(p ->> 'uid_number'), '') else uid_number end,
    visa_file_number = case when p ? 'visa_file_number' then nullif(btrim(p ->> 'visa_file_number'), '') else visa_file_number end,
    notes = case when p ? 'notes' then nullif(btrim(p ->> 'notes'), '') else notes end,
    updated_at = now()
   where id = c.id;
  perform public._imm_audit(c, c.id, 'immigration_case_updated', to_jsonb(c) - 'id', p);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.close_immigration_case(p_case_id uuid, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.employee_immigration_cases; v_open text;
begin
  select * into c from public.employee_immigration_cases where id = p_case_id for update;
  if c.id is null then raise exception 'Case not found' using errcode = 'P0002'; end if;
  perform public._imm_require(c.entity_id);
  if c.status <> 'open' then return jsonb_build_object('ok', true, 'already', true); end if;
  if p_status not in ('completed', 'cancelled') then raise exception 'Status must be completed or cancelled' using errcode = '22023'; end if;
  if p_status = 'cancelled' and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if p_status = 'completed' then
    select string_agg(label, ', ' order by sort_order) into v_open from public.employee_immigration_steps
     where case_id = c.id and status not in ('done', 'not_needed');
    if v_open is not null then raise exception 'Still open: %', v_open using errcode = '22023'; end if;
  end if;
  update public.employee_immigration_cases set status = p_status, closed_by = auth.uid(), closed_at = now(),
         close_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now() where id = c.id;
  perform public._imm_audit(c, c.id, 'immigration_case_' || p_status, null, jsonb_build_object('reason', p_reason));
  if c.onboarding_instance_id is not null then perform public._onb_recompute(c.onboarding_instance_id); end if;
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

create or replace function public.get_immigration_case(p_employee_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare e public.employees; c public.employee_immigration_cases;
begin
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  perform public._imm_require(e.entity_id);
  select * into c from public.employee_immigration_cases where employee_id = e.id order by (status = 'open') desc, opened_at desc limit 1;
  return jsonb_build_object('ok', true, 'suggested_track', public.suggest_immigration_track(e.id),
    'case', case when c.id is null then null else to_jsonb(c) end,
    'steps', coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order) from public.employee_immigration_steps s where s.case_id = c.id), '[]'::jsonb));
end;
$$;

create or replace function public.list_immigration_cases(p_entity_id uuid, p_status text default 'open')
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  perform public._imm_require(p_entity_id);
  return coalesce((select jsonb_agg(jsonb_build_object('case_id', c.id, 'employee_id', e.id, 'name', e.full_name, 'track', c.track,
      'status', c.status, 'opened_at', c.opened_at, 'onboarding_instance_id', c.onboarding_instance_id,
      'done', (select count(*) from public.employee_immigration_steps s where s.case_id = c.id and s.status in ('done', 'not_needed')),
      'total', (select count(*) from public.employee_immigration_steps s where s.case_id = c.id),
      'blocking_open', (select count(*) from public.employee_immigration_steps s where s.case_id = c.id and s.is_blocking and s.status not in ('done', 'not_needed')),
      'overdue', (select count(*) from public.employee_immigration_steps s where s.case_id = c.id and s.status not in ('done', 'not_needed') and s.due_date < v_today),
      'next_step', (select s.label from public.employee_immigration_steps s where s.case_id = c.id and s.status not in ('done', 'not_needed') order by s.sort_order limit 1),
      'next_due', (select min(s.due_date) from public.employee_immigration_steps s where s.case_id = c.id and s.status not in ('done', 'not_needed')))
      order by c.opened_at desc)
    from public.employee_immigration_cases c join public.employees e on e.id = c.employee_id
   where c.entity_id = p_entity_id and (p_status = 'all' or c.status = p_status)), '[]'::jsonb);
end;
$$;

-- The employee sees their own progress (labels and status only).
create or replace function public.get_my_immigration()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_emp uuid := public.my_employee_id(); c public.employee_immigration_cases;
begin
  if v_emp is null then raise exception 'No employee record for this login' using errcode = '42501'; end if;
  select * into c from public.employee_immigration_cases where employee_id = v_emp and status = 'open';
  if c.id is null then return jsonb_build_object('ok', true, 'steps', null); end if;
  return jsonb_build_object('ok', true, 'steps', (select jsonb_agg(jsonb_build_object('label', s.label, 'status', s.status, 'completed_at', s.completed_at)
                                                                  order by s.sort_order)
                                                     from public.employee_immigration_steps s where s.case_id = c.id and s.status <> 'not_needed'));
end;
$$;

-- --------------------------------------------- readiness contribution
create or replace function public._onb_extension_checks(p_instance_id uuid, p_audience text)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  c public.employee_immigration_cases;
  b jsonb := '[]'::jsonb;
  w jsonb := '[]'::jsonb;
  s record;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  select * into c from public.employee_immigration_cases where employee_id = i.employee_id and status in ('open', 'completed')
   order by (status = 'open') desc, opened_at desc limit 1;
  if c.id is null then
    if public.suggest_immigration_track(i.employee_id) <> 'uae_national' then
      w := w || jsonb_build_object('code', 'no_immigration_case', 'message', 'Work permit and visa tracking has not been started.');
    end if;
  elsif c.status = 'open' then
    for s in select * from public.employee_immigration_steps where case_id = c.id and status not in ('done', 'not_needed') order by sort_order loop
      if s.is_blocking or s.status = 'failed' then
        b := b || jsonb_build_object('code', 'immigration_' || s.step_key, 'owner_role', 'hr', 'due_date', s.due_date,
          'message', case when p_audience = 'full' then s.label || case when s.status = 'failed' then ': failed.' else ': not done yet.' end
                          else 'Work permit paperwork is outstanding.' end);
      end if;
    end loop;
  end if;
  return jsonb_build_object('blockers', b, 'warnings', w);
end;
$$;

-- --------------------------------------------------------- reminders
create or replace function public._imm_reminders(p_today date)
returns integer language plpgsql security definer set search_path to '' as $$
declare r record; x record; n integer := 0;
begin
  for r in select c.entity_id, count(*) steps, max(p_today - s.due_date) worst, (array_agg(c.id order by s.due_date))[1] first_case,
                  (array_agg(c.employee_id order by s.due_date))[1] first_employee, (array_agg(s.step_key order by s.due_date))[1] first_step
             from public.employee_immigration_steps s join public.employee_immigration_cases c on c.id = s.case_id
            where c.status = 'open' and s.status not in ('done', 'not_needed') and s.due_date < p_today
            group by c.entity_id loop
    for x in select p.id from public.profiles p where p.is_active and p.role = 'entity_admin' and p.entity_id = r.entity_id loop
      perform public.create_notification(r.entity_id, x.id, null, 'immigration_step_overdue', 'Visa / work permit steps overdue',
        format('%s step(s) overdue, oldest %s day(s).', r.steps, r.worst), 'employee_immigration_case', r.first_case,
        case when r.worst >= 3 then 'high' else 'normal' end, format('imm:overdue:%s:%s:%s', r.entity_id, x.id, p_today));
      n := n + 1;
    end loop;
    begin
      perform public.evaluate_workflow_rules('onboarding', 'immigration_step_overdue', r.entity_id, 'employee_immigration_cases', r.first_case,
        jsonb_build_object('employee_id', r.first_employee, 'immigration_case_id', r.first_case, 'step_key', r.first_step, 'days_overdue', r.worst));
    exception when others then raise warning 'workflow immigration_step_overdue failed: %', sqlerrm;
    end;
  end loop;
  return n;
end;
$$;

create or replace function public._onb_extension_reminders(p_today date)
returns integer language sql security definer set search_path to '' as $$ select public._imm_reminders(p_today); $$;

-- --------------------------------------------------------------- RLS
alter table public.employee_immigration_cases enable row level security;
alter table public.employee_immigration_steps enable row level security;
revoke all on public.employee_immigration_cases, public.employee_immigration_steps from anon, authenticated;
grant select on public.employee_immigration_cases, public.employee_immigration_steps to authenticated;
create policy employee_immigration_cases_select on public.employee_immigration_cases for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner'
         or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))));
create policy employee_immigration_steps_select on public.employee_immigration_steps for select to authenticated
  using (exists (select 1 from public.employee_immigration_cases c where c.id = case_id));

do $$
declare f text;
begin
  foreach f in array array['_imm_step_catalog()', '_imm_require(uuid)', '_imm_reminders(date)', 'suggest_immigration_track(uuid)',
    '_imm_audit(public.employee_immigration_cases, uuid, text, jsonb, jsonb)', '_onb_extension_checks(uuid, text)',
    '_onb_extension_reminders(date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['open_immigration_case(uuid, text, text)',
    'change_immigration_track(uuid, text, text)', 'update_immigration_step(uuid, text, text, date, date, text)',
    'set_immigration_step_blocking(uuid, boolean, text)', 'update_immigration_case(uuid, jsonb)',
    'close_immigration_case(uuid, text, text)', 'get_immigration_case(uuid)', 'list_immigration_cases(uuid, text)',
    'get_my_immigration()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

commit;
