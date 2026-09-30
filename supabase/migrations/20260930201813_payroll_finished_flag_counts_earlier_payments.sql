-- A correction inherits what was paid on the record it replaced, so "finished" must use the same money rule as the payroll rows.
do $m$
declare v text;
begin
  v := pg_get_functiondef('public.payroll_periods_list(uuid)'::regprocedure);
  if position($a$coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.record_id = r.id and pp.status = 'recorded'), 0) < r.net$a$ in v) = 0 then raise exception 'patch point missing'; end if;
  v := replace(v, $a$coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.record_id = r.id and pp.status = 'recorded'), 0) < r.net$a$,
                  $b$(select m.outstanding from public._payroll_money(r.id) m) > 0$b$);
  execute v;
end $m$;
