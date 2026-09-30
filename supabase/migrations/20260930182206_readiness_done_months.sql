-- Payroll checklist: a finished month (every current payslip published) no longer shows blockers such as
-- "No verified bank or payment details" — it returns done:true with no items. For months still in progress,
-- people who have already been paid no longer count as missing payment details.
do $patch$
declare
  v_def text := pg_get_functiondef('public._payroll_readiness(uuid)'::regprocedure);
  v_new text := v_def;
begin
  -- 1) payment details: skip records that already have a recorded payment
  if position($a$          and not exists (select 1 from public.employee_payment_details d where d.employee_id = e.id and d.status = 'verified')) x;$a$ in v_new) = 0 then
    raise exception 'payment_details patch point not found';
  end if;
  v_new := replace(v_new,
    $a$          and not exists (select 1 from public.employee_payment_details d where d.employee_id = e.id and d.status = 'verified')) x;$a$,
    $a$          and not exists (select 1 from public.employee_payment_details d where d.employee_id = e.id and d.status = 'verified')
          and not exists (select 1 from public.payroll_records pr2 join public.payroll_payments pm on pm.record_id = pr2.id
                          where pr2.period_id = p.id and pr2.employee_id = e.id and pr2.superseded_by_record_id is null
                            and pm.status = 'recorded')) x;$a$);

  -- 2) finished month: nothing left to do
  if position($a$  return jsonb_build_object(
    'period_id', p.id,$a$ in v_new) = 0 then
    raise exception 'return patch point not found';
  end if;
  v_new := replace(v_new, $a$  return jsonb_build_object(
    'period_id', p.id,$a$, $a$  if v_total > 0 and not exists (select 1 from public.payroll_records pr
                                 where pr.period_id = p.id and pr.superseded_by_record_id is null and pr.published_at is null) then
    v_items := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'done', v_total > 0 and not exists (select 1 from public.payroll_records pr
                                        where pr.period_id = p.id and pr.superseded_by_record_id is null and pr.published_at is null),
    'period_id', p.id,$a$);
  execute v_new;
end
$patch$;
