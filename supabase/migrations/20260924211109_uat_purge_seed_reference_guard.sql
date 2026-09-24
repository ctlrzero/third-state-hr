-- ============================================================
-- uat_purge_seed(): abort with a clear report (and delete nothing) when
-- rows outside UAT Entity A/B still reference a uat.* user (found in the
-- rolled-back dry run: a real-entity job requisition created by
-- uat.owner). Real data is never modified automatically.
-- ============================================================

create or replace function public.uat_purge_seed()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_ents constant uuid[] := array['a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002']::uuid[];
  v_users uuid[];
  v_emps uuid[];
  v_locs uuid[];
  v_reqs uuid[];
  v_counts jsonb := '{}'::jsonb;
  v_n integer;
  fk record;
  v_blockers text[] := '{}';
begin
  if session_user not in ('postgres', 'supabase_admin') then
    raise exception 'uat_purge_seed may only be run by postgres' using errcode = '42501';
  end if;
  if exists (select 1 from public.entities where id = any(c_ents) and name not in ('UAT Entity A', 'UAT Entity B')) then
    raise exception 'UAT entity ids do not carry UAT names; refusing to purge';
  end if;

  select coalesce(array_agg(id), '{}') into v_users from auth.users where email like 'uat.%@example.com';
  select coalesce(array_agg(id), '{}') into v_emps from public.employees where entity_id = any(c_ents);
  select coalesce(array_agg(id), '{}') into v_locs from public.locations where entity_id = any(c_ents);
  select coalesce(array_agg(id), '{}') into v_reqs from public.job_requisitions where entity_id = any(c_ents);

  if exists (select 1 from public.employees where auth_user_id = any(v_users) and not (entity_id = any(c_ents))) then
    raise exception 'A real-entity employee is linked to a uat.* user; resolve manually before purging';
  end if;
  if exists (select 1 from public.profiles where id = any(v_users) and entity_id is not null and not (entity_id = any(c_ents))) then
    raise exception 'A uat.* profile is scoped to a real entity; resolve manually before purging';
  end if;

  perform set_config('tshr.uat_maintenance', 'on', true);

  delete from public.access_grants where entity_id = any(c_ents) or email like 'uat.%@example.com';
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('access_grants', v_n);
  delete from public.notifications where entity_id = any(c_ents) or recipient_user_id = any(v_users) or employee_id = any(v_emps);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('notifications', v_n);
  delete from public.workflow_runs where entity_id = any(c_ents);
  delete from public.workflow_rules where entity_id = any(c_ents);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('workflow_rules', v_n);

  delete from public.payroll_runs where entity_id = any(c_ents);     -- cascades payslips, deductions, timesheets, tips
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('payroll_runs', v_n);
  delete from public.payable_shift_records where entity_id = any(c_ents);  -- cascades attendance_adjustments
  delete from public.attendance_records where entity_id = any(c_ents);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('attendance_records', v_n);
  delete from public.shifts where entity_id = any(c_ents);           -- cascades swap requests
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('shifts', v_n);
  delete from public.schedule_templates where entity_id = any(c_ents);

  delete from public.leave_accrual_runs where employee_id = any(v_emps);
  delete from public.leave_requests where employee_id = any(v_emps);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('leave_requests', v_n);
  delete from public.leave_accrual_policies where entity_id = any(c_ents);

  delete from public.interview_feedback f using public.interviews i, public.job_applications a
   where f.interview_id = i.id and i.application_id = a.id and a.requisition_id = any(v_reqs);
  delete from public.interviews i using public.job_applications a
   where i.application_id = a.id and a.requisition_id = any(v_reqs);
  delete from public.offers o using public.job_applications a
   where o.application_id = a.id and a.requisition_id = any(v_reqs);
  delete from public.job_applications where requisition_id = any(v_reqs);
  delete from public.interview_stages where requisition_id = any(v_reqs);
  delete from public.job_requisitions where id = any(v_reqs);
  delete from public.candidate_files where entity_id = any(c_ents);
  delete from public.candidates where entity_id = any(c_ents);

  delete from public.employee_documents where employee_id = any(v_emps);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('employee_documents', v_n);
  delete from public.data_retention_policies where entity_id = any(c_ents);

  delete from public.audit_log
   where entity_id = any(c_ents) or employee_id = any(v_emps) or location_id = any(v_locs);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('audit_log', v_n);
  update public.audit_log a
     set changed_by = null,
         new_value = coalesce(a.new_value, '{}'::jsonb)
                     || jsonb_build_object('purged_uat_actor', (select u.email from auth.users u where u.id = a.changed_by))
   where a.changed_by = any(v_users);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('audit_log_actor_nulled', v_n);

  update public.app_settings set updated_by = null where updated_by = any(v_users);
  delete from public.attendance_adjustments where actor_id = any(v_users) or decided_by = any(v_users);

  delete from public.employees where id = any(v_emps);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('employees', v_n);
  delete from public.profiles where id = any(v_users);
  delete from public.positions where entity_id = any(c_ents);
  delete from public.leave_types where entity_id = any(c_ents);
  delete from public.locations where entity_id = any(c_ents);
  delete from public.entities where id = any(c_ents);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('entities', v_n);

  -- Any row still pointing at a uat.* user now lives OUTSIDE the UAT
  -- entities (real data). Never touch it automatically: abort (the whole
  -- purge rolls back) and report where the references are.
  for fk in
    select c.conrelid::regclass as tbl, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.confrelid = 'auth.users'::regclass
       and c.connamespace = 'public'::regnamespace
       and c.confdeltype not in ('c', 'n', 'd')   -- cascade / set null / set default resolve themselves
  loop
    execute format('select count(*) from %s where %I = any($1)', fk.tbl, fk.col) into v_n using v_users;
    if v_n > 0 then
      v_blockers := v_blockers || format('%s.%s (%s row(s))', fk.tbl, fk.col, v_n);
    end if;
  end loop;
  if cardinality(v_blockers) > 0 then
    raise exception 'uat_purge_seed aborted, nothing deleted: real (non-UAT) rows still reference uat.* users: %. Reassign or clear those references first.',
      array_to_string(v_blockers, ', ');
  end if;

  delete from auth.users where id = any(v_users);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('auth_users', v_n);

  perform set_config('tshr.uat_maintenance', '', true);
  return v_counts;
end;
$$;
revoke all on function public.uat_purge_seed() from public, anon, authenticated;
