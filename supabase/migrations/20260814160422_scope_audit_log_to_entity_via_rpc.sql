
-- audit_select previously granted ANY entity_admin unscoped read access to
-- every entity's audit_log rows (audit_log has no entity_id column, and the
-- policy only checked role, never entity match). Tighten direct table
-- access to owner-only, and expose a curated, entity-scoped read via a
-- SECURITY DEFINER RPC for entity_admin, mirroring the get_my_interviews()
-- pattern used elsewhere in this app. location_manager continues to have
-- no audit log access at all (unchanged from before).

drop policy if exists audit_select on public.audit_log;

create policy audit_select on public.audit_log
  for select
  to authenticated
  using (my_role() = 'owner');

create or replace function public.get_audit_log(
  p_limit int default 100,
  p_before timestamptz default null,
  p_table_name text default null,
  p_action text default null
)
returns table (
  id uuid,
  table_name text,
  record_id uuid,
  changed_by uuid,
  changed_at timestamptz,
  action text,
  old_value jsonb,
  new_value jsonb
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if p_limit is null or p_limit <= 0 or p_limit > 500 then
    p_limit := 100;
  end if;

  if my_role() = 'owner' then
    return query
      select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value
      from audit_log a
      where (p_before is null or a.changed_at < p_before)
        and (p_table_name is null or a.table_name = p_table_name)
        and (p_action is null or a.action = p_action)
      order by a.changed_at desc
      limit p_limit;
    return;
  end if;

  if my_role() <> 'entity_admin' then
    -- location_manager and staff get an empty result, not an error — same
    -- "no access" shape as querying a table with no matching rows, never a
    -- signal that audit_log exists but is off-limits.
    return;
  end if;

  -- entity_admin: resolve each row's owning entity via the same joins the
  -- writing RPCs used, and only return rows that resolve to the caller's
  -- own entity. A table_name this function doesn't know how to resolve
  -- (e.g. app_settings, which isn't entity-scoped) is excluded entirely —
  -- fail closed, never leak an unresolvable row.
  return query
    select a.id, a.table_name, a.record_id, a.changed_by, a.changed_at, a.action, a.old_value, a.new_value
    from audit_log a
    left join employee_documents ed on a.table_name = 'employee_documents' and ed.id = a.record_id
    left join employees ed_emp on ed_emp.id = ed.employee_id
    left join employees emp on a.table_name = 'employees' and emp.id = a.record_id
    left join shifts sh on a.table_name = 'shifts' and sh.id = a.record_id
    left join shift_swap_requests ssr on a.table_name = 'shift_swap_requests' and ssr.id = a.record_id
    left join shifts ssr_shift on ssr_shift.id = ssr.shift_id
    left join interviews iv on a.table_name = 'interviews' and iv.id = a.record_id
    left join interview_feedback ifb on a.table_name = 'interview_feedback' and ifb.id = a.record_id
    left join interviews ifb_iv on ifb_iv.id = ifb.interview_id
    left join job_applications iv_ja on iv_ja.id = coalesce(iv.application_id, ifb_iv.application_id)
    left join job_requisitions iv_jr on iv_jr.id = iv_ja.requisition_id
    left join offers off on a.table_name = 'offers' and off.id = a.record_id
    left join job_applications off_ja on off_ja.id = off.application_id
    left join job_requisitions off_jr on off_jr.id = off_ja.requisition_id
    left join payroll_runs pr on a.table_name in ('payroll_runs', 'payslips') and pr.id = a.record_id
    left join candidate_files cf on a.table_name = 'candidate_files' and cf.id = a.record_id
    left join candidates cf_cand on cf_cand.id = cf.candidate_id
    where (p_before is null or a.changed_at < p_before)
      and (p_table_name is null or a.table_name = p_table_name)
      and (p_action is null or a.action = p_action)
      and my_entity() = coalesce(
        ed_emp.entity_id,
        emp.entity_id,
        sh.entity_id,
        ssr_shift.entity_id,
        iv_jr.entity_id,
        off_jr.entity_id,
        pr.entity_id,
        cf_cand.entity_id
      )
    order by a.changed_at desc
    limit p_limit;
end;
$function$;

revoke all on function public.get_audit_log(int, timestamptz, text, text) from public, anon;
grant execute on function public.get_audit_log(int, timestamptz, text, text) to authenticated;
