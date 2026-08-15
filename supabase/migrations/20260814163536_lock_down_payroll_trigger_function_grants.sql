
-- enforce_payroll_child_immutability() is a trigger callback only — it has
-- no business being callable as a direct RPC by anyone. Trigger firing
-- does not require the invoking session to hold EXECUTE on the trigger
-- function, so revoking it from every role (including authenticated) does
-- not break the triggers themselves; it only removes the accidental
-- /rest/v1/rpc/enforce_payroll_child_immutability exposure that PostgREST
-- creates by default for any public-schema function.
revoke all on function public.enforce_payroll_child_immutability() from public, anon, authenticated;

