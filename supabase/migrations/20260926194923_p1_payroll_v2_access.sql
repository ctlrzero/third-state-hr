-- ============================================================
-- Payroll v2 — permissions and row-level security.
-- Capabilities:
--   view_pay    see salaries, records, lines, advances, payments
--   prepare     prepare/recalculate/adjust/return to draft/corrections
--   approve     approve records (subject to approval_mode)
--   pay         exports and payment recording
--   report      payroll reports
--   settings    payroll settings, compensation, role points, permissions
--   inputs      hours and tips for the caller's own branch (branch manager)
-- Presets:
--   owner                  everything, every company
--   entity_admin           everything in their company (payroll admin)
--   payroll_admin (grant)  everything in the granted company
--   accountant (grant)     view_pay, pay, report
--   location_manager       inputs for their branch only; no salaries
--   staff                  own published payslips only
-- ============================================================

create or replace function public.payroll_can(p_entity_id uuid, p_cap text)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_preset text;
begin
  if p_entity_id is null or v_role is null or not public.is_active_user() then
    return false;
  end if;
  if v_role = 'owner' then
    return true;
  end if;
  if v_role = 'entity_admin' and p_entity_id = public.my_entity() then
    return true;
  end if;
  select preset into v_preset from public.payroll_permissions
   where user_id = auth.uid() and entity_id = p_entity_id;
  if v_preset = 'payroll_admin' then
    return true;
  end if;
  if v_preset = 'accountant' then
    return p_cap in ('view_pay', 'pay', 'report');
  end if;
  if v_role = 'location_manager' and p_entity_id = public.my_entity() then
    return p_cap = 'inputs';
  end if;
  return false;
end;
$$;
revoke all on function public.payroll_can(uuid, text) from public, anon;
grant execute on function public.payroll_can(uuid, text) to authenticated;

-- Branch-manager inputs are limited to employees whose home branch is theirs.
create or replace function public.payroll_can_input_for(p_employee_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.employees e
     where e.id = p_employee_id
       and (public.payroll_can(e.entity_id, 'prepare')
            or (public.payroll_can(e.entity_id, 'inputs') and e.home_location_id = public.my_location()))
  );
$$;
revoke all on function public.payroll_can_input_for(uuid) from public, anon;
grant execute on function public.payroll_can_input_for(uuid) to authenticated;

create or replace function public.payroll_period_entity(p_period_id uuid)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select entity_id from public.payroll_periods where id = p_period_id;
$$;
revoke all on function public.payroll_period_entity(uuid) from public, anon;
grant execute on function public.payroll_period_entity(uuid) to authenticated;

create or replace function public.payroll_employee_entity(p_employee_id uuid)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select entity_id from public.employees where id = p_employee_id;
$$;
revoke all on function public.payroll_employee_entity(uuid) from public, anon;
grant execute on function public.payroll_employee_entity(uuid) to authenticated;

-- ------------------------------------------------------------- policies
create policy payroll_settings_select on public.payroll_settings for select to authenticated
  using (public.payroll_can(entity_id, 'view_pay') or public.payroll_can(entity_id, 'inputs'));

create policy compensation_versions_select on public.compensation_versions for select to authenticated
  using (public.payroll_can(public.payroll_employee_entity(employee_id), 'view_pay'));

create policy compensation_components_select on public.compensation_components for select to authenticated
  using (public.payroll_can(public.payroll_employee_entity(employee_id), 'view_pay'));

create policy payroll_periods_select on public.payroll_periods for select to authenticated
  using (public.payroll_can(entity_id, 'view_pay') or public.payroll_can(entity_id, 'inputs'));

create policy payroll_records_select on public.payroll_records for select to authenticated
  using (public.payroll_can(public.payroll_period_entity(period_id), 'view_pay')
         or (employee_id = public.my_employee_id() and published_at is not null));

create policy payroll_lines_select on public.payroll_lines for select to authenticated
  using (exists (select 1 from public.payroll_records r
                  where r.id = payroll_lines.record_id
                    and (public.payroll_can(public.payroll_period_entity(r.period_id), 'view_pay')
                         or (r.employee_id = public.my_employee_id() and r.published_at is not null))));

create policy payroll_hours_select on public.payroll_hours for select to authenticated
  using (public.payroll_can(public.payroll_period_entity(period_id), 'view_pay')
         or public.payroll_can_input_for(employee_id));

create policy payroll_adjustments_select on public.payroll_adjustments for select to authenticated
  using (public.payroll_can(public.payroll_period_entity(period_id), 'view_pay'));

create policy tip_role_points_select on public.tip_role_points for select to authenticated
  using (exists (select 1 from public.positions p where p.id = tip_role_points.position_id
                  and (public.payroll_can(p.entity_id, 'view_pay') or public.payroll_can(p.entity_id, 'inputs'))));

create policy tip_pools_select on public.tip_pools for select to authenticated
  using (public.payroll_can(public.payroll_period_entity(period_id), 'view_pay')
         or (public.payroll_can(public.payroll_period_entity(period_id), 'inputs') and location_id = public.my_location()));

create policy tip_allocations_select on public.tip_allocations for select to authenticated
  using (exists (select 1 from public.tip_pools tp where tp.id = tip_allocations.pool_id
                  and (public.payroll_can(public.payroll_period_entity(tp.period_id), 'view_pay')
                       or (public.payroll_can(public.payroll_period_entity(tp.period_id), 'inputs')
                           and tp.location_id = public.my_location()))));

create policy salary_advances_select on public.salary_advances for select to authenticated
  using (public.payroll_can(entity_id, 'view_pay') or employee_id = public.my_employee_id());

create policy advance_repayments_select on public.advance_repayments for select to authenticated
  using (exists (select 1 from public.salary_advances a where a.id = advance_repayments.advance_id
                  and (public.payroll_can(a.entity_id, 'view_pay') or a.employee_id = public.my_employee_id())));

create policy payroll_payments_select on public.payroll_payments for select to authenticated
  using (exists (select 1 from public.payroll_records r where r.id = payroll_payments.record_id
                  and (public.payroll_can(public.payroll_period_entity(r.period_id), 'view_pay')
                       or (r.employee_id = public.my_employee_id() and r.published_at is not null))));

create policy payroll_exports_select on public.payroll_exports for select to authenticated
  using (public.payroll_can(public.payroll_period_entity(period_id), 'view_pay'));

create policy payroll_export_items_select on public.payroll_export_items for select to authenticated
  using (exists (select 1 from public.payroll_exports x where x.id = payroll_export_items.export_id
                  and public.payroll_can(public.payroll_period_entity(x.period_id), 'view_pay')));

create policy payroll_permissions_select on public.payroll_permissions for select to authenticated
  using (user_id = auth.uid() or public.payroll_can(entity_id, 'settings'));
