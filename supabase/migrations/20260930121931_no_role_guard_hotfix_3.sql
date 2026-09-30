-- Security hotfix 3 (found by the new regression suite, supabase/tests/suite/): 44 more functions checked
-- `if not (my_role() = 'owner' or ...)` (or `my_role() <> 'owner'`). my_role() is NULL for a revoked user or a
-- login without a profile, so the whole condition was NULL and the check never raised — e.g. a revoked manager
-- could still change or cancel published shifts, correct attendance or stage document uploads.
-- Same fix as hotfixes 1 and 2: every signed-in call must have an active role. Cron/system calls (no auth.uid())
-- are unaffected. Trigger functions and functions used inside RLS policies are left alone.
do $patch$
declare
  v_names text[] := array[
    'activate_workflow_rule','adjust_published_shift','admin_upsert_entity','admin_upsert_location',
    'apply_attendance_adjustment','approve_and_activate_employee','approve_data_retention_policy',
    'approve_leave_accrual_policy','cancel_published_shift','confirm_document_upload','correct_attendance_record',
    'create_document_upload','deactivate_workflow_rule','decide_probation_outcome','export_audit_log',
    'get_application_interview_feedback','get_attendance_exceptions','get_audit_log',
    'get_document_requirements_for_employee','get_documents_for_review','get_employee_completeness',
    'get_entity_dependency_summary','get_location_attendance_overview','get_scheduling_setup','get_workflow_rules',
    'get_workflow_runs','get_wps_export_readiness','log_document_access','payroll_approve','payroll_get_settings',
    'payroll_save_settings','payroll_set_permission','payroll_workspace','propose_attendance_adjustment',
    'record_probation_review','reject_attendance_adjustment','review_onboarding_compensation',
    'review_onboarding_task','seed_payable_shift_records','set_cross_outlet_claims','set_entity_admin_self_approval',
    'stage_document_upload','test_workflow_rule','verify_payment_details'];
  v_guard text := E'\n  if auth.uid() is not null and public.my_role() is null then\n    raise exception using errcode = ''42501'', message = ''Not authorized: your access is not active'';\n  end if;';
  r record;
  v_def text;
  v_body_start int;
  v_begin int;
  v_new text;
  v_count int := 0;
begin
  for r in
    select p.oid, p.proname from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname = any (v_names)
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def ~* 'my_role\(\)\s+is\s+null' then
      continue;  -- already guarded
    end if;
    v_body_start := position('$function$' in v_def);
    -- the function's own BEGIN: first line that is exactly "begin" after the body starts
    v_begin := v_body_start + coalesce(nullif(position(E'\nbegin\n' in substr(v_def, v_body_start)), 0), -1);
    if v_body_start = 0 or v_begin < v_body_start then
      raise exception 'no top-level begin found in %', r.proname;
    end if;
    v_new := substr(v_def, 1, v_begin + length(E'\nbegin') - 1) || v_guard || substr(v_def, v_begin + length(E'\nbegin'));
    execute v_new;
    v_count := v_count + 1;
  end loop;
  if v_count < 40 then
    raise exception 'expected to guard at least 40 functions, guarded %', v_count;
  end if;
  raise notice 'guarded % functions', v_count;
end
$patch$;
