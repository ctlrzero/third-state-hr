
-- leave_requests itself already had correct, symmetric RLS (self-insert
-- as pending only, self-select, admin-scoped decide via
-- approve_leave_request()) — no gaps there. But leave_types and
-- leave_balances had no staff-facing SELECT policy at all, so an employee
-- had no way to see which leave types exist for their entity, or their own
-- remaining balance, before submitting a request. Add narrow, read-only
-- access for both, scoped the same way self-access is scoped everywhere
-- else in this project.
create policy leave_types_select_self on public.leave_types
  for select
  to authenticated
  using (entity_id = my_entity());

create policy leave_balances_select_self on public.leave_balances
  for select
  to authenticated
  using (employee_id = my_employee_id());
