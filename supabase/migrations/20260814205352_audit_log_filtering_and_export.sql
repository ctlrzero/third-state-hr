
-- Phase 3.13: audit filtering and export. get_audit_log() already had
-- role-based scoping (owner/entity_admin/location_manager/staff) and a
-- changed_at cursor for infinite-scroll pagination from Phase 1.2/1.4; this
-- adds the remaining filters (date range start, actor, module, entity,
-- branch, employee) as trailing optional params — fully backward compatible
-- with the existing call in Reports.tsx, which only ever passed the original
-- four. "Module" groups the table_name values actually written by existing
-- RPCs today (confirmed live, not guessed) into the same categories the app
-- already uses elsewhere (Documents, Recruiting, Scheduling, Leave, Payroll,
-- Settings, Employees) — an unrecognized module name raises rather than
-- silently matching nothing or everything.
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
    'document_uploaded', 'document_approved', 'document_rejected', 'document_archived',
    'payroll_change_succeeded', 'payroll_change_rejected',
    'leave_request_submitted', 'leave_request_updated', 'leave_approved', 'leave_rejected', 'leave_balance_used'
  ];
  v_employee_actions text[] := array[
    'document_uploaded', 'document_approved', 'document_rejected', 'document_archived',
    'renewal_submitted', 'preview', 'download',
    'shift_claimed', 'swap_requested', 'swap_claimed', 'swap_cancelled',
    'leave_request_submitted', 'leave_approved', 'leave_rejected', 'leave_balance_used'
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

-- CSV export is a heavier capability than on-screen paging (bulk extraction
-- of potentially sensitive change history), so it's restricted to owner/
-- entity_admin even though location_manager/staff can view a curated slice
-- via get_audit_log(). Same filters, same scoping logic, no pagination —
-- capped at 5000 rows (the frontend treats hitting exactly 5000 as a signal
-- to narrow the date range, same heuristic Reports.tsx already uses for
-- "hasMore" on the paged view). The export itself is audited: every call
-- writes its own 'audit_log_exported' row recording who exported, how many
-- rows, and the exact filters used — so bulk extraction of the audit trail
-- is itself part of the audit trail.
create or replace function public.export_audit_log(
  p_after timestamptz default null,
  p_before timestamptz default null,
  p_table_name text default null,
  p_module text default null,
  p_action text default null,
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
  v_row_count int := 0;
  v_entity_for_log uuid;
begin
  if not (v_role = 'owner' or v_role = 'entity_admin') then
    raise exception 'Only an Owner or Entity Admin may export the audit log';
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

  v_entity_for_log := case when v_role = 'entity_admin' then my_entity() else coalesce(p_entity_id, my_entity()) end;

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
        and (p_location_id is null or a.location_id = p_location_id)
        and (p_employee_id is null or a.employee_id = p_employee_id)
      order by a.changed_at desc
      limit 5000;
  else
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
      limit 5000;
  end if;
  get diagnostics v_row_count = row_count;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values (
    'audit_log', auth.uid(), auth.uid(), 'audit_log_exported',
    jsonb_build_object(
      'row_count', v_row_count,
      'filters', jsonb_build_object(
        'after', p_after, 'before', p_before, 'table_name', p_table_name, 'module', p_module,
        'action', p_action, 'actor_id', p_actor_id, 'entity_id', p_entity_id,
        'location_id', p_location_id, 'employee_id', p_employee_id
      )
    ),
    v_entity_for_log, null
  );
end;
$function$;

revoke all on function public.export_audit_log(timestamptz, timestamptz, text, text, text, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.export_audit_log(timestamptz, timestamptz, text, text, text, uuid, uuid, uuid, uuid) to authenticated;

