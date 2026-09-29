-- Security hotfix: refuse signed-in callers with no active role.
--
-- These functions authorise with `if not (my_role() = 'owner' or ...)`.
-- my_role() is null for a revoked user (profiles.is_active = false) or a user
-- with no profile, which makes the whole condition null, so `if not null`
-- never raised and the call went through. P0-1 fixed the same bug in
-- approve_leave_request, publish_schedule_period and
-- generate_shifts_from_templates.
--
-- The guard is inserted as the first statement of each live function body.
-- It only fires when there is a signed-in user (auth.uid() is not null)
-- without an active role, so database-internal and service calls (no JWT
-- subject) behave exactly as before. Idempotent: functions that already
-- carry the guard are skipped.

do $hotfix$
declare
  v_names text[] := array[
    'adjust_leave_balance', 'approve_document', 'approve_shift_swap', 'archive_document',
    'bulk_import_employees', 'cancel_interview', 'cleanup_incomplete_document_uploads',
    'close_interview_round', 'configure_leave_accrual_policy', 'convert_offer_to_employee',
    'create_payroll_revision', 'create_schedule_template', 'deactivate_schedule_template',
    'decide_employee_change_request', 'grant_leave_balance', 'reject_document',
    'reopen_interview_feedback', 'replace_schedule_template', 'reschedule_interview',
    'run_leave_accrual', 'run_payroll_calculation', 'seed_document_requirements_for_employee',
    'waive_document_requirement'];
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
    -- first line that is just "begin" = start of the top-level body
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
