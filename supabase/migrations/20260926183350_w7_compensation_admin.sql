-- ============================================================
-- W7 Compensation admin:
--   * employee_compensation.pay_type defaults to 'monthly'; rows with
--     no rate yet are flipped to monthly (no pay changes: rate is null).
--   * set_employee_compensation / get_employee_compensation RPCs
--     (owner: all entities; entity_admin: own entity), audited.
--   * Direct INSERT/UPDATE/DELETE on employee_compensation revoked from
--     authenticated. The frontend only SELECTs it (now via the RPC), and
--     every other writer (seed_employee_compensation trigger, reached by
--     bulk import / convert_offer_to_employee inserts; run_payroll_calculation
--     and uat_fixtures_refresh) is SECURITY DEFINER owned by postgres.
--     SELECT stays under the comp_access RLS policy.
--   * add_employees_to_payroll_run: adds a 0-hour timesheet row for every
--     active employee of the run's entity missing from a draft run, via
--     record_timesheet_entry (same checks + audit).
-- ============================================================

-- ------------------------------------------------------------ a. default
alter table public.employee_compensation alter column pay_type set default 'monthly';
-- seed_employee_compensation inserts (employee_id) only, so it picks up the
-- new column default; nothing to change there.

update public.employee_compensation
   set pay_type = 'monthly'
 where pay_rate is null and pay_type <> 'monthly';

-- ------------------------------------------------------------ d. harden
revoke insert, update, delete on table public.employee_compensation from authenticated;
revoke all on table public.employee_compensation from anon;

-- ------------------------------------------------------------ b. setter
create or replace function public.set_employee_compensation(
  p_employee_id uuid,
  p_pay_type text,
  p_pay_rate numeric,
  p_overtime_multiplier numeric default null,
  p_holiday_multiplier numeric default null,
  p_reason text default null
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_emp public.employees;
  v_old public.employee_compensation;
  v_reason text := nullif(btrim(p_reason), '');
  v_pay_type text := lower(nullif(btrim(p_pay_type), ''));
  v_ot numeric;
  v_hol numeric;
  v_linked_role public.user_role;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Only an owner or entity admin can set pay' using errcode = '42501';
  end if;

  select * into v_emp from public.employees where id = p_employee_id for update;
  if v_emp.id is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;
  if not (v_role = 'owner' or (v_role = 'entity_admin' and v_emp.entity_id = public.my_entity())) then
    raise exception 'Not authorized to set pay for this employee' using errcode = '42501';
  end if;
  if v_role <> 'owner' and v_emp.id = public.my_employee_id() then
    raise exception 'You cannot set your own pay' using errcode = '42501';
  end if;
  if v_role <> 'owner' and v_emp.auth_user_id is not null then
    select p.role into v_linked_role from public.profiles p where p.id = v_emp.auth_user_id;
    if v_linked_role = 'owner' then
      raise exception 'Only an owner can set pay for an employee linked to an owner login' using errcode = '42501';
    end if;
  end if;
  if v_emp.employment_status = 'inactive' then
    raise exception 'Cannot set pay for an inactive employee' using errcode = '22023';
  end if;

  if v_pay_type is null or v_pay_type not in ('monthly', 'hourly') then
    raise exception 'Pay type must be monthly or hourly' using errcode = '22023';
  end if;
  if p_pay_rate is null or p_pay_rate <= 0 or p_pay_rate >= 1000000 then
    raise exception 'Pay rate must be greater than 0 and less than AED 1,000,000' using errcode = '22023';
  end if;
  if p_pay_rate <> round(p_pay_rate, 2) then
    raise exception 'Pay rate can have at most 2 decimal places' using errcode = '22023';
  end if;
  if p_overtime_multiplier is not null and (p_overtime_multiplier < 1 or p_overtime_multiplier > 3) then
    raise exception 'Overtime multiplier must be between 1 and 3' using errcode = '22023';
  end if;
  if p_holiday_multiplier is not null and (p_holiday_multiplier < 1 or p_holiday_multiplier > 3) then
    raise exception 'Holiday multiplier must be between 1 and 3' using errcode = '22023';
  end if;

  select * into v_old from public.employee_compensation where employee_id = p_employee_id for update;

  v_ot := coalesce(p_overtime_multiplier, v_old.overtime_multiplier, 1.5);
  v_hol := coalesce(p_holiday_multiplier, v_old.holiday_multiplier, 2.0);

  if v_old.employee_id is not null
     and v_old.pay_type = v_pay_type and v_old.pay_rate = p_pay_rate
     and v_old.overtime_multiplier = v_ot and v_old.holiday_multiplier = v_hol then
    return; -- nothing changed
  end if;

  if v_old.pay_rate is not null and v_reason is null then
    raise exception 'A reason is required when changing an existing pay rate' using errcode = '22023';
  end if;

  insert into public.employee_compensation as c (employee_id, pay_type, pay_rate, overtime_multiplier, holiday_multiplier, updated_at)
  values (p_employee_id, v_pay_type, p_pay_rate, v_ot, v_hol, now())
  on conflict (employee_id) do update
    set pay_type = excluded.pay_type,
        pay_rate = excluded.pay_rate,
        overtime_multiplier = excluded.overtime_multiplier,
        holiday_multiplier = excluded.holiday_multiplier,
        updated_at = now();

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('employee_compensation', p_employee_id, auth.uid(), 'compensation_changed',
    case when v_old.employee_id is null then null else jsonb_build_object(
      'pay_type', v_old.pay_type, 'pay_rate', v_old.pay_rate,
      'overtime_multiplier', v_old.overtime_multiplier, 'holiday_multiplier', v_old.holiday_multiplier) end,
    jsonb_build_object(
      'pay_type', v_pay_type, 'pay_rate', p_pay_rate,
      'overtime_multiplier', v_ot, 'holiday_multiplier', v_hol,
      'reason', v_reason, 'actor_role', v_role),
    v_emp.entity_id, v_emp.home_location_id, p_employee_id);
end;
$$;

revoke all on function public.set_employee_compensation(uuid, text, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.set_employee_compensation(uuid, text, numeric, numeric, numeric, text) to authenticated;

-- ------------------------------------------------------------ c. getter
create or replace function public.get_employee_compensation(p_employee_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_emp public.employees;
  v_c public.employee_compensation;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Only an owner or entity admin can view pay' using errcode = '42501';
  end if;
  select * into v_emp from public.employees where id = p_employee_id;
  if v_emp.id is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;
  if not (v_role = 'owner' or (v_role = 'entity_admin' and v_emp.entity_id = public.my_entity())) then
    raise exception 'Not authorized to view pay for this employee' using errcode = '42501';
  end if;

  select * into v_c from public.employee_compensation where employee_id = p_employee_id;
  return jsonb_build_object(
    'pay_type', coalesce(v_c.pay_type, 'monthly'),
    'pay_rate', v_c.pay_rate,
    'overtime_multiplier', coalesce(v_c.overtime_multiplier, 1.5),
    'holiday_multiplier', coalesce(v_c.holiday_multiplier, 2.0),
    'updated_at', v_c.updated_at
  );
end;
$$;

revoke all on function public.get_employee_compensation(uuid) from public, anon;
grant execute on function public.get_employee_compensation(uuid) to authenticated;

-- ------------------------------------------------------------ e. add to run
-- Adds every ACTIVE employee of the run's entity who has no timesheet row
-- in the run yet (and who had joined by the end of the period), with
-- 0 hours, through record_timesheet_entry (same auth/draft/lock checks
-- and payroll_change_succeeded audit). Returns the number added.
create or replace function public.add_employees_to_payroll_run(p_payroll_run_id uuid)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_run public.payroll_runs;
  v_emp record;
  v_res jsonb;
  v_added integer := 0;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Only an owner or entity admin can change payroll runs' using errcode = '42501';
  end if;
  select * into v_run from public.payroll_runs where id = p_payroll_run_id for update;
  if v_run.id is null then
    raise exception 'Payroll run not found' using errcode = 'P0002';
  end if;
  if not (v_role = 'owner' or (v_role = 'entity_admin' and v_run.entity_id = public.my_entity())) then
    raise exception 'Not authorized to modify this payroll run' using errcode = '42501';
  end if;
  if v_run.status <> 'draft' then
    raise exception 'Payroll run is % — only draft runs can be changed', v_run.status using errcode = '22023';
  end if;

  for v_emp in
    select e.id from public.employees e
     where e.entity_id = v_run.entity_id
       and e.employment_status = 'active'
       and (e.join_date is null or e.join_date <= v_run.period_end)
       and not exists (select 1 from public.timesheet_entries t
                        where t.payroll_run_id = p_payroll_run_id and t.employee_id = e.id)
     order by e.full_name
  loop
    v_res := public.record_timesheet_entry(p_payroll_run_id, v_emp.id, 0, 0, 0, 'Added automatically');
    if coalesce((v_res->>'ok')::boolean, false) then
      v_added := v_added + 1;
    else
      raise exception '%', coalesce(v_res->>'message', 'Could not add employee to payroll run') using errcode = '22023';
    end if;
  end loop;

  return v_added;
end;
$$;

revoke all on function public.add_employees_to_payroll_run(uuid) from public, anon;
grant execute on function public.add_employees_to_payroll_run(uuid) to authenticated;
