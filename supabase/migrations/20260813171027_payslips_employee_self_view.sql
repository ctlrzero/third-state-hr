
-- The Payroll nav item is already shown to staff (see AppShell.tsx comment
-- "Payroll must never render for location_manager" — staff IS included),
-- but payslips_select only granted owner/entity_admin, so an employee had
-- no way to see their own computed pay. Adding narrow, read-only,
-- self-scoped SELECT policies — mirroring the same employee_id =
-- my_employee_id() pattern used elsewhere (employee_documents,
-- timesheet_entries) — rather than touching compensation config
-- (employee_compensation stays owner/entity_admin only) or granting any
-- write access.
create policy payslips_select_self on public.payslips
for select
using (employee_id = my_employee_id());

create policy deductions_select_self on public.payslip_deductions
for select
using (employee_id = my_employee_id());
