-- Payroll: pay date, scheduled payslips and the salary month (owner's flow:
-- month > employees > salary preparation > pay date (may be in the future) > payslip schedule).
--   * payroll_periods.pay_date — the day salaries are paid (null = settings pay day). Used by the checklist,
--     reminders and payslips. Recording a payment still can't be dated in the future (unchanged).
--   * payroll_periods.publish_payslips_at + publish_requires_paid (default true) — payslips are published
--     automatically at that time for people who are approved (and paid). Anyone not ready is NOT published and
--     the payroll team is told. A cron job checks every 15 minutes; "Publish now" still works.
--   * payroll_periods.for_month — the salary month of a one-off (off-cycle) run, so payslips say
--     "September 2026" instead of the run's title. Regular months use their own month.
--   * payroll_set_schedule(period, pay_date, publish_at, require_paid) — set/clear from the Payroll screen.
-- Approval, audit and corrections are unchanged: automatic publishing calls payroll_publish as the person who
-- set the schedule, so their permission is re-checked at the moment of publishing.

alter table public.payroll_periods
  add column if not exists pay_date date,
  add column if not exists publish_payslips_at timestamptz,
  add column if not exists publish_requires_paid boolean not null default true,
  add column if not exists for_month date,
  add column if not exists schedule_set_by uuid,
  add column if not exists schedule_set_at timestamptz,
  add column if not exists publish_attempted_at timestamptz;
alter table public.payroll_periods drop constraint if exists payroll_periods_for_month_check;
alter table public.payroll_periods add constraint payroll_periods_for_month_check
  check (for_month is null or for_month = date_trunc('month', for_month)::date);

-- The month a payslip belongs to, in words ("September 2026").
create or replace function public._payroll_period_title(p public.payroll_periods)
returns text
language sql
stable
set search_path to ''
as $function$
  select coalesce(to_char(coalesce(p.for_month, case when p.kind = 'regular' then p.period_start end), 'FMMonth YYYY'), p.label);
$function$;

-- Stored pay date first; otherwise the settings rule as before.
create or replace function public._payroll_pay_date(p_period_id uuid)
returns date
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(p.pay_date,
                  case when p.kind = 'regular'
                       then (date_trunc('month', p.period_end) + interval '1 month')::date
                            + (coalesce((public._payroll_settings(p.entity_id, p.period_start)).pay_day, 1) - 1)
                       else p.period_end end)
  from public.payroll_periods p where p.id = p_period_id;
$function$;
revoke all on function public._payroll_pay_date(uuid) from public, anon, authenticated;

create or replace function public.payroll_set_schedule(
  p_period_id uuid, p_pay_date date, p_publish_at timestamptz, p_require_paid boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  p public.payroll_periods;
  v_old jsonb;
  v_warn text;
  v_month date;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select * into p from public.payroll_periods where id = p_period_id for update;
  if p.id is null then
    raise exception using errcode = 'P0002', message = 'Payroll month not found';
  end if;
  perform public._payroll_require(p.entity_id, 'approve');
  v_month := coalesce(p.for_month, date_trunc('month', p.period_start)::date);
  if p_pay_date is not null and p_pay_date < v_month then
    raise exception using errcode = '22023', message = 'The pay date can’t be before the salary month starts';
  end if;
  if p_publish_at is not null and p_publish_at <= now() then
    raise exception using errcode = '22023', message = 'Choose a time in the future for the payslips (or use Publish now)';
  end if;
  if p_pay_date is not null and p.kind = 'regular'
     and p_pay_date > (date_trunc('month', p.period_end) + interval '1 month + 14 days')::date then
    v_warn := 'This is more than 15 days after the salary was due (1st of next month). UAE WPS may flag late payment.';
  end if;

  v_old := jsonb_build_object('pay_date', p.pay_date, 'publish_payslips_at', p.publish_payslips_at,
                              'publish_requires_paid', p.publish_requires_paid);
  update public.payroll_periods
  set pay_date = p_pay_date,
      publish_payslips_at = p_publish_at,
      publish_requires_paid = coalesce(p_require_paid, true),
      schedule_set_by = auth.uid(),
      schedule_set_at = now(),
      publish_attempted_at = null
  where id = p.id;

  perform public._payroll_audit(p.entity_id, 'payroll_periods', p.id, 'payroll_schedule_set', v_old,
    jsonb_build_object('pay_date', p_pay_date, 'publish_payslips_at', p_publish_at,
                       'publish_requires_paid', coalesce(p_require_paid, true)), null);

  return jsonb_build_object('ok', true, 'pay_date', public._payroll_pay_date(p.id),
                            'publish_payslips_at', p_publish_at, 'warning', v_warn);
end;
$function$;
revoke all on function public.payroll_set_schedule(uuid, date, timestamptz, boolean) from public, anon;
grant execute on function public.payroll_set_schedule(uuid, date, timestamptz, boolean) to authenticated;

-- Off-cycle runs carry their salary month.
drop function if exists public.payroll_open_off_cycle(uuid, date, text);
create or replace function public.payroll_open_off_cycle(p_entity_id uuid, p_pay_date date, p_label text, p_for_month date default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id uuid;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  perform public._payroll_require(p_entity_id, 'prepare');
  if nullif(btrim(p_label), '') is null then
    raise exception 'Give the off-cycle payroll a label (e.g. "Final settlement – Ali")' using errcode = '22023';
  end if;
  insert into public.payroll_periods (entity_id, kind, period_start, period_end, label, created_by, pay_date, for_month)
  values (p_entity_id, 'off_cycle', p_pay_date, p_pay_date, btrim(p_label), auth.uid(), p_pay_date,
          case when p_for_month is not null then date_trunc('month', p_for_month)::date end)
  returning id into v_id;
  perform public._payroll_audit(p_entity_id, 'payroll_periods', v_id, 'payroll_off_cycle_opened', null,
    jsonb_build_object('pay_date', p_pay_date, 'label', p_label, 'for_month', p_for_month), null);
  return v_id;
end;
$function$;
revoke all on function public.payroll_open_off_cycle(uuid, date, text, date) from public, anon;
grant execute on function public.payroll_open_off_cycle(uuid, date, text, date) to authenticated;

-- Payslip notification uses the month, not the run title.
do $patch$
declare v_def text := pg_get_functiondef('public.payroll_publish(uuid[])'::regprocedure);
begin
  if position($a$coalesce(r.label, to_char(r.period_start, 'FMMonth YYYY'))$a$ in v_def) = 0 then
    raise exception 'payroll_publish patch point not found';
  end if;
  v_def := replace(v_def, $a$coalesce(r.label, to_char(r.period_start, 'FMMonth YYYY'))$a$,
    $a$(select public._payroll_period_title(pp2) from public.payroll_periods pp2 where pp2.id = r.period_id)$a$);
  execute v_def;
end
$patch$;

-- Staff payslips: title (month) and pay date.
do $patch$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.payroll_my_payslips()'::regprocedure);
  if position($a$'label', p.label, 'kind', p.kind,$a$ in v_def) = 0 then
    raise exception 'payroll_my_payslips patch point not found';
  end if;
  execute replace(v_def, $a$'label', p.label, 'kind', p.kind,$a$,
    $a$'label', p.label, 'kind', p.kind, 'title', public._payroll_period_title(p), 'pay_date', public._payroll_pay_date(p.id),$a$);

  v_def := pg_get_functiondef('public.payroll_my_payslip(uuid)'::regprocedure);
  if position($a$select jsonb_build_object('start', p.period_start, 'end', p.period_end, 'label', p.label, 'kind', p.kind)$a$ in v_def) = 0 then
    raise exception 'payroll_my_payslip patch point not found';
  end if;
  execute replace(v_def, $a$select jsonb_build_object('start', p.period_start, 'end', p.period_end, 'label', p.label, 'kind', p.kind)$a$,
    $a$select jsonb_build_object('start', coalesce(p.for_month, p.period_start),
                               'end', case when p.for_month is not null then (p.for_month + interval '1 month - 1 day')::date else p.period_end end,
                               'label', p.label, 'kind', p.kind,
                               'title', public._payroll_period_title(p), 'pay_date', public._payroll_pay_date(p.id))$a$);
end
$patch$;

-- Scheduled publishing (system job).
create or replace function public.run_scheduled_payslip_publishing()
returns int
language plpgsql
security definer
set search_path to ''
as $function$
declare
  p public.payroll_periods;
  v_ids uuid[];
  v_waiting int;
  v_res jsonb;
  v_n int := 0;
  v_recipient uuid;
  v_title text;
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
    select array_agg(r.id) into v_ids
    from public.payroll_records r
    left join lateral (select coalesce(sum(pm.amount), 0) as paid from public.payroll_payments pm
                       where pm.record_id = r.id and pm.status = 'recorded') m on true
    where r.period_id = p.id and r.superseded_by_record_id is null and r.published_at is null
      and r.record_status = 'approved'
      and (not p.publish_requires_paid or m.paid >= r.net);

    select count(*) into v_waiting from public.payroll_records r
    where r.period_id = p.id and r.superseded_by_record_id is null and r.published_at is null
      and not (r.id = any (coalesce(v_ids, array[]::uuid[])));

    if v_ids is not null then
      begin
        -- Publish as the person who set the schedule, so their permission is checked now.
        perform set_config('request.jwt.claims', json_build_object('sub', p.schedule_set_by, 'role', 'authenticated')::text, true);
        v_res := public.payroll_publish(v_ids);
        perform set_config('request.jwt.claims', '', true);
        v_n := v_n + coalesce((v_res->>'processed')::int, 0);
      exception when others then
        perform set_config('request.jwt.claims', '', true);
        v_waiting := v_waiting + cardinality(v_ids);
        raise warning 'scheduled publish for % failed: %', p.id, sqlerrm;
      end;
    end if;

    if v_waiting > 0 then
      for v_recipient in
        select pr.id from public.profiles pr
        where pr.is_active and (pr.role = 'owner' or (pr.role = 'entity_admin' and pr.entity_id = p.entity_id))
        union
        select pm.user_id from public.payroll_permissions pm join public.profiles pr on pr.id = pm.user_id and pr.is_active
        where pm.entity_id = p.entity_id and pm.preset = 'payroll_admin'
      loop
        perform public.create_notification(p.entity_id, v_recipient, null, 'payroll_schedule_blocked',
          format('%s: %s payslip%s not published', v_title, v_waiting, case when v_waiting = 1 then '' else 's' end),
          format('The payslips were scheduled for %s, but %s %s not approved%s yet. Finish them in Payroll; they are published at the next check.',
                 to_char(p.publish_payslips_at at time zone 'Asia/Dubai', 'Dy DD Mon HH24:MI'), v_waiting,
                 case when v_waiting = 1 then 'is' else 'are' end,
                 case when p.publish_requires_paid then ' and paid' else '' end),
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

select cron.schedule('scheduled-payslip-publishing', '*/15 * * * *', 'select public.run_scheduled_payslip_publishing();');
