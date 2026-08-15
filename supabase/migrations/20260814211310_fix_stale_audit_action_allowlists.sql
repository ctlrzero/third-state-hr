
-- Final verification pass caught a real cross-phase regression: the
-- location_manager/staff curated action allow-lists inside get_audit_log()
-- were written before Phase 2.10 (document upload staging) and Phase 2.9
-- (leave self-cancel), and were never updated when those phases renamed/
-- added action literals. Concretely:
--   - 'document_uploaded' has not been inserted by any function since Phase
--     2.10's staging rework — the real actions are now 'document_upload_staged'
--     (stage_document_upload/stage_document_renewal's staged path) and
--     'document_upload_confirmed' (confirm_document_upload). Result: every
--     location_manager and staff member has seen exactly zero upload-related
--     audit events since that phase shipped, silently.
--   - 'renewal_submitted' was never a real action either — stage_document_renewal
--     inserts 'renewal_staged'. Same silent-zero-results bug for staff.
--   - 'leave_cancelled' (Phase 2.9's self-cancel RPC) didn't exist yet when
--     these lists were written, so neither role could see their own/their
--     team's leave cancellations even though the equivalent submit/approve/
--     reject events are already visible.
-- This confirms none of these were ever a data leak (the opposite failure
-- mode — under-visibility, not over-visibility — which is why the earlier
-- per-phase security sweeps didn't flag it, they were checking for excess
-- access, not missing access) but it is a real functional regression, fixed
-- here as part of the final cross-phase verification pass.
create or replace function public.get_audit_log(
  p_limit integer default 100,
  p_before timestamptz default null,
  p_table_name text default null,
  p_action text default null,
  p_after timestamptz default null,
  p_module text default null,
  p_actor_id uuid default null,
  p_entity_id uuid default null,
  p_location_id uuid default null,
  p_employee_id uuid default null
)
returns table(id uuid, table_name text, record_id uuid, changed_by uuid, changed_at timestamptz, action text, old_value jsonb, new_value jsonb, entity_id uuid, location_id uuid, employee_id uuid)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_role user_role := my_role();
  v_module_tables text[];
  v_location_manager_actions text[] := array[
    'shift_claimed', 'swap_requested', 'swap_claimed', 'swap_cancelled',
    'interview_cancelled', 'interview_rescheduled',
    'document_upload_staged', 'document_upload_confirmed', 'document_approved', 'document_rejected', 'document_archived',
    'payroll_change_succeeded', 'payroll_change_rejected',
    'leave_request_submitted', 'leave_request_updated', 'leave_approved', 'leave_rejected', 'leave_cancelled', 'leave_balance_used'
  ];
  v_employee_actions text[] := array[
    'document_upload_staged', 'document_upload_confirmed', 'document_approved', 'document_rejected', 'document_archived',
    'renewal_staged', 'preview', 'download',
    'shift_claimed', 'swap_requested', 'swap_claimed', 'swap_cancelled',
    'leave_request_submitted', 'leave_approved', 'leave_rejected', 'leave_cancelled', 'leave_balance_used'
  ];
begin
  if p_limit is null or p_limit <= 0 or p_limit > 500 then
    p_limit := 100;
  end if;

  if p_module is not null then
    v_module_tables := case p_module
      when 'employees' then array['employees']
      when 'documents' then array['employee_documents', 'candidate_files']
      when 'recruiting' then array['interviews', 'interview_feedback', 'interview_round_closures', 'offers']
      when 'scheduling' then array['shifts', 'shift_swap_requests', 'schedule_templates', 'attendance_records', 'timesheet_entries']
      when 'leave' then array['leave_requests', 'leave_balances', 'leave_accrual_policies']
      when 'payroll' then array['payroll_runs', 'payslips', 'payslip_deductions', 'tips_pools']
      when 'settings' then array['app_settings']
      else null
    end;
    if v_module_tables is null then
      raise exception 'Unknown module: %', p_module;
    end if;
  end if;

  if v_role = 'owner' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id, a.location_id, a.employee_id
      from audit_log a
      where (p_before is null or a.changed_at < p_before)
        and (p_after is null or a.changed_at >= p_after)
        and (p_table_name is null or a.table_name = p_table_name)
        and (v_module_tables is null or a.table_name = any(v_module_tables))
        and (p_action is null or a.action = p_action)
        and (p_actor_id is null or a.changed_by = p_actor_id)
        and (p_entity_id is null or a.entity_id = p_entity_id)
        and (p_location_id is null or a.location_id = p_location_id)
        and (p_employee_id is null or a.employee_id = p_employee_id)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  if v_role = 'entity_admin' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id, a.location_id, a.employee_id
      from audit_log a
      where a.entity_id = my_entity()
        and (p_before is null or a.changed_at < p_before)
        and (p_after is null or a.changed_at >= p_after)
        and (p_table_name is null or a.table_name = p_table_name)
        and (v_module_tables is null or a.table_name = any(v_module_tables))
        and (p_action is null or a.action = p_action)
        and (p_actor_id is null or a.changed_by = p_actor_id)
        and (p_entity_id is null or a.entity_id = p_entity_id)
        and (p_location_id is null or a.location_id = p_location_id)
        and (p_employee_id is null or a.employee_id = p_employee_id)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  if v_role = 'location_manager' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id, a.location_id, a.employee_id
      from audit_log a
      where a.location_id = my_location()
        and a.action = any(v_location_manager_actions)
        and (p_before is null or a.changed_at < p_before)
        and (p_after is null or a.changed_at >= p_after)
        and (p_table_name is null or a.table_name = p_table_name)
        and (v_module_tables is null or a.table_name = any(v_module_tables))
        and (p_action is null or a.action = p_action)
        and (p_actor_id is null or a.changed_by = p_actor_id)
        and (p_entity_id is null or a.entity_id = p_entity_id)
        and (p_location_id is null or a.location_id = p_location_id)
        and (p_employee_id is null or a.employee_id = p_employee_id)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  if v_role = 'staff' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id, a.location_id, a.employee_id
      from audit_log a
      where a.employee_id = my_employee_id()
        and a.action = any(v_employee_actions)
        and (p_before is null or a.changed_at < p_before)
        and (p_after is null or a.changed_at >= p_after)
        and (p_table_name is null or a.table_name = p_table_name)
        and (v_module_tables is null or a.table_name = any(v_module_tables))
        and (p_action is null or a.action = p_action)
        and (p_actor_id is null or a.changed_by = p_actor_id)
        and (p_entity_id is null or a.entity_id = p_entity_id)
        and (p_location_id is null or a.location_id = p_location_id)
        and (p_employee_id is null or a.employee_id = p_employee_id)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  return;
end;
$function$;

revoke all on function public.get_audit_log(integer, timestamptz, text, text, timestamptz, text, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.get_audit_log(integer, timestamptz, text, text, timestamptz, text, uuid, uuid, uuid, uuid) to authenticated;

-- export_audit_log() itself has no action allow-list (owner/entity_admin
-- only, unrestricted by action within their own scope), so it was never
-- affected by this drift — no change needed there.
;
