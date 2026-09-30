-- Fix: the pre-payroll reminder said "September payroll not started" although September had been run and
-- approved on the old payroll screen (payroll_runs). A month counts as handled when either screen has it:
-- an approved/paid old-screen run covering the month → no reminder; a draft/in-review one → remind to
-- finish it there. Only when neither screen has the month does it say "not started".
do $patch$
declare
  v_def text := pg_get_functiondef('public.run_payroll_readiness_reminders()'::regprocedure);
  v_old text := $a$    if v_period is null then
      v_title := format('%s payroll not started', to_char(v_month, 'FMMonth'));
      v_msg := format('Pay day is %s. Open the %s payroll month and prepare it.', to_char(v_pay, 'Dy DD Mon'), to_char(v_month, 'FMMonth'));
    else$a$;
  v_new text := $a$    if v_period is null then
      select pr.status into v_legacy_status from public.payroll_runs pr
      where pr.entity_id = en.id and pr.period_start <= (v_month + interval '1 month - 1 day')::date
        and pr.period_end >= v_month
      order by case pr.status when 'paid' then 0 when 'approved' then 1 when 'in_review' then 2 else 3 end, pr.created_at desc
      limit 1;
      -- Run and approved on the old payroll screen: nothing to remind.
      continue when v_legacy_status in ('approved', 'paid');
      if v_legacy_status is not null then
        v_title := format('%s payroll not approved yet', to_char(v_month, 'FMMonth'));
        v_msg := format('Pay day is %s. %s is still %s on the old payroll screen — finish and approve it there.',
                        to_char(v_pay, 'Dy DD Mon'), to_char(v_month, 'FMMonth'), replace(v_legacy_status, '_', ' '));
      else
        v_title := format('%s payroll not started', to_char(v_month, 'FMMonth'));
        v_msg := format('Pay day is %s. Open the %s payroll month and prepare it.', to_char(v_pay, 'Dy DD Mon'), to_char(v_month, 'FMMonth'));
      end if;
    else$a$;
begin
  if position(v_old in v_def) = 0 or position($a$  v_n int := 0;
$a$ in v_def) = 0 then
    raise exception 'run_payroll_readiness_reminders patch points not found';
  end if;
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, $a$  v_n int := 0;
$a$, $a$  v_n int := 0;
  v_legacy_status text;
$a$);
  execute v_def;
end
$patch$;
