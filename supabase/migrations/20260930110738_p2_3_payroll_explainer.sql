-- P2-3: Payroll explainer (read-only). get_payroll_changes compares each current record in a payroll month
-- with the same person's record in the previous regular month, line by line (earnings, deductions),
-- so the payroll team can see why pay changed. The payroll-explainer Edge Function turns this into plain
-- sentences with Claude — pay amounts included, which the owner approved on 2026-09-30 — and stores each
-- explanation with log_payroll_explanation. Needs payroll view_pay. Changes nothing.

alter table public.ai_suggestions drop constraint ai_suggestions_kind_check;
alter table public.ai_suggestions add constraint ai_suggestions_kind_check
  check (kind in ('cover_offer', 'roster_summary', 'payroll_explainer'));

create or replace function public.get_payroll_changes(p_period_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  p public.payroll_periods;
  v_prev uuid;
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

  select pp.id into v_prev from public.payroll_periods pp
  where pp.entity_id = p.entity_id and pp.kind = 'regular' and pp.period_start < p.period_start
  order by pp.period_start desc limit 1;

  with cur as (
    select r.id, r.employee_id, r.gross, r.deductions, r.net, r.record_status
    from public.payroll_records r
    where r.period_id = p.id and r.superseded_by_record_id is null
  ),
  prev as (
    select r.id, r.employee_id, r.gross, r.deductions, r.net
    from public.payroll_records r
    where r.period_id = v_prev and r.superseded_by_record_id is null
  ),
  cl as (
    select c.employee_id, l.kind, l.code, max(l.label) as label, sum(l.amount) as amount,
           string_agg(l.explanation, ' ') as explanation
    from cur c join public.payroll_lines l on l.record_id = c.id
    group by c.employee_id, l.kind, l.code
  ),
  pl as (
    select pv.employee_id, l.kind, l.code, max(l.label) as label, sum(l.amount) as amount
    from prev pv join public.payroll_lines l on l.record_id = pv.id
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
           c.gross as gross_now, pv.gross as gross_prev, pv.id is null as new_this_month,
           coalesce((select jsonb_agg(jsonb_build_object(
                      'kind', l.kind, 'code', l.code, 'label', l.label, 'now', l.now_amount, 'prev', l.prev_amount,
                      'change', l.now_amount - l.prev_amount, 'explanation', l.now_explanation)
                      order by abs(l.now_amount - l.prev_amount) desc)
                     from lines l where l.employee_id = c.employee_id and l.now_amount <> l.prev_amount), '[]'::jsonb) as changes
    from cur c
    join public.employees e on e.id = c.employee_id
    left join prev pv on pv.employee_id = c.employee_id
  ) x;

  return jsonb_build_object(
    'period_id', p.id, 'label', coalesce(p.label, to_char(p.period_start, 'FMMonth YYYY')),
    'previous_period_id', v_prev,
    'previous_label', (select coalesce(pp.label, to_char(pp.period_start, 'FMMonth YYYY')) from public.payroll_periods pp where pp.id = v_prev),
    'currency', (select coalesce(en.default_currency, 'AED') from public.entities en where en.id = p.entity_id),
    'employees', v_rows,
    'left_since_last_month', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name, 'net_prev', r.net) order by e.full_name)
      from public.payroll_records r join public.employees e on e.id = r.employee_id
      where r.period_id = v_prev and r.superseded_by_record_id is null
        and not exists (select 1 from public.payroll_records c where c.period_id = p.id and c.employee_id = r.employee_id
                          and c.superseded_by_record_id is null)), '[]'::jsonb),
    'totals', jsonb_build_object(
      'net_now', (select coalesce(sum(net), 0) from public.payroll_records where period_id = p.id and superseded_by_record_id is null),
      'net_prev', (select coalesce(sum(net), 0) from public.payroll_records where period_id = v_prev and superseded_by_record_id is null)));
end;
$function$;
revoke all on function public.get_payroll_changes(uuid) from public, anon;
grant execute on function public.get_payroll_changes(uuid) to authenticated;

create or replace function public.log_payroll_explanation(p_period_id uuid, p_inputs jsonb, p_output jsonb, p_model text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_entity uuid;
  v_id uuid;
begin
  if auth.uid() is null or public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select entity_id into v_entity from public.payroll_periods where id = p_period_id;
  if v_entity is null then
    raise exception using errcode = 'P0002', message = 'Payroll month not found';
  end if;
  perform public._payroll_require(v_entity, 'view_pay');
  insert into public.ai_suggestions (entity_id, location_id, kind, target_type, target_id, inputs, output, model)
  values (v_entity, null, 'payroll_explainer', 'payroll_periods', p_period_id,
          coalesce(p_inputs, '{}'::jsonb), coalesce(p_output, '{}'::jsonb), p_model)
  returning id into v_id;
  return v_id;
end;
$function$;
revoke all on function public.log_payroll_explanation(uuid, jsonb, jsonb, text) from public, anon;
grant execute on function public.log_payroll_explanation(uuid, jsonb, jsonb, text) to authenticated;

-- Payroll explanations contain pay: only people who may see pay can read them back.
drop policy ai_suggestions_select on public.ai_suggestions;
create policy ai_suggestions_select on public.ai_suggestions for select to authenticated using (
  case when kind = 'payroll_explainer' then public.payroll_can(entity_id, 'view_pay')
  else public.my_role() = 'owner'
    or (public.my_role() = 'entity_admin' and entity_id = public.my_entity())
    or (public.my_role() in ('location_manager', 'shift_supervisor') and location_id = public.my_location())
  end
);
