-- Remediation (UAT Decision 1): export_audit_log crashed for Owner exports
-- with no p_entity_id, because v_entity_for_log resolved to NULL (owners
-- have no single entity_id) and violated audit_log_entity_id_required_check.
--
-- Fix, per explicit direction:
--   - Never relax audit_log_entity_id_required_check.
--   - Never insert entity_id = NULL.
--   - Never invent a sentinel/global entity.
--   - Resolve the full authorized entity scope server-side (never trust
--     client-supplied entity_id as the sole source of truth).
--   - For an Owner export with no entity filter, log one
--     'audit_log_exported' row PER entity in scope, each with its own real
--     entity_id and its own entity-specific row count, all sharing one
--     export_id for correlation.
--   - For an explicit single-entity export (Owner with p_entity_id, or
--     Entity Admin always), log exactly one row for that entity.
--   - Materialize the full result set BEFORE inserting any logging rows,
--     so the logging event(s) this call creates can never appear inside
--     its own exported result.
--   - Log metadata only (export_id, filters, timestamp, total + per-entity
--     row counts) -- never exported row contents, document/feedback/payroll
--     content.
--   - Empty-result exports still log one attempted-export row per
--     authorized entity (0 count), never silently skip logging.

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
returns table(
  id uuid, table_name text, record_id uuid, changed_by uuid, changed_at timestamptz,
  action text, old_value jsonb, new_value jsonb, entity_id uuid, location_id uuid, employee_id uuid
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_role          user_role := my_role();
  v_module_tables text[];
  v_export_id     uuid := gen_random_uuid();
  v_export_ts     timestamptz := now();
  v_rows          audit_log[];
  v_total_count   int;
  v_entity_scope  uuid[];
  v_entity        uuid;
  v_entity_count  int;
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

  -- Resolve the authorized entity scope server-side.
  if v_role = 'entity_admin' then
    -- Forced to exactly their own entity, regardless of client input.
    v_entity_scope := array[my_entity()];
  elsif p_entity_id is not null then
    -- Owner, explicit single-entity export.
    v_entity_scope := array[p_entity_id];
  else
    -- Owner, no entity filter: authorized scope is every entity that
    -- exists. Resolved from `entities`, not from audit_log contents, so an
    -- entity with zero matching rows this export still gets logged below.
    select array_agg(id) into v_entity_scope from entities;
  end if;

  -- Materialize the full filtered result set BEFORE any audit_log insert,
  -- so this call's own logging rows can never appear in its own output.
  select array_agg(a) into v_rows
  from (
    select a.*
    from audit_log a
    where a.entity_id = any(v_entity_scope)
      and (p_before is null or a.changed_at < p_before)
      and (p_after is null or a.changed_at >= p_after)
      and (p_table_name is null or a.table_name = p_table_name)
      and (v_module_tables is null or a.table_name = any(v_module_tables))
      and (p_action is null or a.action = p_action)
      and (p_actor_id is null or a.changed_by = p_actor_id)
      and (p_location_id is null or a.location_id = p_location_id)
      and (p_employee_id is null or a.employee_id = p_employee_id)
    order by a.changed_at desc
    limit 5000
  ) a;

  v_total_count := coalesce(array_length(v_rows, 1), 0);

  -- Return the materialized rows (unnest of an empty/null array yields
  -- zero rows -- a clean empty export, per requirement 12).
  return query select (r).* from unnest(v_rows) r;

  -- Log the export: one row per entity in the authorized scope, every row
  -- carrying a real, non-null entity_id, all sharing v_export_id.
  foreach v_entity in array coalesce(v_entity_scope, array[]::uuid[]) loop
    select count(*) into v_entity_count from unnest(v_rows) r where (r).entity_id = v_entity;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
    values (
      'audit_log', auth.uid(), auth.uid(), 'audit_log_exported',
      jsonb_build_object(
        'export_id', v_export_id,
        'exported_at', v_export_ts,
        'total_row_count', v_total_count,
        'entity_row_count', v_entity_count,
        'filters', jsonb_build_object(
          'after', p_after, 'before', p_before, 'table_name', p_table_name, 'module', p_module,
          'action', p_action, 'actor_id', p_actor_id, 'entity_id', p_entity_id,
          'location_id', p_location_id, 'employee_id', p_employee_id
        )
      ),
      v_entity, null
    );
  end loop;
end;
$function$;

revoke all on function public.export_audit_log(timestamptz, timestamptz, text, text, text, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.export_audit_log(timestamptz, timestamptz, text, text, text, uuid, uuid, uuid, uuid) to authenticated;
