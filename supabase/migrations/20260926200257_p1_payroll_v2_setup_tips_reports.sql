-- ============================================================
-- Payroll v2 — tips, advances, compensation, settings, permissions,
-- read models (workspace, record detail), reports, employee payslips.
-- ============================================================

-- ------------------------------------------------------------------ tips
-- Largest-remainder split in fils: shares always add up exactly to the pool.
create or replace function public._payroll_tip_split(p_period_id uuid, p_location_id uuid, p_start date, p_end date,
  p_amount numeric, p_settlement text, p_method text, p_employee_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  p public.payroll_periods;
  e record;
  v_reason text;
  v_hours numeric;
  v_points numeric;
  v_weight numeric;
  v_items jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_default_points boolean := false;
  v_alloc jsonb;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if p_method not in ('equal', 'hours', 'role_points', 'hours_points') then
    raise exception 'Unknown distribution method' using errcode = '22023';
  end if;
  if p_settlement not in ('payroll', 'cash_paid') then
    raise exception 'Say whether tips are paid through payroll or were already paid in cash' using errcode = '22023';
  end if;
  if coalesce(p_amount, -1) < 0 or round(p_amount, 2) <> p_amount then
    raise exception 'Enter the pool amount with at most 2 decimals' using errcode = '22023';
  end if;
  if p_start < p.period_start or p_end > p.period_end or p_end < p_start then
    raise exception 'Pool dates must fall inside this payroll month' using errcode = '22023';
  end if;
  if not exists (select 1 from public.locations where id = p_location_id and entity_id = p.entity_id) then
    raise exception 'Branch belongs to another company' using errcode = '42501';
  end if;

  for e in select em.id, em.full_name, em.position_id from public.employees em where em.id = any(p_employee_ids) order by em.full_name loop
    v_reason := coalesce(public._payroll_ineligible_reason(e.id, p.id), public._payroll_frozen_reason(p.id, e.id));
    select coalesce(sum(psr.final_payable_minutes), 0) / 60.0 into v_hours
      from public.payable_shift_records psr join public.shifts s on s.id = psr.shift_id
     where psr.employee_id = e.id and s.location_id = p_location_id and s.shift_date between p_start and p_end
       and psr.final_payable_minutes is not null;
    if v_hours = 0 and p_start = p.period_start and p_end = p.period_end then
      select coalesce(h.regular_hours + h.overtime_hours + h.night_overtime_hours + h.holiday_hours, 0) into v_hours
        from public.payroll_hours h where h.period_id = p.id and h.employee_id = e.id;
      v_hours := coalesce(v_hours, 0);
    end if;
    select points into v_points from public.tip_role_points where position_id = e.position_id;
    if v_points is null then v_points := 1; if p_method in ('role_points', 'hours_points') then v_default_points := true; end if; end if;
    v_weight := case p_method when 'equal' then 1 when 'hours' then v_hours when 'role_points' then v_points
                                else v_hours * v_points end;
    if v_reason is null and v_weight <= 0 then v_reason := 'No hours at this branch in the pool dates'; end if;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.full_name, 'reason', v_reason);
      continue;
    end if;
    v_items := v_items || jsonb_build_object('id', e.id, 'name', e.full_name, 'hours', round(v_hours, 2),
                                             'points', v_points, 'weight', v_weight);
  end loop;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'No eligible employees for this pool', 'items', '[]'::jsonb,
                              'skipped', v_skipped, 'total', p_amount);
  end if;

  with t as (
    select x, (x ->> 'weight')::numeric as w, x ->> 'name' as nm from jsonb_array_elements(v_items) x
  ), raw as (
    select x, nm, round(p_amount * 100)::bigint * w / sum(w) over () as r from t
  ), fl as (
    select x, nm, floor(r)::bigint as f, r - floor(r) as frac from raw
  ), ranked as (
    select x, f, row_number() over (order by frac desc, nm) as rn,
           round(p_amount * 100)::bigint - sum(f) over () as remainder from fl
  )
  select jsonb_agg(x || jsonb_build_object('amount', (f + case when rn <= remainder then 1 else 0 end) / 100.0)
                   order by x ->> 'name')
    into v_alloc from ranked;

  return jsonb_build_object('ok', true, 'items', v_alloc, 'skipped', v_skipped, 'total', p_amount,
    'allocated', (select sum((a ->> 'amount')::numeric) from jsonb_array_elements(v_alloc) a),
    'default_points_used', v_default_points);
end;
$$;
revoke all on function public._payroll_tip_split(uuid, uuid, date, date, numeric, text, text, uuid[]) from public, anon, authenticated;

create or replace function public.payroll_tip_preview(p_period_id uuid, p_location_id uuid, p_start date, p_end date,
  p_amount numeric, p_settlement text, p_method text, p_employee_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_entity uuid := public.payroll_period_entity(p_period_id);
begin
  if not (public.payroll_can(v_entity, 'prepare')
          or (public.payroll_can(v_entity, 'inputs') and p_location_id = public.my_location())) then
    raise exception 'No permission to distribute tips for this branch' using errcode = '42501';
  end if;
  return public._payroll_tip_split(p_period_id, p_location_id, p_start, p_end, p_amount, p_settlement, p_method, p_employee_ids);
end;
$$;

create or replace function public.payroll_tip_confirm(p_period_id uuid, p_location_id uuid, p_start date, p_end date,
  p_amount numeric, p_settlement text, p_method text, p_employee_ids uuid[], p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_entity uuid := public.payroll_period_entity(p_period_id);
  v_split jsonb;
  v_pool uuid;
  x jsonb;
begin
  if not (public.payroll_can(v_entity, 'prepare')
          or (public.payroll_can(v_entity, 'inputs') and p_location_id = public.my_location())) then
    raise exception 'No permission to distribute tips for this branch' using errcode = '42501';
  end if;
  v_split := public._payroll_tip_split(p_period_id, p_location_id, p_start, p_end, p_amount, p_settlement, p_method, p_employee_ids);
  if not (v_split ->> 'ok')::boolean then
    return v_split;
  end if;
  if exists (select 1 from public.tip_pools where period_id = p_period_id and location_id = p_location_id
               and pool_start = p_start and pool_end = p_end and settlement = p_settlement and voided_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'A pool for this branch and dates is already confirmed; remove it first to redo it');
  end if;
  insert into public.tip_pools (period_id, location_id, pool_start, pool_end, total_amount, settlement, method, notes, created_by)
  values (p_period_id, p_location_id, p_start, p_end, p_amount, p_settlement, p_method, p_notes, auth.uid())
  returning id into v_pool;
  for x in select * from jsonb_array_elements(v_split -> 'items') loop
    insert into public.tip_allocations (pool_id, employee_id, hours, points, weight, amount)
    values (v_pool, (x ->> 'id')::uuid, (x ->> 'hours')::numeric, (x ->> 'points')::numeric,
            (x ->> 'weight')::numeric, (x ->> 'amount')::numeric);
    if not exists (select 1 from public.payroll_records where period_id = p_period_id and employee_id = (x ->> 'id')::uuid
                      and superseded_by_record_id is null) then
      insert into public.payroll_records (period_id, employee_id) values (p_period_id, (x ->> 'id')::uuid);
    end if;
    perform public._payroll_refresh(p_period_id, (x ->> 'id')::uuid);
  end loop;
  perform public._payroll_audit(v_entity, 'tip_pools', v_pool, 'payroll_tips_distributed', null,
    jsonb_build_object('amount', p_amount, 'method', p_method, 'settlement', p_settlement,
                       'employees', jsonb_array_length(v_split -> 'items')), null);
  return v_split || jsonb_build_object('pool_id', v_pool);
end;
$$;

create or replace function public.payroll_tip_void(p_pool_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  tp public.tip_pools;
  v_entity uuid;
  v_frozen text;
  x record;
begin
  select * into tp from public.tip_pools where id = p_pool_id;
  if tp.id is null then raise exception 'Tip pool not found' using errcode = 'P0002'; end if;
  v_entity := public.payroll_period_entity(tp.period_id);
  if not (public.payroll_can(v_entity, 'prepare')
          or (public.payroll_can(v_entity, 'inputs') and tp.location_id = public.my_location())) then
    raise exception 'No permission' using errcode = '42501';
  end if;
  if tp.voided_at is not null then return jsonb_build_object('ok', false, 'reason', 'Already removed'); end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  select string_agg(e.full_name, ', ') into v_frozen
    from public.tip_allocations ta join public.employees e on e.id = ta.employee_id
   where ta.pool_id = tp.id and public._payroll_frozen_reason(tp.period_id, ta.employee_id) is not null;
  if v_frozen is not null then
    return jsonb_build_object('ok', false, 'reason', 'These employees are already approved or in review: ' || v_frozen);
  end if;
  update public.tip_pools set voided_at = now(), voided_by = auth.uid(),
         notes = coalesce(notes || ' | ', '') || 'Removed: ' || btrim(p_reason) where id = tp.id;
  for x in select employee_id from public.tip_allocations where pool_id = tp.id loop
    perform public._payroll_refresh(tp.period_id, x.employee_id);
  end loop;
  perform public._payroll_audit(v_entity, 'tip_pools', tp.id, 'payroll_tips_removed', to_jsonb(tp),
    jsonb_build_object('reason', p_reason), null);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.payroll_set_role_points(p_position_id uuid, p_points numeric)
returns void language plpgsql security definer set search_path to '' as $$
declare v_entity uuid;
begin
  select entity_id into v_entity from public.positions where id = p_position_id;
  perform public._payroll_require(v_entity, 'settings');
  if p_points is null then
    delete from public.tip_role_points where position_id = p_position_id;
  else
    insert into public.tip_role_points (position_id, points, updated_by) values (p_position_id, p_points, auth.uid())
    on conflict (position_id) do update set points = excluded.points, updated_by = excluded.updated_by, updated_at = now();
  end if;
end;
$$;

-- --------------------------------------------------------------- advances
create or replace function public._payroll_refresh_employee(p_employee_id uuid, p_from date)
returns void language plpgsql security definer set search_path to '' as $$
declare x record;
begin
  for x in
    select r.id from public.payroll_records r join public.payroll_periods p on p.id = r.period_id
     where r.employee_id = p_employee_id and r.record_status = 'draft' and r.superseded_by_record_id is null
       and p.period_end >= coalesce(p_from, date '2000-01-01')
  loop
    perform public._payroll_calculate(x.id);
  end loop;
end;
$$;
revoke all on function public._payroll_refresh_employee(uuid, date) from public, anon, authenticated;

create or replace function public.payroll_create_advance(p_employee_id uuid, p_amount numeric, p_disbursed_on date,
  p_method text, p_repayment_start date, p_instalments integer, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_entity uuid := public.payroll_employee_entity(p_employee_id);
  v_id uuid;
  v_inst numeric;
begin
  perform public._payroll_require(v_entity, 'prepare');
  if coalesce(p_amount, 0) <= 0 or round(p_amount, 2) <> p_amount then
    raise exception 'Enter an amount above zero with at most 2 decimals' using errcode = '22023';
  end if;
  if coalesce(p_instalments, 0) not between 1 and 60 then
    raise exception 'Instalments must be between 1 and 60' using errcode = '22023';
  end if;
  if date_trunc('month', p_repayment_start) < date_trunc('month', p_disbursed_on) then
    raise exception 'Repayment cannot start before the advance is paid' using errcode = '22023';
  end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  v_inst := ceil(p_amount * 100 / p_instalments) / 100.0;
  insert into public.salary_advances (entity_id, employee_id, amount, disbursed_on, disbursement_method, repayment_start,
                                      instalments, instalment_amount, reason, created_by)
  values (v_entity, p_employee_id, p_amount, p_disbursed_on, p_method, date_trunc('month', p_repayment_start)::date,
          p_instalments, v_inst, btrim(p_reason), auth.uid())
  returning id into v_id;
  perform public._payroll_audit(v_entity, 'salary_advances', v_id, 'payroll_advance_created', null,
    jsonb_build_object('amount', p_amount, 'instalments', p_instalments, 'instalment', v_inst,
                       'repayment_start', p_repayment_start), p_employee_id);
  perform public._payroll_refresh_employee(p_employee_id, least(p_disbursed_on, p_repayment_start));
  return jsonb_build_object('ok', true, 'advance_id', v_id, 'instalment_amount', v_inst,
    'note', case when v_inst * p_instalments > p_amount
                 then format('The last instalment is smaller so the total is exactly %s.', public._payroll_fmt(p_amount)) end);
end;
$$;

create or replace function public.payroll_cancel_advance(p_advance_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare a public.salary_advances;
begin
  select * into a from public.salary_advances where id = p_advance_id;
  if a.id is null then raise exception 'Advance not found' using errcode = 'P0002'; end if;
  perform public._payroll_require(a.entity_id, 'prepare');
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if exists (select 1 from public.advance_repayments where advance_id = a.id) then
    return jsonb_build_object('ok', false, 'reason', 'Repayments are already locked into approved payroll; it cannot be cancelled');
  end if;
  update public.salary_advances set status = 'cancelled', cancelled_reason = btrim(p_reason) where id = a.id;
  perform public._payroll_audit(a.entity_id, 'salary_advances', a.id, 'payroll_advance_cancelled', to_jsonb(a),
    jsonb_build_object('reason', p_reason), a.employee_id);
  perform public._payroll_refresh_employee(a.employee_id, a.disbursed_on);
  return jsonb_build_object('ok', true);
end;
$$;

-- ----------------------------------------------------------- compensation
create or replace function public._payroll_can_edit_pay(p_employee_id uuid)
returns text language plpgsql stable security definer set search_path to '' as $$
declare e public.employees;
begin
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then return 'Employee not found'; end if;
  if not public.payroll_can(e.entity_id, 'settings') then return 'No permission to change pay'; end if;
  if public.my_role() <> 'owner' then
    if e.id = public.my_employee_id() then return 'You cannot change your own pay'; end if;
    if exists (select 1 from public.profiles pr where pr.id = e.auth_user_id and pr.role = 'owner') then
      return 'Only the owner can change pay for an owner login';
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public._payroll_can_edit_pay(uuid) from public, anon, authenticated;

create or replace function public.payroll_set_compensation(p_employee_id uuid, p_effective_from date, p_pay_type text,
  p_basic_monthly numeric, p_hourly_rate numeric, p_overtime_eligible boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_reason text := public._payroll_can_edit_pay(p_employee_id);
  v_old jsonb;
  v_id uuid;
  v_latest public.compensation_versions;
begin
  if v_reason is not null then raise exception '%', v_reason using errcode = '42501'; end if;
  if p_effective_from is null then raise exception 'Choose the date the pay takes effect' using errcode = '22023'; end if;
  if p_pay_type not in ('monthly', 'hourly') then raise exception 'Pay type must be monthly or hourly' using errcode = '22023'; end if;
  if p_pay_type = 'monthly' and (coalesce(p_basic_monthly, 0) <= 0 or round(p_basic_monthly, 2) <> p_basic_monthly) then
    raise exception 'Enter a monthly basic salary above zero' using errcode = '22023';
  end if;
  if p_pay_type = 'hourly' and (coalesce(p_hourly_rate, 0) <= 0 or round(p_hourly_rate, 2) <> p_hourly_rate) then
    raise exception 'Enter an hourly rate above zero' using errcode = '22023';
  end if;
  if exists (select 1 from public.compensation_versions where employee_id = p_employee_id)
     and nullif(btrim(p_reason), '') is null then
    raise exception 'A reason is required when pay changes' using errcode = '22023';
  end if;
  select to_jsonb(v) into v_old from public.compensation_versions v
   where employee_id = p_employee_id and effective_from = p_effective_from;
  insert into public.compensation_versions (employee_id, effective_from, pay_type, basic_monthly, hourly_rate,
                                            overtime_eligible, reason, created_by)
  values (p_employee_id, p_effective_from, p_pay_type,
          case when p_pay_type = 'monthly' then p_basic_monthly end, case when p_pay_type = 'hourly' then p_hourly_rate end,
          coalesce(p_overtime_eligible, true), nullif(btrim(p_reason), ''), auth.uid())
  on conflict (employee_id, effective_from) do update
    set pay_type = excluded.pay_type, basic_monthly = excluded.basic_monthly, hourly_rate = excluded.hourly_rate,
        overtime_eligible = excluded.overtime_eligible, reason = excluded.reason, created_by = excluded.created_by,
        created_at = now()
  returning id into v_id;
  -- Keep the legacy single-row table in step with today's version.
  v_latest := public._payroll_comp_on(p_employee_id, (now() at time zone 'Asia/Dubai')::date);
  if v_latest.id is not null then
    insert into public.employee_compensation (employee_id, pay_type, pay_rate)
    values (p_employee_id, v_latest.pay_type, coalesce(v_latest.basic_monthly, v_latest.hourly_rate))
    on conflict (employee_id) do update set pay_type = excluded.pay_type, pay_rate = excluded.pay_rate;
  end if;
  perform public._payroll_audit(public.payroll_employee_entity(p_employee_id), 'compensation_versions', v_id,
    'compensation_changed', v_old,
    jsonb_build_object('effective_from', p_effective_from, 'pay_type', p_pay_type, 'basic_monthly', p_basic_monthly,
                       'hourly_rate', p_hourly_rate, 'overtime_eligible', p_overtime_eligible, 'reason', p_reason), p_employee_id);
  perform public._payroll_refresh_employee(p_employee_id, p_effective_from);
  return jsonb_build_object('ok', true, 'version_id', v_id);
end;
$$;

create or replace function public.payroll_add_component(p_employee_id uuid, p_kind text, p_code text, p_label text,
  p_monthly_amount numeric, p_prorate boolean, p_effective_from date, p_effective_to date, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_reason text := public._payroll_can_edit_pay(p_employee_id);
  v_id uuid;
begin
  if v_reason is not null then raise exception '%', v_reason using errcode = '42501'; end if;
  if coalesce(p_monthly_amount, 0) <= 0 or round(p_monthly_amount, 2) <> p_monthly_amount then
    raise exception 'Enter a monthly amount above zero' using errcode = '22023';
  end if;
  if nullif(btrim(p_label), '') is null then raise exception 'Give it a name' using errcode = '22023'; end if;
  insert into public.compensation_components (employee_id, kind, code, label, monthly_amount, prorate, effective_from,
                                              effective_to, reason, created_by)
  values (p_employee_id, p_kind, p_code, btrim(p_label), p_monthly_amount, coalesce(p_prorate, true), p_effective_from,
          p_effective_to, nullif(btrim(p_reason), ''), auth.uid())
  returning id into v_id;
  perform public._payroll_audit(public.payroll_employee_entity(p_employee_id), 'compensation_components', v_id,
    'compensation_component_added', null,
    jsonb_build_object('kind', p_kind, 'code', p_code, 'amount', p_monthly_amount, 'from', p_effective_from, 'to', p_effective_to),
    p_employee_id);
  perform public._payroll_refresh_employee(p_employee_id, p_effective_from);
  return jsonb_build_object('ok', true, 'component_id', v_id);
end;
$$;

create or replace function public.payroll_end_component(p_component_id uuid, p_effective_to date, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  c public.compensation_components;
  v_reason text;
begin
  select * into c from public.compensation_components where id = p_component_id;
  if c.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  v_reason := public._payroll_can_edit_pay(c.employee_id);
  if v_reason is not null then raise exception '%', v_reason using errcode = '42501'; end if;
  if p_effective_to < c.effective_from - 1 then
    raise exception 'End date is before it started' using errcode = '22023';
  end if;
  update public.compensation_components set effective_to = p_effective_to where id = c.id;
  perform public._payroll_audit(public.payroll_employee_entity(c.employee_id), 'compensation_components', c.id,
    'compensation_component_ended', to_jsonb(c), jsonb_build_object('effective_to', p_effective_to, 'reason', p_reason), c.employee_id);
  perform public._payroll_refresh_employee(c.employee_id, least(p_effective_to, coalesce(c.effective_to, p_effective_to)));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.payroll_set_last_working_date(p_employee_id uuid, p_date date, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_entity uuid := public.payroll_employee_entity(p_employee_id);
        v_old date;
begin
  perform public._payroll_require(v_entity, 'prepare');
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  select last_working_date into v_old from public.employees where id = p_employee_id;
  update public.employees set last_working_date = p_date, updated_at = now() where id = p_employee_id;
  perform public._payroll_audit(v_entity, 'employees', p_employee_id, 'employee_last_working_date_set',
    jsonb_build_object('last_working_date', v_old), jsonb_build_object('last_working_date', p_date, 'reason', p_reason), p_employee_id);
  perform public._payroll_refresh_employee(p_employee_id, least(coalesce(v_old, p_date), coalesce(p_date, v_old)));
  return jsonb_build_object('ok', true);
end;
$$;

-- Gratuity preview (Decree-Law 33/2021 Art. 51): 21 days' basic per year for
-- the first 5 years, 30 days after; pro-rated; minimum 1 year; capped at 2
-- years' wage; unpaid leave days excluded from service; not for UAE nationals.
create or replace function public.payroll_gratuity_preview(p_employee_id uuid, p_last_day date)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  e public.employees;
  v_basic numeric;
  v_unpaid integer;
  v_days integer;
  v_years numeric;
  v_daily numeric;
  v_amount numeric;
  v_cap numeric;
begin
  select * into e from public.employees where id = p_employee_id;
  perform public._payroll_require(e.entity_id, 'prepare');
  if lower(btrim(coalesce(e.nationality, ''))) in ('uae', 'emirati', 'united arab emirates') then
    return jsonb_build_object('ok', false, 'reason', 'UAE nationals receive pension benefits instead of labour-law gratuity (Art. 51(1)).');
  end if;
  if e.join_date is null then return jsonb_build_object('ok', false, 'reason', 'No joining date on file'); end if;
  v_basic := (public._payroll_comp_on(e.id, p_last_day)).basic_monthly;
  if v_basic is null then return jsonb_build_object('ok', false, 'reason', 'No monthly basic salary on file'); end if;
  select coalesce(sum(least(lr.end_date, p_last_day) - greatest(lr.start_date, e.join_date) + 1), 0) into v_unpaid
    from public.leave_requests lr join public.leave_types lt on lt.id = lr.leave_type_id
   where lr.employee_id = e.id and lr.status = 'approved' and lt.payroll_treatment = 'unpaid'
     and lr.start_date <= p_last_day and lr.end_date >= e.join_date;
  v_days := (p_last_day - e.join_date + 1) - v_unpaid;
  v_years := round(v_days / 365.0, 4);
  if v_years < 1 then
    return jsonb_build_object('ok', true, 'amount', 0, 'years', v_years,
      'explanation', 'Less than one year of continuous service: no gratuity is due (Art. 51(2)).');
  end if;
  v_daily := v_basic / 30;
  v_amount := v_daily * 21 * least(v_years, 5) + v_daily * 30 * greatest(v_years - 5, 0);
  v_cap := v_basic * 24;
  v_amount := round(least(v_amount, v_cap), 2);
  return jsonb_build_object('ok', true, 'amount', v_amount, 'years', v_years, 'unpaid_days_excluded', v_unpaid,
    'explanation', format('%s years of service (%s unpaid days excluded). Last basic %s ÷ 30 = %s per day; 21 days per year for the first 5 years%s%s.',
      v_years, v_unpaid, public._payroll_fmt(v_basic), public._payroll_fmt(round(v_daily, 2)),
      case when v_years > 5 then ', 30 days per year after that' else '' end,
      case when v_amount = round(v_cap, 2) then '; capped at 2 years'' wage' else '' end),
    'note', 'Day rate basic ÷ 30 follows Art. 67 (a month counts as 30 days). Check the contract before paying.');
end;
$$;

-- --------------------------------------------------------------- settings
create or replace function public.payroll_save_settings(p_entity_id uuid, p_effective_from date, p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_id uuid;
  cur public.payroll_settings;
begin
  perform public._payroll_require(p_entity_id, 'settings');
  if p ->> 'approval_mode' = 'owner_single_step' and public.my_role() <> 'owner' then
    raise exception 'Only the owner can switch on single-step approval' using errcode = '42501';
  end if;
  if (coalesce((p ->> 'overtime_multiplier')::numeric, 1.25) < 1.25
      or coalesce((p ->> 'night_overtime_multiplier')::numeric, 1.5) < 1.5
      or coalesce((p ->> 'holiday_multiplier')::numeric, 1.5) < 1.5
      or coalesce((p ->> 'max_deduction_pct')::numeric, 50) > 50) then
    raise exception 'Overtime premiums below the legal minimum (25%% / 50%% / 50%%) or a deduction limit above 50%% are not allowed (Decree-Law 33/2021 Arts. 19, 25, 28)'
      using errcode = '22023';
  end if;
  cur := public._payroll_settings(p_entity_id, coalesce(p_effective_from, current_date));
  insert into public.payroll_settings (entity_id, effective_from, pay_day, day_rate_basis, approval_mode, unpaid_leave_basis,
    overtime_hour_divisor, overtime_multiplier, night_overtime_multiplier, holiday_multiplier, max_deduction_pct,
    default_payment_method, payslip_note, confirmed, created_by)
  values (p_entity_id, coalesce(p_effective_from, date_trunc('month', current_date)::date),
    coalesce((p ->> 'pay_day')::smallint, cur.pay_day),
    coalesce(p ->> 'day_rate_basis', cur.day_rate_basis),
    coalesce(p ->> 'approval_mode', cur.approval_mode),
    coalesce(p ->> 'unpaid_leave_basis', cur.unpaid_leave_basis),
    coalesce((p ->> 'overtime_hour_divisor')::numeric, cur.overtime_hour_divisor),
    coalesce((p ->> 'overtime_multiplier')::numeric, cur.overtime_multiplier),
    coalesce((p ->> 'night_overtime_multiplier')::numeric, cur.night_overtime_multiplier),
    coalesce((p ->> 'holiday_multiplier')::numeric, cur.holiday_multiplier),
    coalesce((p ->> 'max_deduction_pct')::numeric, cur.max_deduction_pct),
    coalesce(p ->> 'default_payment_method', cur.default_payment_method),
    coalesce(p ->> 'payslip_note', cur.payslip_note),
    true, auth.uid())
  on conflict (entity_id, effective_from) do update
    set pay_day = excluded.pay_day, day_rate_basis = excluded.day_rate_basis, approval_mode = excluded.approval_mode,
        unpaid_leave_basis = excluded.unpaid_leave_basis, overtime_hour_divisor = excluded.overtime_hour_divisor,
        overtime_multiplier = excluded.overtime_multiplier, night_overtime_multiplier = excluded.night_overtime_multiplier,
        holiday_multiplier = excluded.holiday_multiplier, max_deduction_pct = excluded.max_deduction_pct,
        default_payment_method = excluded.default_payment_method, payslip_note = excluded.payslip_note,
        confirmed = true, created_by = excluded.created_by, created_at = now()
  returning id into v_id;
  perform public._payroll_audit(p_entity_id, 'payroll_settings', v_id, 'payroll_settings_saved', to_jsonb(cur), p, null);
  return jsonb_build_object('ok', true, 'settings_id', v_id);
end;
$$;

create or replace function public.payroll_get_settings(p_entity_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if not (public.payroll_can(p_entity_id, 'view_pay') or public.payroll_can(p_entity_id, 'inputs')) then
    raise exception 'No permission' using errcode = '42501';
  end if;
  return to_jsonb(public._payroll_settings(p_entity_id, (now() at time zone 'Asia/Dubai')::date))
    || jsonb_build_object('history', coalesce((select jsonb_agg(to_jsonb(s) order by s.effective_from desc)
                                                 from public.payroll_settings s where s.entity_id = p_entity_id), '[]'::jsonb),
                          'can_edit', public.payroll_can(p_entity_id, 'settings'),
                          'is_owner', public.my_role() = 'owner');
end;
$$;

create or replace function public.payroll_set_permission(p_user_id uuid, p_entity_id uuid, p_preset text, p_single_step boolean)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_old jsonb;
begin
  perform public._payroll_require(p_entity_id, 'settings');
  if coalesce(p_single_step, false) and public.my_role() <> 'owner' then
    raise exception 'Only the owner can grant single-step approval' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then raise exception 'You cannot change your own payroll access' using errcode = '42501'; end if;
  select to_jsonb(x) into v_old from public.payroll_permissions x where user_id = p_user_id and entity_id = p_entity_id;
  if p_preset is null then
    delete from public.payroll_permissions where user_id = p_user_id and entity_id = p_entity_id;
  else
    insert into public.payroll_permissions (user_id, entity_id, preset, can_single_step_approve, granted_by)
    values (p_user_id, p_entity_id, p_preset, coalesce(p_single_step, false), auth.uid())
    on conflict (user_id, entity_id) do update
      set preset = excluded.preset, can_single_step_approve = excluded.can_single_step_approve,
          granted_by = excluded.granted_by, granted_at = now();
  end if;
  perform public._payroll_audit(p_entity_id, 'payroll_permissions', p_user_id, 'payroll_permission_changed', v_old,
    jsonb_build_object('preset', p_preset, 'single_step', p_single_step), null);
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------ read models
create or replace function public._payroll_row(p_record_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
    'record_id', r.id, 'employee_id', e.id, 'name', e.full_name, 'branch', l.name, 'location_id', e.home_location_id,
    'position', pos.title, 'pay_type', (public._payroll_comp_on(e.id, pp.period_end)).pay_type,
    'record_status', r.record_status, 'calc_version', r.calc_version, 'approved_version', r.approved_version,
    'fixed_pay', coalesce((select sum(amount) from public.payroll_lines x where x.record_id = r.id and x.kind = 'earning'
                            and (x.code in ('basic', 'hourly_pay') or x.source_type = 'compensation_component')), 0),
    'extra_earnings', r.gross - coalesce((select sum(amount) from public.payroll_lines x where x.record_id = r.id and x.kind = 'earning'
                            and (x.code in ('basic', 'hourly_pay') or x.source_type = 'compensation_component')), 0),
    'gross', r.gross, 'deductions', r.deductions, 'net', r.net,
    'paid', m.paid, 'outstanding', case when r.record_status = 'approved' then m.outstanding else null end,
    'payment_status', m.payment_status, 'failed_attempts', m.failed_attempts,
    'published_at', r.published_at, 'attention', r.attention,
    'is_correction', r.supersedes_record_id is not null, 'returned_reason', r.returned_reason,
    'hours_status', (select h.status from public.payroll_hours h where h.period_id = r.period_id and h.employee_id = e.id),
    'in_active_export', exists (select 1 from public.payroll_export_items i join public.payroll_exports x on x.id = i.export_id
                                 where i.record_id = r.id and x.invalidated_at is null))
  from public.payroll_records r
  join public.payroll_periods pp on pp.id = r.period_id
  join public.employees e on e.id = r.employee_id
  left join public.locations l on l.id = e.home_location_id
  left join public.positions pos on pos.id = e.position_id
  cross join lateral public._payroll_money(r.id) m
  where r.id = p_record_id;
$$;
revoke all on function public._payroll_row(uuid) from public, anon, authenticated;

create or replace function public.payroll_periods_list(p_entity_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if not (public.payroll_can(p_entity_id, 'view_pay') or public.payroll_can(p_entity_id, 'inputs')) then
    raise exception 'No permission' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'period_start', p.period_start, 'period_end', p.period_end,
      'label', p.label,
      'employees', (select count(*) from public.payroll_records r where r.period_id = p.id and r.superseded_by_record_id is null),
      'approved', (select count(*) from public.payroll_records r where r.period_id = p.id and r.superseded_by_record_id is null and r.record_status = 'approved'),
      'net', case when public.payroll_can(p_entity_id, 'view_pay') then
               (select coalesce(sum(net), 0) from public.payroll_records r where r.period_id = p.id and r.superseded_by_record_id is null) end)
      order by p.period_start desc, p.created_at desc)
    from public.payroll_periods p where p.entity_id = p_entity_id), '[]'::jsonb);
end;
$$;

create or replace function public.payroll_workspace(p_period_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  p public.payroll_periods;
  v_rows jsonb;
  v_missing jsonb;
  s public.payroll_settings;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if p.id is null then raise exception 'Payroll month not found' using errcode = 'P0002'; end if;
  perform public._payroll_require(p.entity_id, 'view_pay');
  s := public._payroll_settings(p.entity_id, p.period_start);
  select coalesce(jsonb_agg(public._payroll_row(r.id) order by e.full_name), '[]'::jsonb) into v_rows
    from public.payroll_records r join public.employees e on e.id = r.employee_id
   where r.period_id = p.id and r.superseded_by_record_id is null;
  -- Eligible employees not yet prepared (regular months only).
  select coalesce(jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name, 'branch', l.name,
                                               'location_id', e.home_location_id, 'record_status', 'not_prepared')
                            order by e.full_name), '[]'::jsonb)
    into v_missing
    from public.employees e left join public.locations l on l.id = e.home_location_id
   where p.kind = 'regular' and e.entity_id = p.entity_id and public._payroll_ineligible_reason(e.id, p.id) is null
     and not exists (select 1 from public.payroll_records r where r.period_id = p.id and r.employee_id = e.id);
  return jsonb_build_object(
    'period', to_jsonb(p),
    'entity', (select jsonb_build_object('id', en.id, 'name', en.name, 'currency', coalesce(en.default_currency, 'AED'))
                 from public.entities en where en.id = p.entity_id),
    'settings', jsonb_build_object('approval_mode', s.approval_mode, 'confirmed', s.confirmed, 'pay_day', s.pay_day,
                                   'default_payment_method', s.default_payment_method),
    'permissions', jsonb_build_object('prepare', public.payroll_can(p.entity_id, 'prepare'),
                                      'approve', public.payroll_can(p.entity_id, 'approve'),
                                      'pay', public.payroll_can(p.entity_id, 'pay'),
                                      'settings', public.payroll_can(p.entity_id, 'settings'),
                                      'single_step', public.my_role() = 'owner'
                                         or exists (select 1 from public.payroll_permissions pm where pm.user_id = auth.uid()
                                                     and pm.entity_id = p.entity_id and pm.can_single_step_approve),
                                      'user_id', auth.uid()),
    'rows', v_rows,
    'not_prepared', v_missing,
    'summary', jsonb_build_object(
      'employees', jsonb_array_length(v_rows),
      'not_prepared', jsonb_array_length(v_missing),
      'total_net', coalesce((select sum((x ->> 'net')::numeric) from jsonb_array_elements(v_rows) x), 0),
      'approved_net', coalesce((select sum((x ->> 'net')::numeric) from jsonb_array_elements(v_rows) x where x ->> 'record_status' = 'approved'), 0),
      'paid', coalesce((select sum((x ->> 'paid')::numeric) from jsonb_array_elements(v_rows) x), 0),
      'outstanding', coalesce((select sum(greatest((x ->> 'outstanding')::numeric, 0)) from jsonb_array_elements(v_rows) x
                                where x ->> 'record_status' = 'approved'), 0),
      'needs_attention', (select count(*) from jsonb_array_elements(v_rows) x
                           where exists (select 1 from jsonb_array_elements(x -> 'attention') a where a ->> 'severity' in ('blocking', 'warning'))),
      'draft', (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'record_status' = 'draft'),
      'in_review', (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'record_status' = 'in_review'),
      'approved', (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'record_status' = 'approved'),
      'published', (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'published_at' is not null)),
    'tip_pools', coalesce((select jsonb_agg(jsonb_build_object('id', tp.id, 'location', l.name, 'location_id', tp.location_id,
        'pool_start', tp.pool_start, 'pool_end', tp.pool_end, 'total_amount', tp.total_amount, 'settlement', tp.settlement,
        'method', tp.method, 'employees', (select count(*) from public.tip_allocations ta where ta.pool_id = tp.id))
        order by tp.created_at)
      from public.tip_pools tp join public.locations l on l.id = tp.location_id
     where tp.period_id = p.id and tp.voided_at is null), '[]'::jsonb),
    'exports', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'created_at', x.created_at, 'total', x.total_amount,
        'employees', x.employee_count, 'invalidated_at', x.invalidated_at, 'invalidated_reason', x.invalidated_reason)
        order by x.created_at desc)
      from public.payroll_exports x where x.period_id = p.id), '[]'::jsonb));
end;
$$;

create or replace function public.payroll_record_detail(p_record_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r public.payroll_records;
  v_entity uuid;
begin
  select * into r from public.payroll_records where id = p_record_id;
  if r.id is null then raise exception 'Record not found' using errcode = 'P0002'; end if;
  v_entity := public.payroll_period_entity(r.period_id);
  perform public._payroll_require(v_entity, 'view_pay');
  return jsonb_build_object(
    'row', public._payroll_row(r.id),
    'record', to_jsonb(r),
    'period', (select to_jsonb(p) from public.payroll_periods p where p.id = r.period_id),
    'employee', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'join_date', e.join_date,
                   'last_working_date', e.last_working_date, 'probation_end_date', e.probation_end_date,
                   'employment_status', e.employment_status, 'nationality', e.nationality)
                   from public.employees e where e.id = r.employee_id),
    'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.kind = 'info', l.kind desc, l.sort)
                         from public.payroll_lines l where l.record_id = r.id), '[]'::jsonb),
    'compensation', coalesce((select jsonb_agg(to_jsonb(v) order by v.effective_from desc)
                                from public.compensation_versions v where v.employee_id = r.employee_id), '[]'::jsonb),
    'components', coalesce((select jsonb_agg(to_jsonb(c) order by c.effective_from desc)
                              from public.compensation_components c where c.employee_id = r.employee_id), '[]'::jsonb),
    'hours', (select to_jsonb(h) from public.payroll_hours h where h.period_id = r.period_id and h.employee_id = r.employee_id),
    'adjustments', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at)
                               from public.payroll_adjustments a where a.period_id = r.period_id and a.employee_id = r.employee_id), '[]'::jsonb),
    'advances', coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('outstanding',
                               a.amount - coalesce((select sum(ar.amount) from public.advance_repayments ar
                                                      join public.payroll_records rr on rr.id = ar.record_id
                                                     where ar.advance_id = a.id and rr.superseded_by_record_id is null), 0))
                             order by a.created_at desc)
                            from public.salary_advances a where a.employee_id = r.employee_id and a.status <> 'cancelled'), '[]'::jsonb),
    'payments', coalesce((
      with recursive chain(id) as (
        select r.id union all
        select x.supersedes_record_id from public.payroll_records x join chain c on c.id = x.id where x.supersedes_record_id is not null)
      select jsonb_agg(to_jsonb(pm) order by pm.created_at) from public.payroll_payments pm where pm.record_id in (select id from chain)), '[]'::jsonb),
    'history', coalesce((
      with recursive chain(id, depth) as (
        select r.id, 0 union all
        select x.supersedes_record_id, c.depth + 1 from public.payroll_records x join chain c on c.id = x.id where x.supersedes_record_id is not null)
      select jsonb_agg(jsonb_build_object('id', x.id, 'net', x.net, 'status', x.record_status, 'approved_at', x.approved_at,
                                          'correction_reason', x.correction_reason) order by c.depth)
        from chain c join public.payroll_records x on x.id = c.id), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'at', a.changed_at, 'by', pr.full_name,
                                                           'new', a.new_value) order by a.changed_at desc)
                         from (select * from public.audit_log al
                                where al.employee_id = r.employee_id and al.action like 'payroll_%'
                                  and al.changed_at >= (select created_at from public.payroll_periods where id = r.period_id)
                                order by al.changed_at desc limit 30) a
                         left join public.profiles pr on pr.id = a.changed_by), '[]'::jsonb));
end;
$$;

-- Branch manager hours sheet: no pay amounts.
create or replace function public.payroll_hours_sheet(p_period_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare p public.payroll_periods;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if not (public.payroll_can(p.entity_id, 'prepare') or public.payroll_can(p.entity_id, 'inputs')) then
    raise exception 'No permission' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name, 'branch', l.name, 'location_id', e.home_location_id,
      'hours', to_jsonb(h), 'record_status', (select r.record_status from public.payroll_records r
                                                where r.period_id = p.id and r.employee_id = e.id and r.superseded_by_record_id is null))
      order by l.name, e.full_name)
    from public.employees e left join public.locations l on l.id = e.home_location_id
    left join public.payroll_hours h on h.period_id = p.id and h.employee_id = e.id
    where e.entity_id = p.entity_id and public._payroll_ineligible_reason(e.id, p.id) is null
      and public.payroll_can_input_for(e.id)), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------- reports
create or replace function public.payroll_report(p_period_id uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare p public.payroll_periods;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if p.id is null then raise exception 'Payroll month not found' using errcode = 'P0002'; end if;
  perform public._payroll_require(p.entity_id, 'report');
  if p_kind = 'register' then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'name', e.full_name, 'branch', l.name, 'status', r.record_status,
        'basic', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.code in ('basic', 'hourly_pay')),
        'allowances', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.kind = 'earning' and x.source_type = 'compensation_component'),
        'overtime', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.code in ('overtime', 'night_overtime', 'holiday_work')),
        'tips', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.code = 'tips'),
        'other_earnings', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.kind = 'earning'
                             and x.code not in ('basic', 'hourly_pay', 'overtime', 'night_overtime', 'holiday_work', 'tips') and x.source_type <> 'compensation_component'),
        'gross', r.gross,
        'unpaid_leave', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.code = 'unpaid_leave'),
        'advance_repayment', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.code = 'advance_repayment'),
        'other_deductions', (select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.kind = 'deduction'
                               and x.code not in ('unpaid_leave', 'advance_repayment')),
        'deductions', r.deductions, 'net', r.net, 'paid', m.paid,
        'outstanding', case when r.record_status = 'approved' then m.outstanding end) order by l.name, e.full_name)
      from public.payroll_records r join public.employees e on e.id = r.employee_id
      left join public.locations l on l.id = e.home_location_id cross join lateral public._payroll_money(r.id) m
      where r.period_id = p.id and r.superseded_by_record_id is null), '[]'::jsonb);
  elsif p_kind = 'branch_cost' then
    return coalesce((select jsonb_agg(x order by x ->> 'branch') from (
      select jsonb_build_object('branch', coalesce(l.name, 'No branch'), 'employees', count(*),
        'gross', sum(r.gross), 'deductions', sum(r.deductions), 'net', sum(r.net),
        'tips', sum((select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id and x.code = 'tips')),
        'overtime', sum((select coalesce(sum(amount), 0) from public.payroll_lines x where x.record_id = r.id
                          and x.code in ('overtime', 'night_overtime', 'holiday_work')))) as x
        from public.payroll_records r join public.employees e on e.id = r.employee_id
        left join public.locations l on l.id = e.home_location_id
       where r.period_id = p.id and r.superseded_by_record_id is null
       group by l.name) q), '[]'::jsonb);
  elsif p_kind = 'payments' then
    return coalesce((select jsonb_agg(jsonb_build_object('name', e.full_name, 'branch', l.name, 'status', r.record_status,
        'net', r.net, 'paid', m.paid, 'outstanding', case when r.record_status = 'approved' then m.outstanding end,
        'payment_status', m.payment_status, 'failed_attempts', m.failed_attempts,
        'last_payment', (select jsonb_build_object('paid_on', pm.paid_on, 'method', pm.method, 'reference', pm.reference, 'amount', pm.amount)
                           from public.payroll_payments pm where pm.record_id = r.id and pm.status = 'recorded'
                          order by pm.created_at desc limit 1)) order by e.full_name)
      from public.payroll_records r join public.employees e on e.id = r.employee_id
      left join public.locations l on l.id = e.home_location_id cross join lateral public._payroll_money(r.id) m
      where r.period_id = p.id and r.superseded_by_record_id is null), '[]'::jsonb);
  elsif p_kind = 'breakdown' then
    return jsonb_build_object(
      'tips', coalesce((select jsonb_agg(jsonb_build_object('branch', l.name, 'pool_start', tp.pool_start, 'pool_end', tp.pool_end,
          'amount', tp.total_amount, 'settlement', tp.settlement, 'method', tp.method,
          'allocated', (select sum(amount) from public.tip_allocations ta where ta.pool_id = tp.id)) order by l.name)
        from public.tip_pools tp join public.locations l on l.id = tp.location_id
        where tp.period_id = p.id and tp.voided_at is null), '[]'::jsonb),
      'advances', coalesce((select jsonb_agg(jsonb_build_object('name', e.full_name, 'amount', a.amount, 'disbursed_on', a.disbursed_on,
          'repaid_this_month', (select coalesce(sum(x.amount), 0) from public.payroll_lines x join public.payroll_records r on r.id = x.record_id
                                  where r.period_id = p.id and r.superseded_by_record_id is null and x.code = 'advance_repayment' and x.source_id = a.id),
          'outstanding', a.amount - coalesce((select sum(ar.amount) from public.advance_repayments ar join public.payroll_records rr on rr.id = ar.record_id
                                               where ar.advance_id = a.id and rr.superseded_by_record_id is null), 0),
          'status', a.status) order by e.full_name)
        from public.salary_advances a join public.employees e on e.id = a.employee_id
        where a.entity_id = p.entity_id and a.status <> 'cancelled' and a.disbursed_on <= p.period_end), '[]'::jsonb),
      'deductions', coalesce((select jsonb_agg(jsonb_build_object('code', q.code, 'label', q.label, 'employees', q.n, 'amount', q.total) order by q.total desc)
        from (select x.code, min(x.label) as label, count(distinct r.employee_id) as n, sum(x.amount) as total
                from public.payroll_lines x join public.payroll_records r on r.id = x.record_id
               where r.period_id = p.id and r.superseded_by_record_id is null and x.kind = 'deduction'
               group by x.code) q), '[]'::jsonb));
  end if;
  raise exception 'Unknown report' using errcode = '22023';
end;
$$;

-- -------------------------------------------------------- employee payslips
create or replace function public.payroll_my_payslips()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_emp uuid := public.my_employee_id();
begin
  if v_emp is null or not public.is_active_user() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('record_id', r.id, 'period_start', p.period_start, 'period_end', p.period_end,
      'label', p.label, 'kind', p.kind, 'gross', r.gross, 'deductions', r.deductions, 'net', r.net, 'published_at', r.published_at,
      'is_correction', r.supersedes_record_id is not null, 'superseded', r.superseded_by_record_id is not null,
      'currency', coalesce(en.default_currency, 'AED'))
      order by p.period_start desc, r.created_at desc)
    from public.payroll_records r join public.payroll_periods p on p.id = r.period_id
    join public.entities en on en.id = p.entity_id
    where r.employee_id = v_emp and r.published_at is not null), '[]'::jsonb);
end;
$$;

create or replace function public.payroll_my_payslip(p_record_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r public.payroll_records;
  v_emp uuid := public.my_employee_id();
begin
  select * into r from public.payroll_records where id = p_record_id;
  if r.id is null or r.employee_id is distinct from v_emp or r.published_at is null or not public.is_active_user() then
    raise exception 'Payslip not found' using errcode = 'P0002';
  end if;
  perform public._payroll_audit(public.payroll_period_entity(r.period_id), 'payroll_records', r.id, 'payslip_viewed', null, null, r.employee_id);
  return jsonb_build_object(
    'record', jsonb_build_object('id', r.id, 'gross', r.gross, 'deductions', r.deductions, 'net', r.net,
                                 'published_at', r.published_at, 'is_correction', r.supersedes_record_id is not null,
                                 'correction_reason', r.correction_reason, 'superseded', r.superseded_by_record_id is not null),
    'period', (select jsonb_build_object('start', p.period_start, 'end', p.period_end, 'label', p.label, 'kind', p.kind)
                 from public.payroll_periods p where p.id = r.period_id),
    'company', (select jsonb_build_object('name', en.name, 'currency', coalesce(en.default_currency, 'AED'),
                  'note', (public._payroll_settings(en.id, current_date)).payslip_note)
                  from public.entities en where en.id = public.payroll_period_entity(r.period_id)),
    'employee', (select jsonb_build_object('name', e.full_name, 'position', pos.title, 'branch', l.name, 'join_date', e.join_date)
                   from public.employees e left join public.positions pos on pos.id = e.position_id
                   left join public.locations l on l.id = e.home_location_id where e.id = r.employee_id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'code', l.code, 'label', l.label, 'quantity', l.quantity,
                          'amount', l.amount, 'explanation', l.explanation) order by l.kind = 'info', l.kind desc, l.sort)
                         from public.payroll_lines l where l.record_id = r.id), '[]'::jsonb),
    'payments', coalesce((
      with recursive chain(id) as (
        select r.id union all
        select x.supersedes_record_id from public.payroll_records x join chain c on c.id = x.id where x.supersedes_record_id is not null)
      select jsonb_agg(jsonb_build_object('amount', pm.amount, 'paid_on', pm.paid_on, 'method', pm.method) order by pm.paid_on)
        from public.payroll_payments pm where pm.record_id in (select id from chain) and pm.status = 'recorded'), '[]'::jsonb));
end;
$$;

-- ------------------------------------------------------------------ grants
do $$
declare f text;
begin
  foreach f in array array[
    'payroll_tip_preview(uuid, uuid, date, date, numeric, text, text, uuid[])',
    'payroll_tip_confirm(uuid, uuid, date, date, numeric, text, text, uuid[], text)',
    'payroll_tip_void(uuid, text)', 'payroll_set_role_points(uuid, numeric)',
    'payroll_create_advance(uuid, numeric, date, text, date, integer, text)', 'payroll_cancel_advance(uuid, text)',
    'payroll_set_compensation(uuid, date, text, numeric, numeric, boolean, text)',
    'payroll_add_component(uuid, text, text, text, numeric, boolean, date, date, text)',
    'payroll_end_component(uuid, date, text)', 'payroll_set_last_working_date(uuid, date, text)',
    'payroll_gratuity_preview(uuid, date)', 'payroll_save_settings(uuid, date, jsonb)', 'payroll_get_settings(uuid)',
    'payroll_set_permission(uuid, uuid, text, boolean)', 'payroll_periods_list(uuid)', 'payroll_workspace(uuid)',
    'payroll_record_detail(uuid)', 'payroll_hours_sheet(uuid)', 'payroll_report(uuid, text)',
    'payroll_my_payslips()', 'payroll_my_payslip(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
