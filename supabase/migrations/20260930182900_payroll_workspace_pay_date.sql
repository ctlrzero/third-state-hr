-- Payroll workspace returns the effective pay date and the month title for the header / schedule panel.
do $patch$
declare v_def text := pg_get_functiondef('public.payroll_workspace(uuid)'::regprocedure);
begin
  if position($a$    'period', to_jsonb(p),$a$ in v_def) = 0 then raise exception 'payroll_workspace patch point not found'; end if;
  execute replace(v_def, $a$    'period', to_jsonb(p),$a$,
    $a$    'period', to_jsonb(p),
    'pay_date', public._payroll_pay_date(p.id),
    'title', public._payroll_period_title(p),$a$);
end
$patch$;
