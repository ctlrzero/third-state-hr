-- Unindexed foreign keys: every FK column flagged by the performance advisor.
create index if not exists audit_log_changed_by_idx on public.audit_log(changed_by);
create index if not exists candidates_created_by_idx on public.candidates(created_by);
create index if not exists candidates_entity_id_idx on public.candidates(entity_id);
create index if not exists candidates_location_id_idx on public.candidates(location_id);
create index if not exists employee_documents_uploaded_by_idx on public.employee_documents(uploaded_by);
create index if not exists employees_auth_user_id_idx on public.employees(auth_user_id);
create index if not exists employees_position_id_idx on public.employees(position_id);
create index if not exists interviews_application_id_idx on public.interviews(application_id);
create index if not exists interviews_interviewer_id_idx on public.interviews(interviewer_id);
create index if not exists interviews_recorded_by_idx on public.interviews(recorded_by);
create index if not exists interviews_stage_id_idx on public.interviews(stage_id);
create index if not exists job_applications_candidate_id_idx on public.job_applications(candidate_id);
create index if not exists job_requisitions_closed_by_idx on public.job_requisitions(closed_by);
create index if not exists job_requisitions_created_by_idx on public.job_requisitions(created_by);
create index if not exists job_requisitions_entity_id_idx on public.job_requisitions(entity_id);
create index if not exists job_requisitions_location_id_idx on public.job_requisitions(location_id);
create index if not exists job_requisitions_position_id_idx on public.job_requisitions(position_id);
create index if not exists leave_balances_leave_type_id_idx on public.leave_balances(leave_type_id);
create index if not exists leave_requests_decided_by_idx on public.leave_requests(decided_by);
create index if not exists leave_requests_leave_type_id_idx on public.leave_requests(leave_type_id);
create index if not exists offers_created_by_idx on public.offers(created_by);
create index if not exists offers_position_id_idx on public.offers(position_id);
create index if not exists offers_sent_by_idx on public.offers(sent_by);
create index if not exists onboarding_checklist_items_completed_by_idx on public.onboarding_checklist_items(completed_by);
create index if not exists payroll_runs_approved_by_idx on public.payroll_runs(approved_by);
create index if not exists payroll_runs_created_by_idx on public.payroll_runs(created_by);
create index if not exists payslip_deductions_employee_id_idx on public.payslip_deductions(employee_id);
create index if not exists payslip_deductions_payroll_run_id_idx on public.payslip_deductions(payroll_run_id);
create index if not exists payslips_employee_id_idx on public.payslips(employee_id);
create index if not exists profiles_entity_id_idx on public.profiles(entity_id);
create index if not exists profiles_location_id_idx on public.profiles(location_id);
create index if not exists shift_swap_requests_claimed_by_idx on public.shift_swap_requests(claimed_by);
create index if not exists shift_swap_requests_requested_by_idx on public.shift_swap_requests(requested_by);
create index if not exists shift_swap_requests_resolved_by_idx on public.shift_swap_requests(resolved_by);
create index if not exists shift_swap_requests_shift_id_idx on public.shift_swap_requests(shift_id);
create index if not exists shifts_created_by_idx on public.shifts(created_by);
create index if not exists shifts_entity_id_idx on public.shifts(entity_id);
create index if not exists shifts_position_id_idx on public.shifts(position_id);
create index if not exists timesheet_entries_employee_id_idx on public.timesheet_entries(employee_id);
create index if not exists tips_pools_location_id_idx on public.tips_pools(location_id);
create index if not exists employee_identity_documents_employee_id_idx on public.employee_identity_documents(employee_id);

-- Auth RLS Initialization Plan: wrap literal auth.uid() calls in a scalar
-- subselect so Postgres evaluates it once per statement instead of once per row.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select
on public.profiles
for select
using (id = (select auth.uid()) or my_role() = 'owner');

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
on public.profiles
for update
using (id = (select auth.uid()));

drop policy if exists employees_select_own on public.employees;
create policy employees_select_own
on public.employees
for select
using (auth_user_id = (select auth.uid()));

drop policy if exists interviews_access on public.interviews;
create policy interviews_access
on public.interviews
for all
using (
  interviewer_id = (select auth.uid())
  or exists (
    select 1 from job_applications ja join job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (my_role() = 'owner' or (my_role() = 'entity_admin' and jr.entity_id = my_entity()) or (my_role() = 'location_manager' and jr.location_id = my_location()))
  )
)
with check (
  interviewer_id = (select auth.uid())
  or exists (
    select 1 from job_applications ja join job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (my_role() = 'owner' or (my_role() = 'entity_admin' and jr.entity_id = my_entity()) or (my_role() = 'location_manager' and jr.location_id = my_location()))
  )
);

