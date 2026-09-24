-- ============================================================
-- W2 Security & performance pass.
--  1. Draft payslips/deductions are no longer staff-visible: self
--     access requires the run to be approved or paid (published).
--  2. Self-decision guards (defence in depth, enforced in triggers so
--     every RPC path is covered): nobody but an owner may approve/
--     reject their own leave or documents (entity_admin self document
--     approval only when the explicit app setting allows it), or
--     correct their own attendance.
--  3. get_document_expiry_detail: entity_admin pinned to own entity.
--  4. Consolidate multiple permissive SELECT policies (perf advisor)
--     without changing who can see what.
--  5. Covering indexes for every unindexed foreign key.
--  6. EXECUTE sweep: no function in public is executable by anon or
--     PUBLIC; trigger functions are not executable by authenticated;
--     new functions default to no PUBLIC execute.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Published-payslip visibility
-- ------------------------------------------------------------
create or replace function public.is_payroll_run_published(p_payroll_run_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.payroll_runs pr
    where pr.id = p_payroll_run_id and pr.status in ('approved', 'paid')
  );
$$;

revoke all on function public.is_payroll_run_published(uuid) from public, anon;
grant execute on function public.is_payroll_run_published(uuid) to authenticated;

drop policy if exists payslips_select on public.payslips;
drop policy if exists payslips_select_self on public.payslips;
create policy payslips_select on public.payslips
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and exists (
    select 1 from public.payroll_runs pr
    where pr.id = payslips.payroll_run_id and pr.entity_id = (select public.my_entity())
  ))
  or (employee_id = (select public.my_employee_id()) and public.is_payroll_run_published(payroll_run_id))
);

drop policy if exists deductions_access on public.payslip_deductions;
drop policy if exists deductions_select_self on public.payslip_deductions;
create policy deductions_select on public.payslip_deductions
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and exists (
    select 1 from public.payroll_runs pr
    where pr.id = payslip_deductions.payroll_run_id and pr.entity_id = (select public.my_entity())
  ))
  or (employee_id = (select public.my_employee_id()) and public.is_payroll_run_published(payroll_run_id))
);

-- ------------------------------------------------------------
-- 2. Self-decision guards
-- ------------------------------------------------------------
create or replace function public.guard_leave_self_decision()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status in ('approved', 'rejected')
     and new.employee_id = public.my_employee_id()
     and public.my_role() is distinct from 'owner' then
    raise exception 'You cannot approve or reject your own leave request' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_leave_self_decision on public.leave_requests;
create trigger trg_guard_leave_self_decision
  before update of status on public.leave_requests
  for each row execute function public.guard_leave_self_decision();

create or replace function public.guard_document_self_decision()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.review_status = 'pending_review' and new.review_status in ('approved', 'rejected')
     and new.employee_id = public.my_employee_id()
     and public.my_role() is distinct from 'owner'
     and not (public.my_role() = 'entity_admin' and public.entity_admin_self_approval_enabled()) then
    raise exception 'You cannot approve or reject your own document' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_document_self_decision on public.employee_documents;
create trigger trg_guard_document_self_decision
  before update of review_status on public.employee_documents
  for each row execute function public.guard_document_self_decision();

create or replace function public.guard_attendance_self_correction()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.corrected_at is distinct from old.corrected_at
     and new.employee_id = public.my_employee_id()
     and public.my_role() is distinct from 'owner' then
    raise exception 'You cannot correct your own attendance record' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_attendance_self_correction on public.attendance_records;
create trigger trg_guard_attendance_self_correction
  before update on public.attendance_records
  for each row execute function public.guard_attendance_self_correction();

-- ------------------------------------------------------------
-- 3. get_document_expiry_detail entity scoping
-- ------------------------------------------------------------
create or replace function public.get_document_expiry_detail(p_entity_id uuid default null, p_bucket text default 'expiring_30_days')
returns table (employee_id uuid, employee_name text, doc_type public.document_type, expiry_date date)
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_entity uuid := coalesce(p_entity_id, public.my_entity());
  v_today date := (now() at time zone 'Asia/Dubai')::date;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if v_role = 'entity_admin' and v_entity is distinct from public.my_entity() then
    raise exception 'entity_admin can only view their own entity' using errcode = '42501';
  end if;
  return query
    select e.id, e.full_name, ed.doc_type, ed.expiry_date
    from public.employee_documents ed
    join public.employees e on e.id = ed.employee_id
    where e.entity_id = v_entity and ed.is_current = true
      and case p_bucket
        when 'expired' then ed.expiry_date < v_today
        when 'expiring_30_days' then ed.expiry_date >= v_today and ed.expiry_date <= v_today + 30
        else ed.expiry_date is null or ed.expiry_date > v_today + 30
      end
    order by ed.expiry_date nulls last;
end;
$$;

-- ------------------------------------------------------------
-- 4. Policy consolidation (one permissive policy per role/action)
-- ------------------------------------------------------------

-- attendance_records
drop policy if exists attendance_select_admin on public.attendance_records;
drop policy if exists attendance_select_self on public.attendance_records;
create policy attendance_select on public.attendance_records
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and location_id = (select public.my_location()))
  or employee_id = (select public.my_employee_id())
);

-- leave_balances
drop policy if exists leave_balances_select on public.leave_balances;
drop policy if exists leave_balances_select_self on public.leave_balances;
create policy leave_balances_select on public.leave_balances
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and exists (
    select 1 from public.employees e where e.id = leave_balances.employee_id and e.entity_id = (select public.my_entity())))
  or ((select public.my_role()) = 'location_manager'::public.user_role and exists (
    select 1 from public.employees e where e.id = leave_balances.employee_id and e.home_location_id = (select public.my_location())))
  or employee_id = (select public.my_employee_id())
);

-- leave_types (entity members, incl. staff, see their entity's catalogue)
drop policy if exists leave_types_select on public.leave_types;
drop policy if exists leave_types_select_self on public.leave_types;
create policy leave_types_select on public.leave_types
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or entity_id = (select public.my_entity())
);

-- shifts
drop policy if exists shifts_access on public.shifts;
drop policy if exists shifts_select_open_home_location on public.shifts;
drop policy if exists shifts_select_self on public.shifts;
create policy shifts_select on public.shifts
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and location_id = (select public.my_location()))
  or (employee_id = (select public.my_employee_id()) and is_published = true)
  or (status = 'open' and is_published = true and location_id = (select public.my_home_location()))
);
create policy shifts_insert on public.shifts
for insert
to authenticated
with check (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and location_id = (select public.my_location()))
);
create policy shifts_update on public.shifts
for update
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and location_id = (select public.my_location()))
)
with check (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and location_id = (select public.my_location()))
);
create policy shifts_delete on public.shifts
for delete
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and location_id = (select public.my_location()))
);

-- candidate_files
drop policy if exists candidate_files_admin_all on public.candidate_files;
drop policy if exists candidate_files_interviewer_select on public.candidate_files;
create policy candidate_files_select on public.candidate_files
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and exists (
    select 1 from public.candidates c where c.id = candidate_files.candidate_id and c.location_id = (select public.my_location())))
  or (visible_to_interviewers = true and public.interviewer_can_access_candidate_file(candidate_id))
);
create policy candidate_files_insert on public.candidate_files
for insert
to authenticated
with check (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and exists (
    select 1 from public.candidates c where c.id = candidate_files.candidate_id and c.location_id = (select public.my_location())))
);
create policy candidate_files_update on public.candidate_files
for update
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and exists (
    select 1 from public.candidates c where c.id = candidate_files.candidate_id and c.location_id = (select public.my_location())))
)
with check (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and exists (
    select 1 from public.candidates c where c.id = candidate_files.candidate_id and c.location_id = (select public.my_location())))
);
create policy candidate_files_delete on public.candidate_files
for delete
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and exists (
    select 1 from public.candidates c where c.id = candidate_files.candidate_id and c.location_id = (select public.my_location())))
);

-- interviews
drop policy if exists interviews_admin_all on public.interviews;
drop policy if exists interviews_interviewer_select on public.interviews;
create policy interviews_select on public.interviews
for select
to authenticated
using (
  exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        (select public.my_role()) = 'owner'::public.user_role
        or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity()))
        or ((select public.my_role()) = 'location_manager'::public.user_role and jr.location_id = (select public.my_location()))
      )
  )
  or (
    interviewer_id = (select auth.uid())
    and public.is_active_employee((select public.my_employee_id()))
    and public.requisition_entity_for_interview(id) = (select public.my_entity())
    and public.is_interview_within_visibility_window(scheduled_at, public.interview_feedback_status_for(id))
  )
);
create policy interviews_insert on public.interviews
for insert
to authenticated
with check (
  exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        (select public.my_role()) = 'owner'::public.user_role
        or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity()))
        or ((select public.my_role()) = 'location_manager'::public.user_role and jr.location_id = (select public.my_location()))
      )
  )
);
create policy interviews_update on public.interviews
for update
to authenticated
using (
  exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        (select public.my_role()) = 'owner'::public.user_role
        or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity()))
        or ((select public.my_role()) = 'location_manager'::public.user_role and jr.location_id = (select public.my_location()))
      )
  )
)
with check (
  exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        (select public.my_role()) = 'owner'::public.user_role
        or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity()))
        or ((select public.my_role()) = 'location_manager'::public.user_role and jr.location_id = (select public.my_location()))
      )
  )
);
create policy interviews_delete on public.interviews
for delete
to authenticated
using (
  exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        (select public.my_role()) = 'owner'::public.user_role
        or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity()))
        or ((select public.my_role()) = 'location_manager'::public.user_role and jr.location_id = (select public.my_location()))
      )
  )
);

-- interview_feedback
drop policy if exists interview_feedback_owner_admin_all on public.interview_feedback;
drop policy if exists interview_feedback_interviewer_select on public.interview_feedback;
drop policy if exists interview_feedback_location_manager_revealed_select on public.interview_feedback;
create policy interview_feedback_select on public.interview_feedback
for select
to authenticated
using (
  exists (
    select 1 from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = interview_feedback.interview_id
      and (
        (select public.my_role()) = 'owner'::public.user_role
        or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity()))
        or (interview_feedback.status = 'submitted'
            and (select public.my_role()) = 'location_manager'::public.user_role
            and jr.location_id = (select public.my_location())
            and public.is_interview_round_revealed(ja.id, iv.stage_id))
      )
  )
  or (
    submitted_by = (select auth.uid())
    and (select public.is_active_user())
    and exists (
      select 1 from public.interviews iv2
      where iv2.id = interview_feedback.interview_id and iv2.interviewer_id = (select auth.uid())
    )
  )
);
create policy interview_feedback_insert on public.interview_feedback
for insert
to authenticated
with check (
  exists (
    select 1 from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = interview_feedback.interview_id
      and ((select public.my_role()) = 'owner'::public.user_role
           or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity())))
  )
);
create policy interview_feedback_update on public.interview_feedback
for update
to authenticated
using (
  exists (
    select 1 from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = interview_feedback.interview_id
      and ((select public.my_role()) = 'owner'::public.user_role
           or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity())))
  )
)
with check (
  exists (
    select 1 from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = interview_feedback.interview_id
      and ((select public.my_role()) = 'owner'::public.user_role
           or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity())))
  )
);
create policy interview_feedback_delete on public.interview_feedback
for delete
to authenticated
using (
  exists (
    select 1 from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = interview_feedback.interview_id
      and ((select public.my_role()) = 'owner'::public.user_role
           or ((select public.my_role()) = 'entity_admin'::public.user_role and jr.entity_id = (select public.my_entity())))
  )
);

-- ------------------------------------------------------------
-- 5. Covering indexes for foreign keys
-- ------------------------------------------------------------
create index if not exists schedule_templates_created_by_fk_idx on public.schedule_templates (created_by);
create index if not exists employee_documents_submitted_by_fk_idx on public.employee_documents (submitted_by);
create index if not exists employee_documents_reviewed_by_fk_idx on public.employee_documents (reviewed_by);
create index if not exists employee_documents_archived_by_fk_idx on public.employee_documents (archived_by);
create index if not exists app_settings_updated_by_fk_idx on public.app_settings (updated_by);
create index if not exists leave_accrual_policies_entity_id_fk_idx on public.leave_accrual_policies (entity_id);
create index if not exists interviews_cancelled_by_fk_idx on public.interviews (cancelled_by);
create index if not exists interview_feedback_submitted_by_fk_idx on public.interview_feedback (submitted_by);
create index if not exists interview_feedback_reopened_by_fk_idx on public.interview_feedback (reopened_by);
create index if not exists candidate_files_entity_id_fk_idx on public.candidate_files (entity_id);
create index if not exists candidate_files_uploaded_by_fk_idx on public.candidate_files (uploaded_by);
create index if not exists schedule_templates_entity_id_fk_idx on public.schedule_templates (entity_id);
create index if not exists schedule_templates_position_id_fk_idx on public.schedule_templates (position_id);
create index if not exists schedule_templates_supersedes_template_id_fk_idx on public.schedule_templates (supersedes_template_id);
create index if not exists attendance_records_entity_id_fk_idx on public.attendance_records (entity_id);
create index if not exists attendance_records_corrected_by_fk_idx on public.attendance_records (corrected_by);
create index if not exists leave_requests_cancelled_by_fk_idx on public.leave_requests (cancelled_by);
create index if not exists leave_accrual_policies_approved_by_fk_idx on public.leave_accrual_policies (approved_by);
create index if not exists leave_accrual_policies_created_by_fk_idx on public.leave_accrual_policies (created_by);
create index if not exists leave_accrual_runs_policy_id_fk_idx on public.leave_accrual_runs (policy_id);
create index if not exists leave_accrual_runs_leave_type_id_fk_idx on public.leave_accrual_runs (leave_type_id);
create index if not exists leave_accrual_runs_created_by_fk_idx on public.leave_accrual_runs (created_by);
create index if not exists interview_round_closures_stage_id_fk_idx on public.interview_round_closures (stage_id);
create index if not exists payable_shift_records_employee_id_fk_idx on public.payable_shift_records (employee_id);
create index if not exists payable_shift_records_entity_id_fk_idx on public.payable_shift_records (entity_id);
create index if not exists attendance_adjustments_actor_id_fk_idx on public.attendance_adjustments (actor_id);
create index if not exists attendance_adjustments_decided_by_fk_idx on public.attendance_adjustments (decided_by);
create index if not exists timesheet_entry_sources_payable_shift_record_id_fk_idx on public.timesheet_entry_sources (payable_shift_record_id);
create index if not exists workflow_runs_entity_id_fk_idx on public.workflow_runs (entity_id);
create index if not exists workflow_rules_supersedes_rule_id_fk_idx on public.workflow_rules (supersedes_rule_id);
create index if not exists workflow_rules_created_by_fk_idx on public.workflow_rules (created_by);
create index if not exists data_retention_policies_approved_by_fk_idx on public.data_retention_policies (approved_by);
create index if not exists data_retention_policies_created_by_fk_idx on public.data_retention_policies (created_by);

-- ------------------------------------------------------------
-- 6. EXECUTE sweep
-- ------------------------------------------------------------
do $sweep$
declare
  f record;
begin
  for f in
    select p.oid, p.oid::regprocedure::text as sig,
           pg_get_function_result(p.oid) = 'trigger' as is_trigger,
           has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  loop
    if f.is_trigger then
      execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    else
      if f.auth_can then
        -- keep authenticated access explicit before dropping the PUBLIC grant
        execute format('grant execute on function %s to authenticated', f.sig);
      end if;
      execute format('revoke all on function %s from public, anon', f.sig);
    end if;
  end loop;
end
$sweep$;

alter default privileges for role postgres in schema public revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke execute on functions from anon;
