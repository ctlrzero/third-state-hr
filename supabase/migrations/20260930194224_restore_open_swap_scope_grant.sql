-- The shifts access rule (shifts_select) calls this helper, so signed-in users must be allowed to execute it.
-- Without this grant every read of public.shifts failed with "permission denied for function".
grant execute on function public._open_swap_in_staff_scope(uuid) to authenticated;
