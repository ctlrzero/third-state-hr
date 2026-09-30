-- Staff portal: a payslip replaced by a correction is no longer returned to the employee at all —
-- not in their list (payroll_my_payslips) and not when opened directly, e.g. from an old "Payslip ready"
-- notification (payroll_my_payslip → "This payslip was replaced — see the corrected one"). The record is kept
-- for audit / WPS and payroll still sees it in the workspace. Nothing is deleted.
do $patch$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.payroll_my_payslips()'::regprocedure);
  if position($a$where r.employee_id = v_emp and r.published_at is not null)$a$ in v_def) = 0 then
    raise exception 'payroll_my_payslips patch point not found';
  end if;
  execute replace(v_def, $a$where r.employee_id = v_emp and r.published_at is not null)$a$,
                         $a$where r.employee_id = v_emp and r.published_at is not null and r.superseded_by_record_id is null)$a$);

  v_def := pg_get_functiondef('public.payroll_my_payslip(uuid)'::regprocedure);
  if position($a$    raise exception 'Payslip not found' using errcode = 'P0002';
  end if;
$a$ in v_def) = 0 then
    raise exception 'payroll_my_payslip patch point not found';
  end if;
  execute replace(v_def, $a$    raise exception 'Payslip not found' using errcode = 'P0002';
  end if;
$a$, $a$    raise exception 'Payslip not found' using errcode = 'P0002';
  end if;
  if r.superseded_by_record_id is not null then
    raise exception 'This payslip was replaced by a corrected one. Open your latest payslip for this month in Payslips.' using errcode = 'P0002';
  end if;
$a$);
end
$patch$;
