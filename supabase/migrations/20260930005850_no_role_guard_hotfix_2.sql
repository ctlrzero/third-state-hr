-- Security hotfix, part 2: same no-role guard as 20260929211250_no_role_guard_hotfix
-- for the 13 functions a wider scan found. They write the check as
-- `if not (public.my_role() = ...)`, which is null — so passes — for a revoked
-- or profile-less user. _require_entity_admin is the shared admin check behind
-- branch setup, opening hours, staffing needs and work patterns.
--
-- Not included (already safe): upsert_position and _imm_require start with
-- `if not public.is_active_user() or ...`, and is_active_user() is never null.

do $hotfix$
declare
  v_names text[] := array[
    '_require_entity_admin', 'check_shift_work_pattern', 'create_onboarding_template',
    'deactivate_onboarding_template', 'delete_pending_document', 'replace_onboarding_template',
    'seed_default_onboarding_template', 'set_employee_numbering', 'set_onboarding_settings',
    'start_onboarding_direct_hire', 'start_onboarding_for_employee', 'start_onboarding_from_offer',
    'upsert_onboarding_policy'];
  v_guard text := E'\n  if auth.uid() is not null and public.my_role() is null then\n'
               || E'    raise exception using errcode = ''42501'', message = ''Not authorized: your access is not active'';\n'
               || E'  end if;\n';
  f record;
  v_def text;
  v_new text;
  v_done int := 0;
  v_skipped int := 0;
begin
  for f in
    select p.oid, p.proname from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = any(v_names)
  loop
    v_def := pg_get_functiondef(f.oid);
    if position('your access is not active' in v_def) > 0 then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_new := regexp_replace(v_def, '(\n[ \t]*begin[ \t]*)\n', E'\\1' || v_guard, 'i');
    if v_new = v_def then
      raise exception 'No body start found in %', f.proname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done + v_skipped <> cardinality(v_names) then
    raise exception 'Expected % functions, guarded % and skipped %', cardinality(v_names), v_done, v_skipped;
  end if;
  raise notice 'no-role guard: % added, % already present', v_done, v_skipped;
end
$hotfix$;
