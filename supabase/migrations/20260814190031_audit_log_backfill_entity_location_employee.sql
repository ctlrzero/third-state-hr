
-- One-time backfill using the same resolution paths the old get_audit_log() join list
-- used, applied directly to the historical rows themselves rather than at read time.
-- This is intentionally a one-off UPDATE, not a kept function -- once complete, all
-- reads go through the direct entity_id/location_id/employee_id columns.

update public.audit_log a
set entity_id = ed_emp.entity_id, location_id = ed_emp.home_location_id, employee_id = ed.employee_id
from public.employee_documents ed
join public.employees ed_emp on ed_emp.id = ed.employee_id
where a.table_name = 'employee_documents' and ed.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = emp.entity_id, location_id = emp.home_location_id, employee_id = emp.id
from public.employees emp
where a.table_name = 'employees' and emp.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = sh.entity_id, location_id = sh.location_id, employee_id = sh.employee_id
from public.shifts sh
where a.table_name = 'shifts' and sh.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = ssr_shift.entity_id, location_id = ssr_shift.location_id
from public.shift_swap_requests ssr
join public.shifts ssr_shift on ssr_shift.id = ssr.shift_id
where a.table_name = 'shift_swap_requests' and ssr.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = iv_jr.entity_id, location_id = iv_jr.location_id
from public.interviews iv
join public.job_applications iv_ja on iv_ja.id = iv.application_id
join public.job_requisitions iv_jr on iv_jr.id = iv_ja.requisition_id
where a.table_name = 'interviews' and iv.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = ifb_jr.entity_id, location_id = ifb_jr.location_id
from public.interview_feedback ifb
join public.interviews ifb_iv on ifb_iv.id = ifb.interview_id
join public.job_applications ifb_ja on ifb_ja.id = ifb_iv.application_id
join public.job_requisitions ifb_jr on ifb_jr.id = ifb_ja.requisition_id
where a.table_name = 'interview_feedback' and ifb.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = off_jr.entity_id, location_id = off_jr.location_id
from public.offers off
join public.job_applications off_ja on off_ja.id = off.application_id
join public.job_requisitions off_jr on off_jr.id = off_ja.requisition_id
where a.table_name = 'offers' and off.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = pr.entity_id
from public.payroll_runs pr
where a.table_name in ('payroll_runs', 'payslips') and pr.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = te_pr.entity_id, employee_id = te.employee_id
from public.timesheet_entries te
join public.payroll_runs te_pr on te_pr.id = te.payroll_run_id
where a.table_name = 'timesheet_entries' and te.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = tp_pr.entity_id, location_id = tp.location_id
from public.tips_pools tp
join public.payroll_runs tp_pr on tp_pr.id = tp.payroll_run_id
where a.table_name = 'tips_pools' and tp.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = pd_pr.entity_id, employee_id = pd.employee_id
from public.payslip_deductions pd
join public.payroll_runs pd_pr on pd_pr.id = pd.payroll_run_id
where a.table_name = 'payslip_deductions' and pd.id = a.record_id and a.entity_id is null;

update public.audit_log a
set entity_id = cf_cand.entity_id
from public.candidate_files cf
join public.candidates cf_cand on cf_cand.id = cf.candidate_id
where a.table_name = 'candidate_files' and cf.id = a.record_id and a.entity_id is null;

-- Rejection rows written by the new payroll RPCs already carry table_name='payroll_runs'
-- with record_id = the run id, so the payroll_runs backfill above already covers them.;
