-- Owner-approved 2026-09-30.
--  1. Prepare skips anyone already approved/published for the same salary month in a one-off run, or already
--     paid on the previous payroll screen, and says why. Picking them on purpose (explicit selection) still works.
--  2. "What changed since last month" compares with the previous SALARY month across every source: the regular
--     month, one-off runs marked with that salary month, and the previous payroll screen — summed per person.

-- 1. payroll_prepare: don't pick up people already paid for this month elsewhere
do $patch$
declare
  v_def text := pg_get_functiondef('public.payroll_prepare(uuid, uuid[])'::regprocedure);
  v_old text := $a$      if v_reason is not null then
        if p_employee_ids is not null or v_reason not in$a$;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'payroll_prepare patch point not found';
  end if;
  execute replace(v_def, v_old, $a$      if v_reason is null and p.kind = 'regular' and p_employee_ids is null then
        select format('Already paid for this month in “%s”', coalesce(op.label, 'a one-off run')) into v_reason
        from public.payroll_records o join public.payroll_periods op on op.id = o.period_id
        where o.employee_id = e.id and o.superseded_by_record_id is null and o.record_status = 'approved'
          and op.id <> p.id and op.for_month = p.period_start
        limit 1;
        if v_reason is null then
          select 'Already paid for this month on the previous payroll screen' into v_reason
          from public.payslips ls join public.payroll_runs lr on lr.id = ls.payroll_run_id
          where ls.employee_id = e.id and lr.status in ('approved', 'paid')
            and lr.period_start <= p.period_end and lr.period_end >= p.period_start
          limit 1;
        end if;
      end if;
$a$ || v_old);
end
$patch$;

-- 2. get_payroll_changes: previous salary month from all sources
create or replace function public.get_payroll_changes(p_period_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  p public.payroll_periods;
  v_cur_month date;
  v_prev_month date;
  v_rows jsonb;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select * into p from public.payroll_periods where id = p_period_id;
  if p.id is null then
    raise exception using errcode = 'P0002', message = 'Payroll month not found';
  end if;
  perform public._payroll_require(p.entity_id, 'view_pay');

  v_cur_month := coalesce(p.for_month, date_trunc('month', p.period_start)::date);

  -- The latest earlier salary month that has any payroll, wherever it was run.
  select max(m) into v_prev_month from (
    select pp.period_start as m from public.payroll_periods pp
      where pp.entity_id = p.entity_id and pp.kind = 'regular' and pp.period_start < v_cur_month
        and exists (select 1 from public.payroll_records r where r.period_id = pp.id and r.superseded_by_record_id is null)
    union all
    select pp.for_month from public.payroll_periods pp
      where pp.entity_id = p.entity_id and pp.kind = 'off_cycle' and pp.for_month < v_cur_month
        and exists (select 1 from public.payroll_records r where r.period_id = pp.id and r.superseded_by_record_id is null)
    union all
    select date_trunc('month', lr.period_start)::date from public.payroll_runs lr
      where lr.entity_id = p.entity_id and lr.status in ('approved', 'paid') and date_trunc('month', lr.period_start)::date < v_cur_month
  ) s;

  with cur as (
    select r.id, r.employee_id, r.gross, r.deductions, r.net, r.record_status
    from public.payroll_records r
    where r.period_id = p.id and r.superseded_by_record_id is null
  ),
  prev_recs as (
    select r.id, r.employee_id, r.gross, r.net
    from public.payroll_records r join public.payroll_periods pp on pp.id = r.period_id
    where pp.entity_id = p.entity_id and r.superseded_by_record_id is null and pp.id <> p.id
      and ((pp.kind = 'regular' and pp.period_start = v_prev_month) or (pp.kind = 'off_cycle' and pp.for_month = v_prev_month))
  ),
  prev_legacy as (
    select ls.employee_id, ls.net_pay as net, (ls.net_pay + ls.total_deductions) as gross
    from public.payslips ls join public.payroll_runs lr on lr.id = ls.payroll_run_id
    where lr.entity_id = p.entity_id and lr.status in ('approved', 'paid')
      and date_trunc('month', lr.period_start)::date = v_prev_month
  ),
  prev_tot as (
    select employee_id, sum(net) as net, sum(gross) as gross from (
      select employee_id, net, gross from prev_recs
      union all select employee_id, net, gross from prev_legacy) u
    group by employee_id
  ),
  cl as (
    select c.employee_id, l.kind, l.code, max(l.label) as label, sum(l.amount) as amount,
           string_agg(l.explanation, ' ') as explanation
    from cur c join public.payroll_lines l on l.record_id = c.id
    group by c.employee_id, l.kind, l.code
  ),
  pl as (
    select pv.employee_id, l.kind, l.code, max(l.label) as label, sum(l.amount) as amount
    from prev_recs pv join public.payroll_lines l on l.record_id = pv.id
    group by pv.employee_id, l.kind, l.code
  ),
  lines as (
    select coalesce(cl.employee_id, pl.employee_id) as employee_id, coalesce(cl.kind, pl.kind) as kind,
           coalesce(cl.code, pl.code) as code, coalesce(cl.label, pl.label) as label,
           coalesce(cl.amount, 0) as now_amount, coalesce(pl.amount, 0) as prev_amount,
           cl.explanation as now_explanation
    from cl full join pl on pl.employee_id = cl.employee_id and pl.kind = cl.kind and pl.code = cl.code
  )
  select coalesce(jsonb_agg(x order by abs(x.net_change) desc, x.name), '[]'::jsonb) into v_rows
  from (
    select c.employee_id, e.full_name as name, c.record_status,
           c.net as net_now, pv.net as net_prev, c.net - coalesce(pv.net, 0) as net_change,
           c.gross as gross_now, pv.gross as gross_prev, pv.employee_id is null as new_this_month,
           coalesce((select jsonb_agg(jsonb_build_object(
                      'kind', l.kind, 'code', l.code, 'label', l.label, 'now', l.now_amount, 'prev', l.prev_amount,
                      'change', l.now_amount - l.prev_amount, 'explanation', l.now_explanation)
                      order by abs(l.now_amount - l.prev_amount) desc)
                     from lines l where l.employee_id = c.employee_id and l.now_amount <> l.prev_amount), '[]'::jsonb) as changes
    from cur c
    join public.employees e on e.id = c.employee_id
    left join prev_tot pv on pv.employee_id = c.employee_id
  ) x;

  return jsonb_build_object(
    'period_id', p.id, 'label', public._payroll_period_title(p),
    'previous_period_id', null,
    'previous_label', case when v_prev_month is not null then to_char(v_prev_month, 'FMMonth YYYY') end,
    'currency', (select coalesce(en.default_currency, 'AED') from public.entities en where en.id = p.entity_id),
    'employees', v_rows,
    'left_since_last_month', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name, 'net_prev', t.net) order by e.full_name)
      from (select employee_id, sum(net) as net from (
              select employee_id, net from (select r.employee_id, r.net from public.payroll_records r join public.payroll_periods pp on pp.id = r.period_id
                      where pp.entity_id = p.entity_id and r.superseded_by_record_id is null and pp.id <> p.id
                        and ((pp.kind = 'regular' and pp.period_start = v_prev_month) or (pp.kind = 'off_cycle' and pp.for_month = v_prev_month))) a
              union all
              select ls.employee_id, ls.net_pay from public.payslips ls join public.payroll_runs lr on lr.id = ls.payroll_run_id
                      where lr.entity_id = p.entity_id and lr.status in ('approved', 'paid') and date_trunc('month', lr.period_start)::date = v_prev_month) u
            group by employee_id) t
      join public.employees e on e.id = t.employee_id
      where not exists (select 1 from public.payroll_records c where c.period_id = p.id and c.employee_id = t.employee_id
                          and c.superseded_by_record_id is null)), '[]'::jsonb),
    'totals', jsonb_build_object(
      'net_now', (select coalesce(sum(net), 0) from public.payroll_records where period_id = p.id and superseded_by_record_id is null),
      'net_prev', (
        select coalesce(sum(n), 0) from (
          select r.net as n from public.payroll_records r join public.payroll_periods pp on pp.id = r.period_id
            where pp.entity_id = p.entity_id and r.superseded_by_record_id is null and pp.id <> p.id
              and ((pp.kind = 'regular' and pp.period_start = v_prev_month) or (pp.kind = 'off_cycle' and pp.for_month = v_prev_month))
          union all
          select ls.net_pay from public.payslips ls join public.payroll_runs lr on lr.id = ls.payroll_run_id
            where lr.entity_id = p.entity_id and lr.status in ('approved', 'paid') and date_trunc('month', lr.period_start)::date = v_prev_month
        ) z)));
end;
$function$;
revoke all on function public.get_payroll_changes(uuid) from public, anon;
grant execute on function public.get_payroll_changes(uuid) to authenticated;
