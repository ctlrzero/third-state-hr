-- Integration fixes (phase 1 completion)
-- 1) data_retention_policies: owner (entity_id NULL on profile) read nothing because the
--    policy required entity_id = my_entity(). Owner now reads all entities, entity_admin
--    reads own entity, every other role reads nothing. Writes stay RPC-only
--    (propose_data_retention_policy / approve_data_retention_policy).
drop policy if exists data_retention_policies_select on public.data_retention_policies;
create policy data_retention_policies_select on public.data_retention_policies
  for select to authenticated
  using (
    (select public.my_role()) = 'owner'::public.user_role
    or ((select public.my_role()) = 'entity_admin'::public.user_role
        and entity_id = (select public.my_entity()))
  );

-- 2) get_payroll_payslip: owner / entity_admin (own entity) read of ONE payslip in the
--    same shape as get_my_payslip, so the payroll run screen PDF uses real version,
--    position, branch and compensation data. Any run status (a draft is labelled by
--    run_status). Every read is audited as payslip_viewed.
create or replace function public.get_payroll_payslip(p_payslip_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_role public.user_role := public.my_role();
  v_ps public.payslips;
  v_run public.payroll_runs;
  v_result jsonb;
begin
  if not public.is_active_user() or v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'You do not have permission to view this payslip' using errcode = '42501';
  end if;
  select * into v_ps from public.payslips where id = p_payslip_id;
  select * into v_run from public.payroll_runs where id = v_ps.payroll_run_id;
  if v_ps.id is null or (v_role = 'entity_admin' and v_run.entity_id is distinct from public.my_entity()) then
    raise exception 'Payslip not found' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'payslip_id', v_ps.id,
    'payroll_run_id', v_run.id,
    'version', public._payroll_run_version(v_run.id),
    'is_revision', v_run.revises_payroll_run_id is not null,
    'revises_payroll_run_id', v_run.revises_payroll_run_id,
    'superseded', exists (select 1 from public.payroll_runs r2
                           where r2.revises_payroll_run_id = v_run.id and r2.status in ('approved', 'paid')),
    'run_status', v_run.status,
    'period_start', v_run.period_start,
    'period_end', v_run.period_end,
    'published_at', case when v_run.status in ('approved', 'paid') then v_run.approved_at end,
    'generated_at', v_ps.generated_at,
    'currency', coalesce(en.default_currency, 'AED'),
    'employer', jsonb_build_object(
      'entity_id', en.id, 'name', en.name, 'trade_license_no', en.trade_license_no, 'emirate', en.emirate),
    'employee', jsonb_build_object(
      'employee_id', e.id, 'full_name', e.full_name, 'preferred_name', e.preferred_name,
      'position_title', pos.title, 'location_name', loc.name,
      'employment_type', e.employment_type, 'join_date', e.join_date),
    'salary', jsonb_build_object(
      'pay_type', c.pay_type, 'pay_rate', c.pay_rate,
      'overtime_multiplier', c.overtime_multiplier, 'holiday_multiplier', c.holiday_multiplier,
      'regular_hours', coalesce(t.regular_hours, 0), 'overtime_hours', coalesce(t.overtime_hours, 0),
      'holiday_hours', coalesce(t.holiday_hours, 0)),
    'earnings', jsonb_build_array(
      jsonb_build_object('code', 'base', 'label', 'Basic pay', 'amount', coalesce(v_ps.base_pay, 0)),
      jsonb_build_object('code', 'overtime', 'label', 'Overtime', 'amount', coalesce(v_ps.overtime_pay, 0)),
      jsonb_build_object('code', 'holiday', 'label', 'Public holiday pay', 'amount', coalesce(v_ps.holiday_pay, 0)),
      jsonb_build_object('code', 'tips', 'label', 'Tips share', 'amount', coalesce(v_ps.tips_share, 0))),
    'allowances', '[]'::jsonb,
    'deductions', coalesce((
      select jsonb_agg(jsonb_build_object('type', d.deduction_type, 'amount', d.amount, 'notes', d.notes)
                       order by d.created_at)
        from public.payslip_deductions d
       where d.payroll_run_id = v_run.id and d.employee_id = v_ps.employee_id), '[]'::jsonb),
    'gross_pay', coalesce(v_ps.base_pay, 0) + coalesce(v_ps.overtime_pay, 0) + coalesce(v_ps.holiday_pay, 0) + coalesce(v_ps.tips_share, 0),
    'total_deductions', coalesce(v_ps.total_deductions, 0),
    'net_pay', v_ps.net_pay
  ) into v_result
  from public.employees e
  join public.entities en on en.id = v_run.entity_id
  left join public.positions pos on pos.id = e.position_id
  left join public.locations loc on loc.id = e.home_location_id
  left join public.employee_compensation c on c.employee_id = e.id
  left join public.timesheet_entries t on t.payroll_run_id = v_run.id and t.employee_id = e.id
  where e.id = v_ps.employee_id;

  insert into public.audit_log(table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  select 'payslips', v_ps.id, auth.uid(), 'payslip_viewed',
         jsonb_build_object('payroll_run_id', v_run.id, 'viewer_role', v_role, 'source', 'payroll_run_screen'),
         v_run.entity_id, e.home_location_id, v_ps.employee_id
    from public.employees e where e.id = v_ps.employee_id;

  return v_result;
end;
$function$;

revoke all on function public.get_payroll_payslip(uuid) from public, anon;
grant execute on function public.get_payroll_payslip(uuid) to authenticated;
