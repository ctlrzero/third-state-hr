-- Prior migration revoked EXECUTE from anon/authenticated directly, but every
-- function still has an implicit EXECUTE grant to PUBLIC from creation time (or,
-- for brand-new functions, from Postgres's default-grant-to-PUBLIC behavior).
-- PUBLIC grants apply to every role including anon/authenticated regardless of
-- role-specific revokes, which is why the advisor still flagged them. Revoke from
-- PUBLIC explicitly, then re-grant EXECUTE only where a real caller needs it.

revoke execute on function public.log_employee_changes() from public;
revoke execute on function public.log_offer_changes() from public;
revoke execute on function public.handle_new_user() from public;
revoke execute on function public.set_updated_at() from public;
revoke execute on function public.sync_shift_status() from public;
revoke execute on function public.seed_employee_availability() from public;
revoke execute on function public.seed_employee_compensation() from public;
revoke execute on function public.seed_leave_balances_for_employee() from public;
revoke execute on function public.seed_leave_balances_for_leave_type() from public;
revoke execute on function public.seed_onboarding_checklist() from public;
revoke execute on function public.enforce_profile_role_change_authority() from public;
revoke execute on function public.prevent_payroll_run_status_regression() from public;
-- (these are trigger-only; no grant is re-added -- trigger firing is unaffected)

revoke execute on function public.approve_leave_request(uuid, text) from public;
grant execute on function public.approve_leave_request(uuid, text) to authenticated;

revoke execute on function public.approve_shift_swap(uuid, text) from public;
grant execute on function public.approve_shift_swap(uuid, text) to authenticated;

revoke execute on function public.convert_offer_to_employee(uuid) from public;
grant execute on function public.convert_offer_to_employee(uuid) to authenticated;

revoke execute on function public.run_payroll_calculation(uuid) from public;
grant execute on function public.run_payroll_calculation(uuid) to authenticated;

revoke execute on function public.decide_employee_change_request(uuid, text, text) from public;
grant execute on function public.decide_employee_change_request(uuid, text, text) to authenticated;

revoke execute on function public.my_role() from public;
grant execute on function public.my_role() to authenticated;

revoke execute on function public.my_entity() from public;
grant execute on function public.my_entity() to authenticated;

revoke execute on function public.my_location() from public;
grant execute on function public.my_location() to authenticated;

revoke execute on function public.my_employee_id() from public;
grant execute on function public.my_employee_id() to authenticated;

