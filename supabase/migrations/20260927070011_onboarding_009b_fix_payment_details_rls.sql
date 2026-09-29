-- Bug fix: employee_payment_details_select joined public.employees to check
-- payroll_can(e.entity_id, 'approve'), but employees' own SELECT policy has
-- no payroll branch (only owner / entity_admin / location_manager / self),
-- so the EXISTS silently returned false for a payroll_admin-preset STAFF
-- caller (a non-owner/entity_admin payroll approver, e.g. an accountant
-- role) even though payroll_can() itself returned true. Fixed by resolving
-- the employee's entity via the existing SECURITY DEFINER helper
-- payroll_employee_entity(), which bypasses employees' RLS instead of
-- depending on it.
drop policy if exists employee_payment_details_select on public.employee_payment_details;
create policy employee_payment_details_select on public.employee_payment_details for select to authenticated
  using ((select public.is_active_user()) and (
    employee_id = (select public.my_employee_id())
    or (public.payroll_can(public.payroll_employee_entity(employee_id), 'approve')
        and employee_id is distinct from (select public.my_employee_id()))
  ));;
