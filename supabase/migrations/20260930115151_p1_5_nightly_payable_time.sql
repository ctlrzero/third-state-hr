-- P1-5 Nightly payable time + missing clock-out suggestions.
--
-- - _seed_payable_shift_records_core: the insert behind seed_payable_shift_records
--   without the role check (a cron job has auth.uid() = null, so the public RPC
--   would refuse it). Same maths as the public RPC; cancelled shifts skipped.
--   Also refreshes the default of still-pending, never-overridden payable rows
--   whose attendance has since been closed (e.g. a confirmed clock-out).
-- - clock_out_suggestions: one row per open attendance record from an earlier
--   Dubai day. Suggested clock-out = shift planned end (null when there is no
--   shift). NEVER applied automatically: a manager confirms, changes or dismisses.
-- - run_nightly_payable_time(p_force): system job, 00:30 Dubai (20:30 UTC).
--   Per active branch, in its own sub-transaction (one failing branch doesn't
--   stop the others). Logged in system_job_runs as 'nightly_payable_time'.
-- - get_clock_out_suggestions / confirm_clock_out_suggestion /
--   dismiss_clock_out_suggestion: manager-facing RPCs.

create table public.clock_out_suggestions (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid not null unique references public.attendance_records(id) on delete cascade,
  entity_id uuid not null references public.entities(id),
  location_id uuid not null references public.locations(id),
  employee_id uuid not null references public.employees(id),
  shift_id uuid references public.shifts(id) on delete set null,
  work_date date not null,
  suggested_clock_out_at timestamptz,
  reason text not null default 'Forgot to clock out — set to planned end',
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'dismissed', 'resolved')),
  applied_clock_out_at timestamptz,
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.clock_out_suggestions is
  'P1-5: suggested clock-out for an open attendance record. Never auto-applied. '
  'resolved = the record was closed another way before anyone confirmed.';
create index clock_out_suggestions_location_pending_idx
  on public.clock_out_suggestions (location_id) where status = 'pending';

alter table public.clock_out_suggestions enable row level security;
revoke all on public.clock_out_suggestions from public, anon, authenticated;
-- No policies: read through get_clock_out_suggestions, write through the RPCs.

-- ---------------------------------------------------------------------------
create or replace function public._seed_payable_shift_records_core(
  p_location_id uuid, p_period_start date, p_period_end date)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_seeded int;
  v_refreshed int;
begin
  with inserted as (
    insert into public.payable_shift_records (
      shift_id, employee_id, entity_id, location_id,
      planned_minutes, planned_break_minutes, default_payable_minutes, status)
    select s.id, s.employee_id, s.entity_id, s.location_id,
      case when s.end_time >= s.start_time
        then extract(epoch from (s.end_time - s.start_time))::integer / 60
        else extract(epoch from (s.end_time - s.start_time + interval '24 hours'))::integer / 60 end,
      0,
      coalesce(
        (select round(extract(epoch from (ar.clock_out_at - ar.clock_in_at)) / 60)::integer
           from public.attendance_records ar
          where ar.shift_id = s.id and ar.clock_out_at is not null
          order by ar.clock_out_at desc limit 1),
        case when s.end_time >= s.start_time
          then extract(epoch from (s.end_time - s.start_time))::integer / 60
          else extract(epoch from (s.end_time - s.start_time + interval '24 hours'))::integer / 60 end),
      'pending'
    from public.shifts s
    where s.location_id = p_location_id
      and s.shift_date between p_period_start and p_period_end
      and s.is_published = true
      and s.employee_id is not null
      and s.status <> 'cancelled'
    on conflict (shift_id) do nothing
    returning 1
  )
  select count(*) into v_seeded from inserted;

  -- A pending row seeded while the shift was still open got the planned
  -- minutes; once the clock-out is known, follow the actual time. Rows that
  -- were adjusted, overridden or materialized are never touched.
  with src as (
    select p.id,
      (select round(extract(epoch from (ar.clock_out_at - ar.clock_in_at)) / 60)::integer
         from public.attendance_records ar
        where ar.shift_id = p.shift_id and ar.clock_out_at is not null
        order by ar.clock_out_at desc limit 1) as mins
    from public.payable_shift_records p
    join public.shifts s on s.id = p.shift_id
    where p.location_id = p_location_id
      and s.shift_date between p_period_start and p_period_end
      and p.status = 'pending' and p.final_payable_minutes is null
  ), upd as (
    update public.payable_shift_records p
       set default_payable_minutes = src.mins, updated_at = now()
      from src
     where p.id = src.id and src.mins is not null and src.mins >= 0
       and p.default_payable_minutes is distinct from src.mins
    returning 1
  )
  select count(*) into v_refreshed from upd;

  return jsonb_build_object('seeded', v_seeded, 'refreshed', v_refreshed);
end;
$$;
revoke all on function public._seed_payable_shift_records_core(uuid, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
create or replace function public._create_clock_out_suggestions(p_location_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_created int;
  v_resolved int;
begin
  -- Close suggestions whose record got a clock-out some other way.
  with r as (
    update public.clock_out_suggestions c
       set status = 'resolved', decided_at = now()
      from public.attendance_records a
     where a.id = c.attendance_record_id and c.location_id = p_location_id
       and c.status = 'pending' and a.clock_out_at is not null
    returning 1
  )
  select count(*) into v_resolved from r;

  with ins as (
    insert into public.clock_out_suggestions (
      attendance_record_id, entity_id, location_id, employee_id, shift_id, work_date, suggested_clock_out_at)
    select a.id, a.entity_id, a.location_id, a.employee_id, a.shift_id,
           coalesce(s.shift_date, (a.clock_in_at at time zone 'Asia/Dubai')::date),
           case when b.planned_end > a.clock_in_at then b.planned_end end
    from public.attendance_records a
    left join public.shifts s on s.id = a.shift_id
    left join lateral public._shift_planned_bounds(s.shift_date, s.start_time, s.end_time) b on s.id is not null
    where a.location_id = p_location_id
      and a.clock_out_at is null
      and (a.clock_in_at at time zone 'Asia/Dubai')::date < v_today
      -- an overnight shift still running is not a missing clock-out yet
      and (s.id is null or b.planned_end <= now())
    on conflict (attendance_record_id) do nothing
    returning 1
  )
  select count(*) into v_created from ins;

  return jsonb_build_object('suggestions_created', v_created, 'suggestions_resolved', v_resolved);
end;
$$;
revoke all on function public._create_clock_out_suggestions(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.run_nightly_payable_time(p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_day date := (now() at time zone 'Asia/Dubai')::date - 1;
  v_loc record;
  v_branches jsonb := '[]'::jsonb;
  v_failed int := 0;
  v_total int := 0;
  v_pay jsonb;
  v_sug jsonb;
begin
  if auth.uid() is not null or coalesce(current_setting('request.jwt.claims', true), '') not in ('', 'null') then
    raise exception 'System job only' using errcode = '42501';
  end if;

  if exists (select 1 from public.system_job_runs where job = 'nightly_payable_time' and run_date = v_today) then
    if not coalesce(p_force, false) then
      return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'Already ran today', 'run_date', v_today);
    end if;
    update public.system_job_runs set started_at = now(), finished_at = null, status = 'running', result = '{}'::jsonb
     where job = 'nightly_payable_time' and run_date = v_today;
  else
    insert into public.system_job_runs (job, run_date) values ('nightly_payable_time', v_today);
  end if;

  for v_loc in select id, name from public.locations where is_active order by name loop
    v_total := v_total + 1;
    begin
      v_pay := public._seed_payable_shift_records_core(v_loc.id, v_day, v_day);
      v_sug := public._create_clock_out_suggestions(v_loc.id);
      v_branches := v_branches || jsonb_build_array(
        jsonb_build_object('location_id', v_loc.id, 'name', v_loc.name) || v_pay || v_sug);
    exception when others then
      v_failed := v_failed + 1;
      v_branches := v_branches || jsonb_build_array(jsonb_build_object(
        'location_id', v_loc.id, 'name', v_loc.name, 'error', sqlerrm, 'sqlstate', sqlstate));
      raise warning 'nightly_payable_time: branch % failed: %', v_loc.id, sqlerrm;
    end;
  end loop;

  update public.system_job_runs
     set finished_at = now(),
         status = case when v_failed = 0 then 'ok' when v_failed = v_total then 'failed' else 'partial' end,
         result = jsonb_build_object('work_date', v_day, 'branches', v_branches)
   where job = 'nightly_payable_time' and run_date = v_today;

  return jsonb_build_object('ok', v_failed = 0, 'run_date', v_today, 'work_date', v_day,
    'failed_branches', v_failed, 'branches', v_branches);
end;
$$;
revoke all on function public.run_nightly_payable_time(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
create or replace function public._can_manage_attendance_branch(p_entity_id uuid, p_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(
    public.my_role() = 'owner'
    or (public.my_role() = 'entity_admin' and p_entity_id = public.my_entity())
    or (public.my_role() in ('location_manager', 'shift_supervisor') and p_location_id = public.my_location()),
    false);
$$;
revoke all on function public._can_manage_attendance_branch(uuid, uuid) from public, anon, authenticated;

create or replace function public.get_clock_out_suggestions(p_location_id uuid)
returns table (
  id uuid, attendance_record_id uuid, employee_id uuid, employee_name text, shift_id uuid,
  work_date date, clock_in_at timestamptz, suggested_clock_out_at timestamptz, reason text,
  status text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_entity uuid;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select l.entity_id into v_entity from public.locations l where l.id = p_location_id;
  if v_entity is null then
    raise exception 'Location not found';
  end if;
  if not public._can_manage_attendance_branch(v_entity, p_location_id) then
    raise exception using errcode = '42501', message = 'Not authorized to view attendance for this branch';
  end if;

  return query
  select c.id, c.attendance_record_id, c.employee_id, coalesce(e.preferred_name, e.full_name), c.shift_id,
         c.work_date, a.clock_in_at, c.suggested_clock_out_at, c.reason, c.status, c.created_at
  from public.clock_out_suggestions c
  join public.attendance_records a on a.id = c.attendance_record_id
  join public.employees e on e.id = c.employee_id
  where c.location_id = p_location_id
    and c.status = 'pending'
    and a.clock_out_at is null
  order by c.work_date desc, e.full_name;
end;
$$;
revoke all on function public.get_clock_out_suggestions(uuid) from public, anon;
grant execute on function public.get_clock_out_suggestions(uuid) to authenticated;

create or replace function public.confirm_clock_out_suggestion(
  p_id uuid, p_clock_out_at timestamptz default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_s public.clock_out_suggestions;
  v_a public.attendance_records;
  v_out timestamptz;
  v_reason text;
  v_day date;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authorized';
  end if;

  select * into v_s from public.clock_out_suggestions where id = p_id for update;
  if v_s.id is null then
    raise exception 'Suggestion not found';
  end if;
  if not public._can_manage_attendance_branch(v_s.entity_id, v_s.location_id) then
    raise exception using errcode = '42501', message = 'Not authorized to correct attendance for this branch';
  end if;
  if v_s.status <> 'pending' then
    raise exception 'This suggestion was already %', v_s.status;
  end if;

  select * into v_a from public.attendance_records where id = v_s.attendance_record_id;
  if v_a.employee_id = public.my_employee_id() then
    raise exception using errcode = '42501', message = 'You cannot confirm your own clock-out. Ask another manager.';
  end if;
  if v_a.clock_out_at is not null then
    update public.clock_out_suggestions set status = 'resolved', decided_at = now() where id = p_id;
    raise exception 'This clock-in already has a clock-out';
  end if;

  v_out := coalesce(p_clock_out_at, v_s.suggested_clock_out_at);
  if v_out is null then
    raise exception 'Choose a clock-out time — there is no planned end to suggest';
  end if;
  v_reason := coalesce(nullif(btrim(p_reason), ''), v_s.reason);

  -- Same rules as any manual correction: branch scope, clock-out after
  -- clock-in, not in the future, original kept, audit row.
  perform public.correct_attendance_record(v_a.id, null, v_out, v_reason);

  update public.clock_out_suggestions
     set status = 'confirmed', applied_clock_out_at = v_out, decided_by = auth.uid(), decided_at = now()
   where id = p_id;

  -- Payable time for that shift follows the confirmed clock-out (pending rows only).
  if v_a.shift_id is not null then
    select shift_date into v_day from public.shifts where id = v_a.shift_id;
    perform public._seed_payable_shift_records_core(v_a.location_id, v_day, v_day);
  end if;

  return jsonb_build_object('ok', true, 'id', p_id, 'attendance_record_id', v_a.id, 'clock_out_at', v_out);
end;
$$;
revoke all on function public.confirm_clock_out_suggestion(uuid, timestamptz, text) from public, anon;
grant execute on function public.confirm_clock_out_suggestion(uuid, timestamptz, text) to authenticated;

create or replace function public.dismiss_clock_out_suggestion(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_s public.clock_out_suggestions;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authorized';
  end if;
  select * into v_s from public.clock_out_suggestions where id = p_id for update;
  if v_s.id is null then
    raise exception 'Suggestion not found';
  end if;
  if not public._can_manage_attendance_branch(v_s.entity_id, v_s.location_id) then
    raise exception using errcode = '42501', message = 'Not authorized to correct attendance for this branch';
  end if;
  if v_s.status <> 'pending' then
    raise exception 'This suggestion was already %', v_s.status;
  end if;
  update public.clock_out_suggestions
     set status = 'dismissed', decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('clock_out_suggestions', p_id, auth.uid(), 'clock_out_suggestion_dismissed',
    jsonb_build_object('attendance_record_id', v_s.attendance_record_id, 'suggested_clock_out_at', v_s.suggested_clock_out_at),
    v_s.entity_id, v_s.location_id, v_s.employee_id);
  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;
revoke all on function public.dismiss_clock_out_suggestion(uuid) from public, anon;
grant execute on function public.dismiss_clock_out_suggestion(uuid) to authenticated;

-- 00:30 Dubai = 20:30 UTC
select cron.unschedule(jobid) from cron.job where jobname = 'nightly-payable-time';
select cron.schedule('nightly-payable-time', '30 20 * * *', 'select public.run_nightly_payable_time();');
