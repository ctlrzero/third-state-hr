
create or replace function public.get_audit_log(
  p_limit int default 100,
  p_before timestamptz default null,
  p_table_name text default null,
  p_action text default null
)
returns table(id uuid, table_name text, record_id uuid, changed_by uuid, changed_at timestamptz, action text, old_value jsonb, new_value jsonb, entity_id uuid)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_role user_role := my_role();
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

  if v_role = 'owner' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id
      from audit_log a
      where (p_before is null or a.changed_at < p_before)
        and (p_table_name is null or a.table_name = p_table_name)
        and (p_action is null or a.action = p_action)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  if v_role = 'entity_admin' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id
      from audit_log a
      where a.entity_id = my_entity()
        and (p_before is null or a.changed_at < p_before)
        and (p_table_name is null or a.table_name = p_table_name)
        and (p_action is null or a.action = p_action)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  if v_role = 'location_manager' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id
      from audit_log a
      where a.location_id = my_location()
        and a.action = any(v_location_manager_actions)
        and (p_before is null or a.changed_at < p_before)
        and (p_table_name is null or a.table_name = p_table_name)
        and (p_action is null or a.action = p_action)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  if v_role = 'staff' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value, a.entity_id
      from audit_log a
      where a.employee_id = my_employee_id()
        and a.action = any(v_employee_actions)
        and (p_before is null or a.changed_at < p_before)
        and (p_table_name is null or a.table_name = p_table_name)
        and (p_action is null or a.action = p_action)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  return;
end;
$$;

revoke all on function public.get_audit_log(int, timestamptz, text, text) from public, anon;
grant execute on function public.get_audit_log(int, timestamptz, text, text) to authenticated;

