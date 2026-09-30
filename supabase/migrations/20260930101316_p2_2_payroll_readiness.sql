-- P2-2: Pre-payroll readiness (read-only, no AI).
-- get_payroll_readiness(period) returns one checklist of what still blocks a payroll month: the payroll
-- engine's own per-employee attention items plus the HR inputs that feed pay (pending leave, missing
-- clock-outs, shifts without attendance, pending payable-time adjustments, unverified payment details,
-- draft shifts). Names and counts only — no pay amounts. It changes nothing.
-- run_payroll_readiness_reminders (cron, 08:00 Dubai) notifies the payroll team from 3 days before pay
-- day, daily, until every record is approved — including when the month hasn't been opened yet.

create or replace function public._payroll_pay_date(p_period_id uuid)
returns date
language sql
stable
security definer
set search_path to ''
as $function$
  -- Regular month: pay day of the following month (payroll_settings.pay_day). Off-cycle: its own date.
  select case when p.kind = 'regular'
              then (date_trunc('month', p.period_end) + interval '1 month')::date
                   + (coalesce((public._payroll_settings(p.entity_id, p.period_start)).pay_day, 1) - 1)
              else p.period_end end
  from public.payroll_periods p where p.id = p_period_id;
$function$;
revoke all on function public._payroll_pay_date(uuid) from public, anon, authenticated;

create or replace function public._payroll_readiness(p_period_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  p public.payroll_periods;
  s public.payroll_settings;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_pay_date date;
  v_items jsonb := '[]'::jsonb;
  v_people jsonb;
  v_n int;
  v_total int;
  v_approved int;
  r record;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if p.id is null then
    raise exception using errcode = 'P0002', message = 'Payroll month not found';
  end if;
  s := public._payroll_settings(p.entity_id, p.period_start);
  v_pay_date := public._payroll_pay_date(p.id);

  -- Payroll settings
  if s.id is null or not coalesce(s.confirmed, false) then
    v_items := v_items || jsonb_build_object('key', 'settings_unconfirmed', 'severity', 'warning', 'count', 1,
      'title', 'Payroll settings not confirmed', 'people', '[]'::jsonb, 'link', '/payroll', 'action', 'Open settings');
  end if;

  -- Eligible employees with no payroll record yet (regular months only)
  if p.kind = 'regular' then
    select count(*), coalesce(jsonb_agg(x.name order by x.name) filter (where x.rn <= 8), '[]'::jsonb) into v_n, v_people
    from (select e.full_name as name, row_number() over (order by e.full_name) rn
          from public.employees e
          where e.entity_id = p.entity_id and public._payroll_ineligible_reason(e.id, p.id) is null
            and not exists (select 1 from public.payroll_records pr where pr.period_id = p.id and pr.employee_id = e.id)) x;
    if v_n > 0 then
      v_items := v_items || jsonb_build_object('key', 'not_prepared', 'severity', 'blocking', 'count', v_n,
        'title', 'Not prepared yet', 'people', v_people, 'link', '/payroll', 'action', 'Prepare');
    end if;
  end if;

  -- The payroll engine's own blocking / warning items on current records
  for r in
    select a->>'code' as code, a->>'severity' as severity, count(*) as n,
           coalesce(jsonb_agg(jsonb_build_object('name', e.full_name, 'detail', a->>'message') order by e.full_name)
                      filter (where true), '[]'::jsonb) as people
    from public.payroll_records pr
    join public.employees e on e.id = pr.employee_id
    cross join lateral jsonb_array_elements(coalesce(pr.attention, '[]'::jsonb)) a
    where pr.period_id = p.id and pr.superseded_by_record_id is null and pr.published_at is null
      and a->>'severity' in ('blocking', 'warning')
    group by 1, 2
  loop
    v_items := v_items || jsonb_build_object('key', 'attention_' || r.code, 'severity', r.severity, 'count', r.n,
      'title', case r.code
                 when 'no_pay' then 'No pay set'
                 when 'no_hours' then 'No hours entered'
                 when 'hours_pending' then 'Hours not confirmed'
                 when 'negative_net' then 'Net pay below zero'
                 when 'not_employed' then 'Not employed in this month'
                 when 'no_join_date' then 'No join date'
                 when 'ot_not_eligible' then 'Overtime entered but not eligible'
                 when 'overtime_pending' then 'Overtime not confirmed'
                 when 'deduction_cap' then 'Deductions above the legal cap'
                 else initcap(replace(r.code, '_', ' ')) end,
      'people', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements(r.people) x limit 8) y),
      'link', '/payroll', 'action', 'Open payroll');
  end loop;

  -- Leave still pending in the month (can change paid/unpaid days)
  select count(*), coalesce(jsonb_agg(x.name order by x.name) filter (where x.rn <= 8), '[]'::jsonb) into v_n, v_people
  from (select e.full_name as name, row_number() over (order by e.full_name) rn
        from public.leave_requests lr join public.employees e on e.id = lr.employee_id
        where e.entity_id = p.entity_id and lr.status = 'pending'
          and lr.start_date <= p.period_end and lr.end_date >= p.period_start) x;
  if v_n > 0 then
    v_items := v_items || jsonb_build_object('key', 'pending_leave', 'severity', 'blocking', 'count', v_n,
      'title', 'Leave requests not decided', 'people', v_people, 'link', '/leave', 'action', 'Decide leave');
  end if;

  -- Missing clock-outs (open records from an earlier day in the month)
  select count(*), coalesce(jsonb_agg(x.name order by x.name) filter (where x.rn <= 8), '[]'::jsonb) into v_n, v_people
  from (select e.full_name as name, row_number() over (order by e.full_name) rn
        from public.attendance_records a join public.employees e on e.id = a.employee_id
        where a.entity_id = p.entity_id and a.clock_out_at is null
          and (a.clock_in_at at time zone 'Asia/Dubai')::date between p.period_start and least(p.period_end, v_today - 1)) x;
  if v_n > 0 then
    v_items := v_items || jsonb_build_object('key', 'missing_clock_out', 'severity', 'blocking', 'count', v_n,
      'title', 'Missing clock-outs', 'people', v_people, 'link', '/attendance', 'action', 'Fix clock-outs');
  end if;

  -- Published past shifts with no attendance
  select count(*), coalesce(jsonb_agg(x.name order by x.name) filter (where x.rn <= 8), '[]'::jsonb) into v_n, v_people
  from (select e.full_name as name, row_number() over (order by e.full_name) rn
        from public.shifts sh join public.employees e on e.id = sh.employee_id
        where sh.entity_id = p.entity_id and sh.is_published and sh.status <> 'cancelled'
          and sh.shift_date between p.period_start and least(p.period_end, v_today - 1)
          and not exists (select 1 from public.attendance_records a where a.shift_id = sh.id)
          and not exists (select 1 from public.leave_requests lr where lr.employee_id = sh.employee_id
                            and lr.status = 'approved' and sh.shift_date between lr.start_date and lr.end_date)) x;
  if v_n > 0 then
    v_items := v_items || jsonb_build_object('key', 'shift_no_attendance', 'severity', 'warning', 'count', v_n,
      'title', 'Shifts with no clock-in', 'people', v_people, 'link', '/attendance', 'action', 'Review attendance');
  end if;

  -- Payable-time adjustments waiting for a decision
  select count(*), coalesce(jsonb_agg(x.name order by x.name) filter (where x.rn <= 8), '[]'::jsonb) into v_n, v_people
  from (select e.full_name as name, row_number() over (order by e.full_name) rn
        from public.attendance_adjustments aa
        join public.payable_shift_records ps on ps.id = aa.payable_shift_record_id
        join public.shifts sh on sh.id = ps.shift_id
        join public.employees e on e.id = ps.employee_id
        where ps.entity_id = p.entity_id and aa.status = 'pending'
          and sh.shift_date between p.period_start and p.period_end) x;
  if v_n > 0 then
    v_items := v_items || jsonb_build_object('key', 'pending_time_adjustments', 'severity', 'warning', 'count', v_n,
      'title', 'Payable-time changes not decided', 'people', v_people, 'link', '/attendance', 'action', 'Decide');
  end if;

  -- Payment details not verified (people being paid this month)
  select count(*), coalesce(jsonb_agg(x.name order by x.name) filter (where x.rn <= 8), '[]'::jsonb) into v_n, v_people
  from (select e.full_name as name, row_number() over (order by e.full_name) rn
        from public.employees e
        where e.entity_id = p.entity_id
          and (exists (select 1 from public.payroll_records pr where pr.period_id = p.id and pr.employee_id = e.id
                        and pr.superseded_by_record_id is null)
               or (p.kind = 'regular' and public._payroll_ineligible_reason(e.id, p.id) is null))
          and not exists (select 1 from public.employee_payment_details d where d.employee_id = e.id and d.status = 'verified')) x;
  if v_n > 0 then
    v_items := v_items || jsonb_build_object('key', 'payment_details', 'severity', 'blocking', 'count', v_n,
      'title', 'No verified bank or payment details', 'people', v_people, 'link', '/employees', 'action', 'Open people');
  end if;

  -- Draft (unpublished) shifts still in the month
  select count(*) into v_n from public.shifts sh
  where sh.entity_id = p.entity_id and not sh.is_published and sh.status <> 'cancelled'
    and sh.shift_date between p.period_start and p.period_end;
  if v_n > 0 then
    v_items := v_items || jsonb_build_object('key', 'draft_shifts', 'severity', 'warning', 'count', v_n,
      'title', 'Draft shifts not published', 'people', '[]'::jsonb, 'link', '/schedules', 'action', 'Open schedules');
  end if;

  select count(*), count(*) filter (where pr.record_status = 'approved') into v_total, v_approved
  from public.payroll_records pr where pr.period_id = p.id and pr.superseded_by_record_id is null;

  return jsonb_build_object(
    'period_id', p.id, 'entity_id', p.entity_id, 'kind', p.kind, 'label', p.label,
    'period_start', p.period_start, 'period_end', p.period_end,
    'pay_date', v_pay_date, 'days_to_pay_day', v_pay_date - v_today,
    'records', v_total, 'approved', v_approved,
    'blocking', (select count(*) from jsonb_array_elements(v_items) i where i->>'severity' = 'blocking'),
    'warnings', (select count(*) from jsonb_array_elements(v_items) i where i->>'severity' = 'warning'),
    'ready', not exists (select 1 from jsonb_array_elements(v_items) i where i->>'severity' = 'blocking'),
    'items', v_items);
end;
$function$;
revoke all on function public._payroll_readiness(uuid) from public, anon, authenticated;

create or replace function public.get_payroll_readiness(p_period_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_entity uuid;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select entity_id into v_entity from public.payroll_periods where id = p_period_id;
  if v_entity is null then
    raise exception using errcode = 'P0002', message = 'Payroll month not found';
  end if;
  if not (public.payroll_can(v_entity, 'prepare') or public.payroll_can(v_entity, 'approve')) then
    raise exception using errcode = '42501', message = 'You do not have payroll permission to see this';
  end if;
  return public._payroll_readiness(p_period_id);
end;
$function$;
revoke all on function public.get_payroll_readiness(uuid) from public, anon;
grant execute on function public.get_payroll_readiness(uuid) to authenticated, service_role;

-- Daily reminder to the payroll team (owner, company admins, payroll admins).
create or replace function public.run_payroll_readiness_reminders()
returns int
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  en record;
  v_month date;
  v_pay date;
  v_period uuid;
  rd jsonb;
  v_title text;
  v_msg text;
  v_recipient uuid;
  v_n int := 0;
begin
  for en in select id, name from public.entities where coalesce(is_active, true) loop
    -- The month whose pay day is next: pay day falls in the month after the payroll month.
    v_month := (date_trunc('month', v_today) - interval '1 month')::date;
    v_pay := (date_trunc('month', v_today))::date + (coalesce((public._payroll_settings(en.id, v_month)).pay_day, 1) - 1);
    if v_pay < v_today - 7 then
      v_month := date_trunc('month', v_today)::date;
      v_pay := (date_trunc('month', v_today) + interval '1 month')::date
               + (coalesce((public._payroll_settings(en.id, v_month)).pay_day, 1) - 1);
    end if;
    -- From 3 days before pay day until a week after it.
    continue when v_today < v_pay - 3 or v_today > v_pay + 7;
    -- Only companies that run payroll here.
    continue when not exists (select 1 from public.payroll_periods pp where pp.entity_id = en.id);

    v_period := null;
    select id into v_period from public.payroll_periods
    where entity_id = en.id and kind = 'regular' and period_start = v_month;

    if v_period is null then
      v_title := format('%s payroll not started', to_char(v_month, 'FMMonth'));
      v_msg := format('Pay day is %s. Open the %s payroll month and prepare it.', to_char(v_pay, 'Dy DD Mon'), to_char(v_month, 'FMMonth'));
    else
      rd := public._payroll_readiness(v_period);
      continue when (rd->>'records')::int > 0 and (rd->>'approved')::int = (rd->>'records')::int
                    and (rd->>'blocking')::int = 0;
      v_title := format('%s payroll: %s', to_char(v_month, 'FMMonth'),
                        case when (rd->>'blocking')::int = 0 then 'ready to approve'
                             else format('%s thing%s blocking', rd->>'blocking', case when (rd->>'blocking')::int = 1 then '' else 's' end) end);
      v_msg := format('Pay day is %s. %s of %s approved. Open the readiness checklist in Payroll.',
                      to_char(v_pay, 'Dy DD Mon'), rd->>'approved', rd->>'records');
    end if;

    for v_recipient in
      select p.id from public.profiles p
      where p.is_active and (p.role = 'owner' or (p.role = 'entity_admin' and p.entity_id = en.id))
      union
      select pm.user_id from public.payroll_permissions pm
      join public.profiles p on p.id = pm.user_id and p.is_active
      where pm.entity_id = en.id and pm.preset = 'payroll_admin'
    loop
      perform public.create_notification(en.id, v_recipient, null, 'payroll_readiness', v_title, v_msg,
        case when v_period is null then null else 'payroll_periods' end, v_period,
        case when v_today >= v_pay - 1 then 'high' else 'normal' end,
        'payroll_readiness:' || en.id || ':' || v_today || ':' || v_recipient);
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end;
$function$;
revoke all on function public.run_payroll_readiness_reminders() from public, anon, authenticated;

-- 04:00 UTC = 08:00 Dubai.
select cron.schedule('payroll-readiness-reminders', '0 4 * * *', 'select public.run_payroll_readiness_reminders();');
