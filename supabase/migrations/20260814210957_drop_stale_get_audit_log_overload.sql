
-- Final verification pass: Phase 3.13 replaced get_audit_log()'s 4-parameter
-- signature with a 10-parameter one via CREATE OR REPLACE. Since Postgres
-- overload identity is the full parameter *type* list, that created a new
-- overload alongside the old one rather than truly replacing it — both
-- (integer,timestamptz,text,text) and the new 10-arg version have existed
-- side by side since. Confirmed anon EXECUTE was already correctly revoked
-- on the stale overload (no security hole), but it's dead/confusing code:
-- Reports.tsx only ever calls the 10-arg version by name, and keeping two
-- same-named overloads with diverging behavior is a real footgun for future
-- callers who might pass only the original 4 positional args and silently
-- get the old, less-capable codepath. Dropping it.
drop function if exists public.get_audit_log(integer, timestamptz, text, text);

