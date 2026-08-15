-- ============================================================================
-- F&B HR System — Employee Self-Service (ESS) RLS Policies
-- Closes the gap for BR-ESS-001..006: every existing policy on these tables
-- branched only on my_role() in ('owner','entity_admin','location_manager').
-- There is no backend that runs with a service-role key (the frontend uses
-- only the anon key — see src/supabaseClient.js), so RLS is the only
-- enforcement layer; a 'staff' user currently cannot see or submit anything,
-- even their own records.
--
-- These policies are additive (Postgres OR's multiple permissive policies
-- for the same command together), so none of the existing owner/entity_admin/
-- location_manager access is changed.
--
-- Scope: read access to own profile/documents/availability/onboarding/
-- timesheets, plus read+submit for own leave requests. No write access is
-- granted to anything payroll-adjacent (employee_compensation, payroll_runs,
-- tips_pools, payslip_deductions, payslips all remain untouched).
--
-- Not included here: shift_swap_requests. Granting staff access there needs
-- a product decision this task didn't specify — can staff only view their
-- own swap requests, or also see (and claim) open swaps at their location?
-- Claiming requires an UPDATE path (claimed_by), not just SELECT/INSERT.
-- Left for a follow-up migration once that's decided.
-- ============================================================================

-- Helper: resolves the calling user's own employee row, if any linked.
create or replace function my_employee_id() returns uuid
language sql stable security definer as $$
  select id from employees where auth_user_id = auth.uid();
$$;

-- employees: staff can see their own record. This is required for the ESS
-- portal to load "my profile" at all, and it's also load-bearing for every
-- policy below — a subquery against `employees` inside another table's
-- policy is still subject to employees' own RLS (it isn't run through a
-- SECURITY DEFINER function), so without this, employee_id = my_employee_id()
-- checks elsewhere would only work if my_employee_id() itself bypasses RLS,
-- which it does (security definer) — but the portal still needs a direct
-- employees_select policy to read the profile row itself.
create policy "employees_select_own" on employees for select
  using (auth_user_id = auth.uid());

-- employee_documents: staff can view (not upload) their own documents.
-- Uploads stay manager/admin-mediated, per the existing document vault note.
create policy "documents_select_own" on employee_documents for select
  using (employee_id = my_employee_id());

-- employee_availability: staff can view their own availability.
create policy "availability_select_own" on employee_availability for select
  using (employee_id = my_employee_id());

-- onboarding_checklist_items: staff can view their own checklist.
create policy "checklist_select_own" on onboarding_checklist_items for select
  using (employee_id = my_employee_id());

-- timesheet_entries: staff can view their own timesheet entries. Read-only —
-- hours stay manager-entered, no staff write path here.
create policy "timesheet_select_own" on timesheet_entries for select
  using (employee_id = my_employee_id());

-- leave_requests: staff can view their own requests and submit new ones.
-- Insert is pinned to their own employee_id, forced to 'pending', and can't
-- carry a decision (decided_by/decided_at) — approval stays manager-mediated
-- via approve_leave_request().
create policy "leave_requests_select_own" on leave_requests for select
  using (employee_id = my_employee_id());

create policy "leave_requests_insert_own" on leave_requests for insert
  with check (
    employee_id = my_employee_id()
    and status = 'pending'
    and decided_by is null
    and decided_at is null
  );

