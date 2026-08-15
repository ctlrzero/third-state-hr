
-- get_audit_log()'s entity_admin branch had no resolution path for timesheet_entries,
-- tips_pools, or payslip_deductions (only payroll_runs/payslips were in the join list),
-- so the new payroll_change_blocked_locked_run / *_payroll_input audit rows written by
-- enforce_payroll_child_immutability() were silently invisible to entity admins even for
-- their own entity's runs -- failing closed too aggressively. Extend the join list with
-- these three child tables, resolved back to payroll_runs.entity_id. This is a stopgap
-- inside the existing hand-maintained-join architecture; Phase 1.2 replaces the whole
-- mechanism with a direct audit_log.entity_id column and removes this join list entirely.
create or replace function public.get_audit_log(
  p_limit int default 100,
  p_before timestamptz default null,
  p_table_name text default null,
  p_action text default null
)
returns table(id uuid, table_name text, record_id uuid, changed_by uuid, changed_at timestamptz, action text, old_value jsonb, new_value jsonb)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
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
    return;
  end if;

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
    left join timesheet_entries te on a.table_name = 'timesheet_entries' and te.id = a.record_id
    left join payroll_runs te_pr on te_pr.id = te.payroll_run_id
    left join tips_pools tp on a.table_name = 'tips_pools' and tp.id = a.record_id
    left join payroll_runs tp_pr on tp_pr.id = tp.payroll_run_id
    left join payslip_deductions pd on a.table_name = 'payslip_deductions' and pd.id = a.record_id
    left join payroll_runs pd_pr on pd_pr.id = pd.payroll_run_id
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
        te_pr.entity_id,
        tp_pr.entity_id,
        pd_pr.entity_id,
        cf_cand.entity_id
      )
    order by a.changed_at desc
    limit p_limit;
end;
$$;

revoke all on function public.get_audit_log(int, timestamptz, text, text) from public, anon;
grant execute on function public.get_audit_log(int, timestamptz, text, text) to authenticated;

