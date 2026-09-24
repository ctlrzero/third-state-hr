revoke all privileges on all tables in schema public from anon;

revoke all privileges on all tables in schema public from authenticated;

grant SELECT, UPDATE on table public.app_settings to authenticated;
grant SELECT on table public.attendance_records to authenticated;
grant SELECT on table public.audit_log to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.candidate_files to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.candidates to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.employee_availability to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.employee_change_requests to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.employee_compensation to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.employee_documents to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.employee_identity_documents to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.employees to authenticated;
grant SELECT, INSERT, UPDATE on table public.entities to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.interview_feedback to authenticated;
grant SELECT on table public.interview_round_closures to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.interview_stages to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.interviews to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.job_applications to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.job_requisitions to authenticated;
grant SELECT on table public.leave_accrual_policies to authenticated;
grant SELECT on table public.leave_accrual_runs to authenticated;
grant SELECT on table public.leave_balances to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.leave_requests to authenticated;
grant SELECT, INSERT, UPDATE on table public.leave_types to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.locations to authenticated;
grant SELECT, UPDATE on table public.notifications to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.offers to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.onboarding_checklist_items to authenticated;
grant SELECT, INSERT, UPDATE on table public.payroll_runs to authenticated;
grant SELECT on table public.payslip_deductions to authenticated;
grant SELECT on table public.payslips to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.positions to authenticated;
grant SELECT, UPDATE on table public.profiles to authenticated;
grant SELECT on table public.schedule_templates to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.shift_swap_requests to authenticated;
grant SELECT, INSERT, UPDATE, DELETE on table public.shifts to authenticated;
grant SELECT on table public.timesheet_entries to authenticated;
grant SELECT on table public.tips_pools to authenticated;
grant SELECT on table public.compliance_alerts to authenticated;
grant SELECT on table public.payroll_run_totals to authenticated;

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
