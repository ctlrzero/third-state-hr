-- Period list: flag runs that are completely done (every current record approved, published and fully paid)
-- so the Payroll page can tuck them away instead of showing them as the active month.
do $m$
declare v text;
begin
  v := pg_get_functiondef('public.payroll_periods_list(uuid)'::regprocedure);
  if position($a$'approved', (select count(*)$a$ in v) = 0 then raise exception 'patch point missing'; end if;
  v := replace(v, $a$'approved', (select count(*)$a$, $b$'finished', (
        exists (select 1 from public.payroll_records r where r.period_id = p.id and r.superseded_by_record_id is null)
        and not exists (
          select 1 from public.payroll_records r
          where r.period_id = p.id and r.superseded_by_record_id is null
            and (r.record_status <> 'approved' or r.published_at is null
                 or coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.record_id = r.id and pp.status = 'recorded'), 0) < r.net))),
      'approved', (select count(*)$b$);
  execute v;
end $m$;
