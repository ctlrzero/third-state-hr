-- =====================================================================
-- Migration 007 — Build E: day one, closure, probation and reports.
-- Depends on: 001–006.
-- =====================================================================

begin;

-- ------------------------------------------------------------ day one
-- started  → day_one (then in_progress once day-one tasks are done)
-- no_show  → blocking exception for HR; employee stays active until HR decides
-- delayed  → new start date; the probation window moves with it
create or replace function public.record_day_one_outcome(p_instance_id uuid, p_outcome text, p_new_start_date date default null,
  p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  s public.onboarding_settings;
  v_end date;
begin
  perform public._onb_require(p_instance_id, 'operate');
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status not in ('activated', 'day_one') then raise exception 'Day one is recorded after activation' using errcode = '22023'; end if;
  if p_outcome not in ('started', 'no_show', 'delayed') then raise exception 'Outcome must be started, no_show or delayed' using errcode = '22023'; end if;
  if p_outcome <> 'started' and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if i.day_one_outcome = 'started' then return jsonb_build_object('ok', true, 'already', true); end if;

  update public.onboarding_instances set day_one_outcome = p_outcome, day_one_recorded_at = now(), day_one_recorded_by = auth.uid()
   where id = i.id;
  if p_outcome = 'started' then
    update public.onboarding_instances set actual_start_date = coalesce(actual_start_date, proposed_start_date) where id = i.id;
    perform public._onb_set_status(i.id, 'day_one', 'Employee started');
    perform public._onb_advance_post_start(i.id);  -- day-one tasks may already be done
  elsif p_outcome = 'no_show' then
    insert into public.onboarding_exceptions (instance_id, exception_type, description, owner_role, due_date, raised_by)
    values (i.id, 'no_show', btrim(p_reason), 'hr', (now() at time zone 'Asia/Dubai')::date + 1, auth.uid());
  else
    if p_new_start_date is null or p_new_start_date <= coalesce(i.actual_start_date, i.proposed_start_date) then
      raise exception 'Give the new (later) start date' using errcode = '22023';
    end if;
    s := public._onb_settings(i.entity_id);
    update public.onboarding_instances set actual_start_date = p_new_start_date, proposed_start_date = p_new_start_date,
           day_one_outcome = null where id = i.id;
    update public.employees set join_date = p_new_start_date, updated_at = now() where id = i.employee_id;
    if s.probation_months > 0 then
      v_end := (p_new_start_date + make_interval(months => s.probation_months))::date - 1;
      update public.employee_probation_periods set start_date = p_new_start_date, end_date = v_end,
             review_due_date = greatest(p_new_start_date, v_end - s.probation_review_days_before), updated_at = now()
       where onboarding_instance_id = i.id and status = 'active' and previous_period_id is null;
      update public.employees set probation_end_date = v_end where id = i.employee_id;
    end if;
    update public.onboarding_tasks t set due_date = t.due_date + (p_new_start_date - coalesce(i.actual_start_date, i.proposed_start_date))
     where t.instance_id = i.id and t.phase <> 'pre_activation' and t.status not in ('approved', 'waived', 'cancelled');
    insert into public.onboarding_exceptions (instance_id, exception_type, is_blocking, description, owner_role, raised_by, status,
      resolution, resolved_by, resolved_at)
    values (i.id, 'delayed_start', false, btrim(p_reason), 'hr', auth.uid(), 'resolved',
      'Start moved to ' || p_new_start_date, auth.uid(), now());
  end if;
  perform public._onb_audit(i.id, 'onboarding_instances', i.id, 'onboarding_day_one_recorded', null,
    jsonb_build_object('outcome', p_outcome, 'new_start_date', p_new_start_date, 'reason', p_reason));
  perform public._onb_touch(i.id);
  return jsonb_build_object('ok', true, 'already', false, 'outcome', p_outcome);
end;
$$;

-- Moves day_one → in_progress when every required day-one task is done.
create or replace function public._onb_advance_post_start(p_instance_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.status = 'day_one' and not exists (select 1 from public.onboarding_tasks where instance_id = i.id and phase = 'day_one'
       and is_required and status not in ('approved', 'waived', 'cancelled')) then
    perform public._onb_set_status(i.id, 'in_progress', 'Day-one tasks complete');
  end if;
end;
$$;

create or replace function public.trg_onb_task_post_start()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.phase = 'day_one' and new.status in ('approved', 'waived') and old.status is distinct from new.status then
    perform public._onb_advance_post_start(new.instance_id);
  end if;
  return new;
end;
$$;
drop trigger if exists onboarding_task_post_start on public.onboarding_tasks;
create trigger onboarding_task_post_start after update of status on public.onboarding_tasks
  for each row execute function public.trg_onb_task_post_start();

-- ------------------------------------------------------------ closure
create or replace function public.close_onboarding(p_instance_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare i public.onboarding_instances; v_open text; v_snap jsonb;
begin
  perform public._onb_require(p_instance_id, 'manage');
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.status = 'completed' then return jsonb_build_object('ok', true, 'already', true); end if;
  if i.status not in ('day_one', 'in_progress') then raise exception 'Onboarding closes after the employee has started' using errcode = '22023'; end if;
  select string_agg(item_label, ', ') into v_open from public.onboarding_tasks
   where instance_id = i.id and is_required and status not in ('approved', 'waived', 'cancelled');
  if v_open is not null then raise exception 'Still open: %', v_open using errcode = '22023'; end if;
  if exists (select 1 from public.onboarding_exceptions where instance_id = i.id and status = 'open') then
    raise exception 'Resolve the open exceptions first' using errcode = '22023';
  end if;
  v_snap := jsonb_build_object(
    'closed_at', now(), 'notes', p_notes, 'activated_at', i.activated_at, 'actual_start_date', i.actual_start_date,
    'days_to_activate', extract(day from (i.activated_at - i.started_at))::integer,
    'tasks', (select jsonb_object_agg(status, n) from (select status, count(*) n from public.onboarding_tasks where instance_id = i.id group by status) x),
    'reviews', (select count(*) from public.onboarding_reviews where instance_id = i.id),
    'changes_requested', (select count(*) from public.onboarding_reviews where instance_id = i.id and decision <> 'approved'),
    'exceptions', (select count(*) from public.onboarding_exceptions where instance_id = i.id));
  perform public._onb_set_status(i.id, 'completed', p_notes);
  update public.onboarding_instances set completed_at = now(), closed_by = auth.uid(), closure_snapshot = v_snap where id = i.id;
  perform public._onb_audit(i.id, 'onboarding_instances', i.id, 'onboarding_completed', null, v_snap);
  return jsonb_build_object('ok', true, 'already', false, 'summary', v_snap);
end;
$$;

-- ---------------------------------------------------------- probation
create or replace function public._onb_probation_scope(p_period_id uuid, p_cap text)
returns public.employee_probation_periods language plpgsql stable security definer set search_path to '' as $$
declare pp public.employee_probation_periods; e public.employees; v_role public.user_role := public.my_role();
begin
  select * into pp from public.employee_probation_periods where id = p_period_id;
  if pp.id is null then raise exception 'Probation period not found' using errcode = 'P0002'; end if;
  select * into e from public.employees where id = pp.employee_id;
  if not public.is_active_user() or e.id = public.my_employee_id() or not (
       v_role = 'owner' or (v_role = 'entity_admin' and e.entity_id = public.my_entity())
       or (p_cap = 'review' and v_role = 'location_manager' and e.home_location_id = public.my_location())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return pp;
end;
$$;

create or replace function public.record_probation_review(p_period_id uuid, p_recommendation text, p_comments text, p_ratings jsonb default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare pp public.employee_probation_periods; v_id uuid;
begin
  pp := public._onb_probation_scope(p_period_id, 'review');
  if pp.status not in ('active', 'extended') then raise exception 'This probation is already decided' using errcode = '22023'; end if;
  insert into public.employee_probation_reviews (probation_period_id, reviewer_id, reviewer_role, recommendation, comments, ratings)
  values (pp.id, auth.uid(), public.my_role()::text, p_recommendation, p_comments, p_ratings) returning id into v_id;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_probation_reviews', v_id, auth.uid(), 'probation_review_recorded',
    jsonb_build_object('period_id', pp.id, 'recommendation', p_recommendation), public.payroll_employee_entity(pp.employee_id), pp.employee_id);
  return jsonb_build_object('ok', true, 'review_id', v_id);
end;
$$;

-- Decision: confirmed / extended (total ≤ 6 months from the first start) / not_confirmed.
-- not_confirmed never ends employment by itself: it opens an HR exception
-- (notice under Art. 9 is handled in the offboarding process).
create or replace function public.decide_probation_outcome(p_period_id uuid, p_outcome text, p_effective_date date,
  p_new_end_date date default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  pp public.employee_probation_periods;
  v_first date;
  v_new uuid;
  v_inst uuid;
  s public.onboarding_settings;
begin
  pp := public._onb_probation_scope(p_period_id, 'decide');
  select * into pp from public.employee_probation_periods where id = pp.id for update;
  if pp.status <> 'active' then raise exception 'This probation is already decided' using errcode = '22023'; end if;
  if p_outcome not in ('confirmed', 'extended', 'not_confirmed') then raise exception 'Unknown outcome' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null and p_outcome <> 'confirmed' then raise exception 'A reason is required' using errcode = '22023'; end if;
  if not exists (select 1 from public.employee_probation_reviews where probation_period_id = pp.id) then
    raise exception 'Record at least one probation review first' using errcode = '22023';
  end if;
  if public.my_role() <> 'owner' and not exists (select 1 from public.employee_probation_reviews
       where probation_period_id = pp.id and reviewer_id <> auth.uid()) then
    raise exception 'The decision needs a review from someone other than you' using errcode = '42501';
  end if;
  -- Earliest start in the chain of periods.
  with recursive chain as (
    select id, start_date, previous_period_id from public.employee_probation_periods where id = pp.id
    union all
    select p.id, p.start_date, p.previous_period_id from public.employee_probation_periods p join chain c on p.id = c.previous_period_id)
  select min(start_date) into v_first from chain;

  update public.employee_probation_periods set status = p_outcome, decided_by = auth.uid(), decided_at = now(),
         decision_effective_date = coalesce(p_effective_date, (now() at time zone 'Asia/Dubai')::date),
         decision_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now()
   where id = pp.id;

  if p_outcome = 'confirmed' then
    update public.employees set probation_end_date = least(coalesce(p_effective_date, pp.end_date), pp.end_date) where id = pp.employee_id;
  elsif p_outcome = 'extended' then
    if p_new_end_date is null or p_new_end_date <= pp.end_date then raise exception 'Give a later end date' using errcode = '22023'; end if;
    if p_new_end_date > (v_first + interval '6 months')::date - 1 then
      raise exception 'Probation cannot exceed six months in total (UAE Decree-Law 33/2021 Art. 9); latest end is %',
        (v_first + interval '6 months')::date - 1 using errcode = '22023';
    end if;
    select * into s from public.onboarding_settings where entity_id = public.payroll_employee_entity(pp.employee_id);
    insert into public.employee_probation_periods (employee_id, onboarding_instance_id, start_date, end_date, review_due_date, previous_period_id)
    values (pp.employee_id, pp.onboarding_instance_id, pp.end_date + 1, p_new_end_date,
            greatest(pp.end_date + 1, p_new_end_date - coalesce(s.probation_review_days_before, 14)), pp.id)
    returning id into v_new;
    update public.employees set probation_end_date = p_new_end_date where id = pp.employee_id;
  else
    select id into v_inst from public.onboarding_instances where employee_id = pp.employee_id order by created_at desc limit 1;
    if v_inst is not null then
      insert into public.onboarding_exceptions (instance_id, exception_type, description, owner_role, raised_by, due_date)
      values (v_inst, 'probation_not_confirmed', 'Probation not confirmed: ' || btrim(p_reason) || '. Start offboarding with the required notice.',
              'hr', auth.uid(), coalesce(p_effective_date, (now() at time zone 'Asia/Dubai')::date));
    end if;
  end if;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_probation_periods', pp.id, auth.uid(), 'probation_' || p_outcome,
    jsonb_build_object('effective_date', p_effective_date, 'new_end_date', p_new_end_date, 'new_period_id', v_new, 'reason', p_reason),
    public.payroll_employee_entity(pp.employee_id), pp.employee_id);
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'new_period_id', v_new);
end;
$$;

create or replace function public.list_probation_due(p_entity_id uuid, p_within_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_role public.user_role := public.my_role(); v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('period_id', pp.id, 'employee_id', e.id, 'full_name', e.full_name,
      'location', l.name, 'start_date', pp.start_date, 'end_date', pp.end_date, 'review_due_date', pp.review_due_date,
      'is_extension', pp.previous_period_id is not null,
      'reviews', (select count(*) from public.employee_probation_reviews r where r.probation_period_id = pp.id),
      'overdue', pp.review_due_date < v_today) order by pp.review_due_date)
    from public.employee_probation_periods pp join public.employees e on e.id = pp.employee_id
    left join public.locations l on l.id = e.home_location_id
   where e.entity_id = p_entity_id and pp.status = 'active' and e.employment_status = 'active'
     and pp.review_due_date <= v_today + p_within_days
     and (v_role <> 'location_manager' or e.home_location_id = public.my_location())), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------ reports
-- kind: funnel | ageing | blocked_reasons | starting_soon | overdue_tasks | invitations
--       | document_rejections | day_one | probation_due | time_to_activate
create or replace function public.onboarding_report(p_entity_id uuid, p_kind text, p_from date default null, p_to date default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_role public.user_role := public.my_role();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_from date := coalesce(p_from, v_today - 90);
  v_to date := coalesce(p_to, v_today);
  r jsonb;
begin
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  create temp table if not exists _onb_rep_scope (id uuid primary key) on commit drop;
  truncate _onb_rep_scope;
  insert into _onb_rep_scope select i.id from public.onboarding_instances i
   where i.entity_id = p_entity_id and (v_role <> 'location_manager' or i.home_location_id = public.my_location());

  if p_kind = 'funnel' then
    select jsonb_object_agg(status, n) into r from (select i.status, count(*) n from public.onboarding_instances i
      join _onb_rep_scope s on s.id = i.id where (i.started_at at time zone 'Asia/Dubai')::date between v_from and v_to group by i.status) x;
  elsif p_kind = 'ageing' then
    select jsonb_agg(jsonb_build_object('instance_id', i.id, 'employee', e.full_name, 'status', i.status,
             'days_open', v_today - (i.started_at at time zone 'Asia/Dubai')::date, 'days_in_status', v_today - (i.status_changed_at at time zone 'Asia/Dubai')::date)
             order by i.started_at) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id join public.employees e on e.id = i.employee_id
     where i.status not in ('completed', 'cancelled', 'withdrawn');
  elsif p_kind = 'blocked_reasons' then
    select jsonb_agg(jsonb_build_object('code', code, 'count', n) order by n desc) into r from (
      select b ->> 'code' code, count(*) n from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id
       cross join lateral jsonb_array_elements(public._onb_readiness(i.id, 'operations') -> 'blockers') b
       where i.status in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked') group by 1) x;
  elsif p_kind = 'starting_soon' then
    select jsonb_agg(jsonb_build_object('instance_id', i.id, 'employee', e.full_name, 'start_date', i.proposed_start_date, 'status', i.status,
             'blocking', (public._onb_readiness(i.id, 'operations') ->> 'blocking_count')::integer) order by i.proposed_start_date) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id join public.employees e on e.id = i.employee_id
     where i.status not in ('completed', 'cancelled', 'withdrawn') and i.proposed_start_date between v_today and v_today + 14;
  elsif p_kind = 'overdue_tasks' then
    select jsonb_agg(jsonb_build_object('task_id', t.id, 'instance_id', t.instance_id, 'employee', e.full_name, 'task', t.item_label,
             'owner_role', t.owner_role, 'due_date', t.due_date, 'days_overdue', v_today - t.due_date) order by t.due_date) into r
      from public.onboarding_tasks t join _onb_rep_scope s on s.id = t.instance_id join public.onboarding_instances i on i.id = t.instance_id
      join public.employees e on e.id = i.employee_id
     where t.status not in ('approved', 'waived', 'cancelled') and t.due_date < v_today and i.status not in ('completed', 'cancelled', 'withdrawn');
  elsif p_kind = 'invitations' then
    select jsonb_object_agg(status, n) into r from (select v.status, count(*) n from public.onboarding_invitations v
      join _onb_rep_scope s on s.id = v.instance_id where (v.issued_at at time zone 'Asia/Dubai')::date between v_from and v_to group by v.status) x;
  elsif p_kind = 'document_rejections' then
    select jsonb_agg(jsonb_build_object('doc_type', doc_type, 'rejected', n) order by n desc) into r from (
      select d.doc_type, count(*) n from public.employee_documents d join public.onboarding_instances i on i.employee_id = d.employee_id
        join _onb_rep_scope s on s.id = i.id
       where d.review_status = 'rejected' and (d.submitted_at at time zone 'Asia/Dubai')::date between v_from and v_to
         and (v_role <> 'location_manager' or not public.is_restricted_doc_type(d.doc_type))
       group by d.doc_type) x;
  elsif p_kind = 'day_one' then
    select jsonb_build_object('started', count(*) filter (where day_one_outcome = 'started'),
             'no_show', count(*) filter (where day_one_outcome = 'no_show'),
             'delayed', (select count(*) from public.onboarding_exceptions x join _onb_rep_scope s on s.id = x.instance_id where x.exception_type = 'delayed_start'),
             'not_recorded', count(*) filter (where status = 'activated' and actual_start_date < v_today)) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id
     where coalesce(i.actual_start_date, i.proposed_start_date) between v_from and v_to;
  elsif p_kind = 'probation_due' then
    r := public.list_probation_due(p_entity_id, 30);
  elsif p_kind = 'time_to_activate' then
    select jsonb_build_object('activated', count(*),
             'avg_days', round(avg(extract(epoch from (activated_at - started_at)) / 86400)::numeric, 1),
             'max_days', round(max(extract(epoch from (activated_at - started_at)) / 86400)::numeric, 1),
             'activated_after_start_date', count(*) filter (where (activated_at at time zone 'Asia/Dubai')::date > proposed_start_date)) into r
      from public.onboarding_instances i join _onb_rep_scope s on s.id = i.id
     where activated_at is not null and (activated_at at time zone 'Asia/Dubai')::date between v_from and v_to;
  else
    raise exception 'Unknown report %', p_kind using errcode = '22023';
  end if;
  return jsonb_build_object('kind', p_kind, 'from', v_from, 'to', v_to, 'data', coalesce(r, '[]'::jsonb));
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['_onb_advance_post_start(uuid)', 'trg_onb_task_post_start()', '_onb_probation_scope(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['record_day_one_outcome(uuid, text, date, text)', 'close_onboarding(uuid, text)',
    'record_probation_review(uuid, text, text, jsonb)', 'decide_probation_outcome(uuid, text, date, date, text)',
    'list_probation_due(uuid, integer)', 'onboarding_report(uuid, text, date, date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

commit;
