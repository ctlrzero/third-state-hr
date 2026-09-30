-- Owner-approved 2026-09-30 (proposal accepted):
--  1. The previous payroll screen is retired: no NEW payroll runs can be created in payroll_runs (corrections of an
--     existing run are still allowed). History stays readable; nothing is changed or deleted.
--  2. One-off (off-cycle) runs with a salary month cover that whole month; pay_date is only the payment date.
--     payroll_open_off_cycle does this for new runs, and the two existing September runs are normalised
--     (period 1–30 Sep, audited). Amounts, approvals and payments are untouched.
--  3. The checklist for a one-off run only looks at the people in that run (not the whole company).
--  4. The late-payment warning applies to any run with a salary month.

-- 1. Retire the old screen for new runs
create or replace function public.block_new_legacy_runs()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if public._maintenance_bypass() then
    return new;
  end if;
  -- A revision (correction) of an existing run is still allowed.
  if new.revises_payroll_run_id is not null then
    return new;
  end if;
  raise exception 'Payroll is run on the new Payroll screen now. Open the month there and press Prepare payroll.' using errcode = '22023';
end;
$function$;
drop trigger if exists trg_block_new_legacy_runs on public.payroll_runs;
create trigger trg_block_new_legacy_runs before insert on public.payroll_runs
  for each row execute function public.block_new_legacy_runs();

-- 2. One-off runs with a salary month span that month
create or replace function public.payroll_open_off_cycle(p_entity_id uuid, p_pay_date date, p_label text, p_for_month date default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
  v_month date := case when p_for_month is not null then date_trunc('month', p_for_month)::date end;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  perform public._payroll_require(p_entity_id, 'prepare');
  if nullif(btrim(p_label), '') is null then
    raise exception 'Give the off-cycle payroll a label (e.g. "Final settlement – Ali")' using errcode = '22023';
  end if;
  insert into public.payroll_periods (entity_id, kind, period_start, period_end, label, created_by, pay_date, for_month)
  values (p_entity_id, 'off_cycle',
          coalesce(v_month, p_pay_date),
          case when v_month is not null then (v_month + interval '1 month - 1 day')::date else p_pay_date end,
          btrim(p_label), auth.uid(), p_pay_date, v_month)
  returning id into v_id;
  perform public._payroll_audit(p_entity_id, 'payroll_periods', v_id, 'payroll_off_cycle_opened', null,
    jsonb_build_object('pay_date', p_pay_date, 'label', p_label, 'for_month', v_month), null);
  return v_id;
end;
$function$;
revoke all on function public.payroll_open_off_cycle(uuid, date, text, date) from public, anon;
grant execute on function public.payroll_open_off_cycle(uuid, date, text, date) to authenticated;

-- Existing one-off runs that have a salary month: same period, audited, idempotent.
do $fix$
declare r record;
begin
  for r in
    select id, entity_id, period_start, period_end, for_month from public.payroll_periods
    where kind = 'off_cycle' and for_month is not null
      and (period_start <> for_month or period_end <> (for_month + interval '1 month - 1 day')::date)
  loop
    update public.payroll_periods
    set period_start = r.for_month, period_end = (r.for_month + interval '1 month - 1 day')::date
    where id = r.id;
    perform public._payroll_audit(r.entity_id, 'payroll_periods', r.id, 'payroll_period_dates_normalised',
      jsonb_build_object('period_start', r.period_start, 'period_end', r.period_end),
      jsonb_build_object('period_start', r.for_month, 'period_end', (r.for_month + interval '1 month - 1 day')::date), null);
  end loop;
end
$fix$;

-- 3. Checklist: one-off runs only check the people in the run
do $patch$
declare
  v_def text := pg_get_functiondef('public._payroll_readiness(uuid)'::regprocedure);
  v_new text := v_def;
  v_parts text[][] := array[
    array[$a$          and lr.start_date <= p.period_end and lr.end_date >= p.period_start) x;$a$,
          $a$          and lr.start_date <= p.period_end and lr.end_date >= p.period_start
          and (p.kind = 'regular' or exists (select 1 from public.payroll_records ox where ox.period_id = p.id
                and ox.employee_id = lr.employee_id and ox.superseded_by_record_id is null))) x;$a$],
    array[$a$          and (a.clock_in_at at time zone 'Asia/Dubai')::date between p.period_start and least(p.period_end, v_today - 1)) x;$a$,
          $a$          and (a.clock_in_at at time zone 'Asia/Dubai')::date between p.period_start and least(p.period_end, v_today - 1)
          and (p.kind = 'regular' or exists (select 1 from public.payroll_records ox where ox.period_id = p.id
                and ox.employee_id = a.employee_id and ox.superseded_by_record_id is null))) x;$a$],
    array[$a$          and sh.shift_date between p.period_start and least(p.period_end, v_today - 1)
$a$,
          $a$          and sh.shift_date between p.period_start and least(p.period_end, v_today - 1)
          and (p.kind = 'regular' or exists (select 1 from public.payroll_records ox where ox.period_id = p.id
                and ox.employee_id = sh.employee_id and ox.superseded_by_record_id is null))
$a$],
    array[$a$          and sh.shift_date between p.period_start and p.period_end) x;$a$,
          $a$          and sh.shift_date between p.period_start and p.period_end
          and (p.kind = 'regular' or exists (select 1 from public.payroll_records ox where ox.period_id = p.id
                and ox.employee_id = ps.employee_id and ox.superseded_by_record_id is null))) x;$a$],
    array[$a$    and sh.shift_date between p.period_start and p.period_end;$a$,
          $a$    and sh.shift_date between p.period_start and p.period_end
    and (p.kind = 'regular' or exists (select 1 from public.payroll_records ox where ox.period_id = p.id
          and ox.employee_id = sh.employee_id and ox.superseded_by_record_id is null));$a$]
  ];
  i int;
begin
  for i in 1 .. array_length(v_parts, 1) loop
    if position(v_parts[i][1] in v_new) = 0 then
      raise exception '_payroll_readiness patch point % not found', i;
    end if;
    v_new := replace(v_new, v_parts[i][1], v_parts[i][2]);
  end loop;
  execute v_new;
end
$patch$;

-- 4. Late-payment warning for any run with a salary month
do $patch$
declare v_def text := pg_get_functiondef('public.payroll_set_schedule(uuid, date, timestamptz, boolean)'::regprocedure);
begin
  if position($a$if p_pay_date is not null and p.kind = 'regular'$a$ in v_def) = 0 then
    raise exception 'payroll_set_schedule patch point not found';
  end if;
  execute replace(v_def, $a$if p_pay_date is not null and p.kind = 'regular'$a$,
                         $a$if p_pay_date is not null and (p.kind = 'regular' or p.for_month is not null)$a$);
end
$patch$;
