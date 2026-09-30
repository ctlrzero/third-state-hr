-- Fixes from the payroll workflow audit (2026-09-30).
--  1. Scheduled publishing counts payments the way the rest of payroll does (_payroll_money, which includes
--     payments on the payslip a correction replaces), so a correction to a paid payslip is published.
--  2. Staff keep seeing their payslip while a correction is being prepared; the old one is hidden only once
--     the corrected one is published.
--  3. If the person who set the schedule can no longer approve payroll, nothing is published and the team
--     is told to save the schedule again (it used to fail silently every hour).
--  4. The pay date can be changed after the publish time has passed (the time is only checked when it changes).
--  5. The "not published" notice says why: not approved, not paid, or not prepared yet.
--  6. Payroll reminders use each month's stored pay date, include one-off runs, and keep going until payslips
--     are published (not just approved).
--  7. A payslip that was replaced by a correction can't be published.
--  8. The checklist warns when someone is paid more than once for the same salary month
--     (regular month, one-off runs with that salary month, or the old payroll screen).
--  9. Month list shows the salary month and sorts by it; the "already run on the previous screen" message
--     points to where it actually is.

-- 7. payroll_publish: never publish a replaced payslip
do $patch$
declare v_def text := pg_get_functiondef('public.payroll_publish(uuid[])'::regprocedure);
begin
  if position($a$when r.published_at is not null then 'Already published' end;$a$ in v_def) = 0 then
    raise exception 'payroll_publish patch point not found';
  end if;
  execute replace(v_def, $a$when r.published_at is not null then 'Already published' end;$a$,
    $a$when r.published_at is not null then 'Already published'
                     when r.superseded_by_record_id is not null then 'Replaced by a correction' end;$a$);
end
$patch$;

-- 2. staff: hide the old payslip only once its correction is published
do $patch$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.payroll_my_payslips()'::regprocedure);
  if position($a$and r.superseded_by_record_id is null)$a$ in v_def) = 0 then
    raise exception 'payroll_my_payslips patch point not found';
  end if;
  execute replace(v_def, $a$and r.superseded_by_record_id is null)$a$,
    $a$and (r.superseded_by_record_id is null
         or not exists (select 1 from public.payroll_records x where x.id = r.superseded_by_record_id and x.published_at is not null)))$a$);

  v_def := pg_get_functiondef('public.payroll_my_payslip(uuid)'::regprocedure);
  if position($a$  if r.superseded_by_record_id is not null then
    raise exception 'This payslip was replaced$a$ in v_def) = 0 then
    raise exception 'payroll_my_payslip patch point not found';
  end if;
  execute replace(v_def, $a$  if r.superseded_by_record_id is not null then
    raise exception 'This payslip was replaced$a$,
    $a$  if r.superseded_by_record_id is not null
     and exists (select 1 from public.payroll_records x where x.id = r.superseded_by_record_id and x.published_at is not null) then
    raise exception 'This payslip was replaced$a$);
end
$patch$;

-- 4. schedule: only check the publish time when it changes
do $patch$
declare v_def text := pg_get_functiondef('public.payroll_set_schedule(uuid, date, timestamptz, boolean)'::regprocedure);
begin
  if position($a$if p_publish_at is not null and p_publish_at <= now() then$a$ in v_def) = 0 then
    raise exception 'payroll_set_schedule patch point not found';
  end if;
  execute replace(v_def, $a$if p_publish_at is not null and p_publish_at <= now() then$a$,
    $a$if p_publish_at is not null and p_publish_at is distinct from p.publish_payslips_at and p_publish_at <= now() then$a$);
end
$patch$;

-- 9. clearer message for a month run on the old screen
do $patch$
declare v_def text := pg_get_functiondef('public.payroll_open_period(uuid, date)'::regprocedure);
begin
  if position($a$'% was already run in the previous payroll screen (status: %). Open it there, or use an off-cycle payroll for any extra payment.'$a$ in v_def) = 0 then
    raise exception 'payroll_open_period patch point not found';
  end if;
  execute replace(v_def,
    $a$'% was already run in the previous payroll screen (status: %). Open it there, or use an off-cycle payroll for any extra payment.'$a$,
    $a$'% was already run on the previous payroll screen (status: %). You can see it under "Earlier payroll runs" at the bottom of this page. For anyone not paid there, use "Off-cycle / final settlement" and choose this month as the salary month.'$a$);
end
$patch$;

-- 9. month list: salary month, title, pay date; sorted by salary month
create or replace function public.payroll_periods_list(p_entity_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if not (public.payroll_can(p_entity_id, 'view_pay') or public.payroll_can(p_entity_id, 'inputs')) then
    raise exception 'No permission' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'period_start', p.period_start, 'period_end', p.period_end,
      'label', p.label, 'for_month', p.for_month, 'title', public._payroll_period_title(p),
      'pay_date', public._payroll_pay_date(p.id),
      'employees', (select count(*) from public.payroll_records r where r.period_id = p.id and r.superseded_by_record_id is null),
      'approved', (select count(*) from public.payroll_records r where r.period_id = p.id and r.superseded_by_record_id is null and r.record_status = 'approved'),
      'net', case when public.payroll_can(p_entity_id, 'view_pay') then
               (select coalesce(sum(net), 0) from public.payroll_records r where r.period_id = p.id and r.superseded_by_record_id is null) end)
      order by coalesce(p.for_month, p.period_start) desc, p.kind, p.created_at desc)
    from public.payroll_periods p where p.entity_id = p_entity_id), '[]'::jsonb);
end;
$function$;

-- 8. checklist: paid more than once for the same salary month
do $patch$
declare v_def text := pg_get_functiondef('public._payroll_readiness(uuid)'::regprocedure);
  v_anchor text := $a$  select count(*), count(*) filter (where pr.record_status = 'approved') into v_total, v_approved$a$;
begin
  if position(v_anchor in v_def) = 0 then
    raise exception '_payroll_readiness patch point not found';
  end if;
  execute replace(v_def, v_anchor, $a$  -- Paid more than once for the same salary month?
  select count(*), coalesce(jsonb_agg(x.name order by x.name) filter (where x.rn <= 8), '[]'::jsonb) into v_n, v_people
  from (select e.full_name as name, row_number() over (order by e.full_name) rn
        from public.payroll_records pr
        join public.employees e on e.id = pr.employee_id
        where pr.period_id = p.id and pr.superseded_by_record_id is null
          and coalesce(p.for_month, case when p.kind = 'regular' then p.period_start end) is not null
          and (exists (select 1 from public.payroll_records o join public.payroll_periods op on op.id = o.period_id
                       where o.employee_id = pr.employee_id and o.superseded_by_record_id is null and op.id <> p.id
                         and coalesce(op.for_month, case when op.kind = 'regular' then op.period_start end)
                             = coalesce(p.for_month, case when p.kind = 'regular' then p.period_start end))
               or exists (select 1 from public.payslips ls join public.payroll_runs lr on lr.id = ls.payroll_run_id
                          where ls.employee_id = pr.employee_id and lr.status in ('approved', 'paid')
                            and lr.period_start <= (coalesce(p.for_month, p.period_start) + interval '1 month - 1 day')::date
                            and lr.period_end >= coalesce(p.for_month, date_trunc('month', p.period_start)::date)))) x;
  if v_n > 0 then
    v_items := v_items || jsonb_build_object('key', 'salary_month_twice', 'severity', 'warning', 'count', v_n,
      'title', 'Also paid for this month elsewhere — check it isn''t paid twice', 'people', v_people,
      'link', '/payroll', 'action', 'Check');
  end if;

$a$ || v_anchor);
end
$patch$;

-- 1, 3, 5. scheduled publishing
create or replace function public.run_scheduled_payslip_publishing()
returns int
language plpgsql
security definer
set search_path to ''
as $function$
declare
  p public.payroll_periods;
  v_ids uuid[];
  v_not_approved int;
  v_unpaid int;
  v_not_prepared int;
  v_no_permission boolean;
  v_res jsonb;
  v_n int := 0;
  v_recipient uuid;
  v_title text;
  v_reasons text;
begin
  if auth.uid() is not null then
    raise exception using errcode = '42501', message = 'System job only';
  end if;
  for p in
    select pp.* from public.payroll_periods pp
    where pp.publish_payslips_at is not null and pp.publish_payslips_at <= now()
      and (pp.publish_attempted_at is null or pp.publish_attempted_at < now() - interval '1 hour')
      and exists (select 1 from public.payroll_records r where r.period_id = pp.id
                    and r.superseded_by_record_id is null and r.published_at is null)
    for update skip locked
  loop
    v_title := public._payroll_period_title(p);

    -- Does the person who scheduled it still have payroll approval?
    perform set_config('request.jwt.claims', json_build_object('sub', p.schedule_set_by, 'role', 'authenticated')::text, true);
    v_no_permission := p.schedule_set_by is null or not coalesce(public.payroll_can(p.entity_id, 'approve'), false);
    perform set_config('request.jwt.claims', '', true);

    select array_agg(r.id) filter (where r.record_status = 'approved'
                                     and (not p.publish_requires_paid or m.payment_status in ('paid', 'overpaid'))),
           count(*) filter (where r.record_status <> 'approved'),
           count(*) filter (where r.record_status = 'approved' and p.publish_requires_paid
                              and m.payment_status not in ('paid', 'overpaid'))
      into v_ids, v_not_approved, v_unpaid
    from public.payroll_records r
    cross join lateral public._payroll_money(r.id) m
    where r.period_id = p.id and r.superseded_by_record_id is null and r.published_at is null;

    v_not_prepared := 0;
    if p.kind = 'regular' then
      select count(*) into v_not_prepared from public.employees e
      where e.entity_id = p.entity_id and public._payroll_ineligible_reason(e.id, p.id) is null
        and not exists (select 1 from public.payroll_records r where r.period_id = p.id and r.employee_id = e.id);
    end if;

    if v_ids is not null and not v_no_permission then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', p.schedule_set_by, 'role', 'authenticated')::text, true);
        v_res := public.payroll_publish(v_ids);
        perform set_config('request.jwt.claims', '', true);
        v_n := v_n + coalesce((v_res->>'processed')::int, 0);
        v_unpaid := v_unpaid + coalesce(jsonb_array_length(v_res->'skipped'), 0);
      exception when others then
        perform set_config('request.jwt.claims', '', true);
        v_unpaid := v_unpaid + cardinality(v_ids);
        raise warning 'scheduled publish for % failed: %', p.id, sqlerrm;
      end;
    end if;

    v_reasons := concat_ws(', ',
      case when v_no_permission then 'the person who scheduled it can no longer approve payroll — open the month and save the dates again' end,
      case when v_not_approved > 0 then format('%s not approved', v_not_approved) end,
      case when v_unpaid > 0 then format('%s not paid', v_unpaid) end,
      case when v_not_prepared > 0 then format('%s not prepared yet', v_not_prepared) end);

    if v_reasons <> '' then
      for v_recipient in
        select pr.id from public.profiles pr
        where pr.is_active and (pr.role = 'owner' or (pr.role = 'entity_admin' and pr.entity_id = p.entity_id))
        union
        select pm.user_id from public.payroll_permissions pm join public.profiles pr on pr.id = pm.user_id and pr.is_active
        where pm.entity_id = p.entity_id and pm.preset = 'payroll_admin'
      loop
        perform public.create_notification(p.entity_id, v_recipient, null, 'payroll_schedule_blocked',
          format('%s: some payslips not published', v_title),
          format('Scheduled for %s. Waiting: %s. They are published at the next check once ready.',
                 to_char(p.publish_payslips_at at time zone 'Asia/Dubai', 'Dy DD Mon HH24:MI'), v_reasons),
          'payroll_periods', p.id, 'high',
          'payroll_schedule_blocked:' || p.id || ':' || (now() at time zone 'Asia/Dubai')::date || ':' || v_recipient);
      end loop;
    end if;

    update public.payroll_periods set publish_attempted_at = now() where id = p.id;
  end loop;
  return v_n;
end;
$function$;
revoke all on function public.run_scheduled_payslip_publishing() from public, anon, authenticated;

-- 6. reminders: each month's own pay date, one-off runs too, until payslips are published
create or replace function public.run_payroll_readiness_reminders()
returns int
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  en record;
  pr record;
  v_month date;
  v_pay date;
  v_legacy_status text;
  rd jsonb;
  v_title text;
  v_msg text;
  v_recipient uuid;
  v_n int := 0;
begin
  for en in select id, name from public.entities where coalesce(is_active, true)
              and exists (select 1 from public.payroll_periods pp where pp.entity_id = entities.id) loop

    -- (a) Last month's regular payroll not started anywhere
    v_month := (date_trunc('month', v_today) - interval '1 month')::date;
    v_pay := (date_trunc('month', v_today))::date + (coalesce((public._payroll_settings(en.id, v_month)).pay_day, 1) - 1);
    if v_today between v_pay - 3 and v_pay + 7
       and not exists (select 1 from public.payroll_periods pp where pp.entity_id = en.id
                         and ((pp.kind = 'regular' and pp.period_start = v_month) or pp.for_month = v_month)) then
      v_legacy_status := null;
      select lr.status into v_legacy_status from public.payroll_runs lr
      where lr.entity_id = en.id and lr.period_start <= (v_month + interval '1 month - 1 day')::date and lr.period_end >= v_month
      order by case lr.status when 'paid' then 0 when 'approved' then 1 when 'in_review' then 2 else 3 end limit 1;
      if coalesce(v_legacy_status, '') not in ('approved', 'paid') then
        v_title := case when v_legacy_status is null then format('%s payroll not started', to_char(v_month, 'FMMonth'))
                        else format('%s payroll not approved yet', to_char(v_month, 'FMMonth')) end;
        v_msg := case when v_legacy_status is null
                      then format('Pay day is %s. Open the %s payroll month and prepare it.', to_char(v_pay, 'Dy DD Mon'), to_char(v_month, 'FMMonth'))
                      else format('Pay day is %s. %s is still %s on the old payroll screen.', to_char(v_pay, 'Dy DD Mon'), to_char(v_month, 'FMMonth'), replace(v_legacy_status, '_', ' ')) end;
        for v_recipient in
          select p.id from public.profiles p where p.is_active and (p.role = 'owner' or (p.role = 'entity_admin' and p.entity_id = en.id))
          union select pm.user_id from public.payroll_permissions pm join public.profiles p on p.id = pm.user_id and p.is_active
                where pm.entity_id = en.id and pm.preset = 'payroll_admin'
        loop
          perform public.create_notification(en.id, v_recipient, null, 'payroll_readiness', v_title, v_msg, null, null,
            case when v_today >= v_pay - 1 then 'high' else 'normal' end,
            'payroll_readiness:' || en.id || ':' || v_today || ':' || v_recipient);
          v_n := v_n + 1;
        end loop;
      end if;
    end if;

    -- (b) Every open payroll month / one-off run near its own pay date and not finished
    for pr in
      select pp.id, public._payroll_pay_date(pp.id) as pay_date, public._payroll_period_title(pp) as title
      from public.payroll_periods pp
      where pp.entity_id = en.id
        and public._payroll_pay_date(pp.id) between v_today - 7 and v_today + 3
    loop
      rd := public._payroll_readiness(pr.id);
      continue when coalesce((rd->>'done')::boolean, false);
      v_title := format('%s payroll: %s', pr.title,
                        case when (rd->>'blocking')::int > 0
                             then format('%s thing%s blocking', rd->>'blocking', case when (rd->>'blocking')::int = 1 then '' else 's' end)
                             when (rd->>'approved')::int < (rd->>'records')::int then 'ready to approve'
                             else 'pay and publish payslips' end);
      v_msg := format('Pay day is %s. %s of %s approved. Open Payroll to finish it.',
                      to_char(pr.pay_date, 'Dy DD Mon'), rd->>'approved', rd->>'records');
      for v_recipient in
        select p.id from public.profiles p where p.is_active and (p.role = 'owner' or (p.role = 'entity_admin' and p.entity_id = en.id))
        union select pm.user_id from public.payroll_permissions pm join public.profiles p on p.id = pm.user_id and p.is_active
              where pm.entity_id = en.id and pm.preset = 'payroll_admin'
      loop
        perform public.create_notification(en.id, v_recipient, null, 'payroll_readiness', v_title, v_msg,
          'payroll_periods', pr.id, case when v_today >= pr.pay_date - 1 then 'high' else 'normal' end,
          'payroll_readiness:' || pr.id || ':' || v_today || ':' || v_recipient);
        v_n := v_n + 1;
      end loop;
    end loop;
  end loop;
  return v_n;
end;
$function$;
revoke all on function public.run_payroll_readiness_reminders() from public, anon, authenticated;
