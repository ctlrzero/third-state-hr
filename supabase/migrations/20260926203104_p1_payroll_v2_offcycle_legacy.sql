-- ============================================================
-- Payroll v2 — off-cycle runs pay only their adjustments; legacy payroll
-- becomes read-only; the Pay card writes effective-dated versions.
-- ============================================================
create or replace function public._payroll_calculate(p_record_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  r public.payroll_records;
  p public.payroll_periods;
  e public.employees;
  s public.payroll_settings;
  h public.payroll_hours;
  v record;
  c record;
  lv record;
  tp record;
  adj record;
  adv record;
  v_att jsonb := '[]'::jsonb;
  v_dim numeric;
  v_win_start date;
  v_win_end date;
  v_seg_start date;
  v_seg_end date;
  v_days integer;
  v_amount numeric;
  v_full boolean;
  v_latest public.compensation_versions;
  v_hourly_equiv numeric;
  v_day date;
  v_daily numeric;
  v_unpaid_total numeric;
  v_unpaid_days numeric;
  v_ordinal integer;
  v_year_start date;
  v_fraction numeric;
  v_outstanding numeric;
  v_gross numeric;
  v_ded numeric;
  v_capped numeric;
  v_sort smallint := 0;
  v_ccy text;
  v_off boolean;
begin
  select * into r from public.payroll_records where id = p_record_id for update;
  if r.id is null then
    raise exception 'Payroll record not found' using errcode = 'P0002';
  end if;
  if r.record_status <> 'draft' then
    raise exception 'Only draft records can be recalculated (this one is %)', r.record_status using errcode = '22023';
  end if;
  select * into p from public.payroll_periods where id = r.period_id;
  select * into e from public.employees where id = r.employee_id;
  s := public._payroll_settings(p.entity_id, p.period_start);
  select coalesce(default_currency, 'AED') into v_ccy from public.entities where id = p.entity_id;

  delete from public.payroll_lines where record_id = r.id;

  v_dim := case when s.day_rate_basis = 'fixed_30' then 30 else (p.period_end - p.period_start + 1) end;
  v_win_start := greatest(p.period_start, coalesce(e.join_date, p.period_start));
  v_win_end := least(p.period_end, coalesce(e.last_working_date, p.period_end));
  v_full := v_win_start = p.period_start and v_win_end = p.period_end;
  -- Off-cycle runs (final settlements, one-off payments) contain only the
  -- adjustments added to them; salary stays in the monthly payroll.
  v_off := p.kind = 'off_cycle';

  if not v_off and e.join_date is null then
    v_att := v_att || jsonb_build_object('code', 'no_join_date', 'severity', 'warning',
      'message', 'No joining date on file; treated as employed for the whole month.');
  end if;
  if not v_off and v_win_end < v_win_start then
    v_att := v_att || jsonb_build_object('code', 'not_employed', 'severity', 'blocking',
      'message', 'Not employed during this period.');
  end if;
  if not v_off and e.join_date between p.period_start + 1 and p.period_end then
    v_att := v_att || jsonb_build_object('code', 'joiner', 'severity', 'info',
      'message', format('Joined on %s; pay prorated.', public._payroll_fmt_date(e.join_date)));
  end if;
  if not v_off and e.last_working_date between p.period_start and p.period_end - 1 then
    v_att := v_att || jsonb_build_object('code', 'leaver', 'severity', 'info',
      'message', format('Last working day %s; pay prorated. Add any final-settlement items as adjustments.',
                        public._payroll_fmt_date(e.last_working_date)));
  end if;

  v_latest := public._payroll_comp_on(e.id, v_win_end);
  if not v_off and v_latest.id is null then
    v_att := v_att || jsonb_build_object('code', 'no_pay', 'severity', 'blocking',
      'message', 'No salary or hourly rate set. Set pay on the employee''s Pay card.');
  end if;

  select * into h from public.payroll_hours where period_id = p.id and employee_id = e.id;

  -- ------------------------------------------------------------ basic pay
  if not v_off and v_win_end >= v_win_start then
    for v in
      select cv.*, coalesce(lead(cv.effective_from) over (order by cv.effective_from) - 1, date '9999-12-31') as effective_to
        from public.compensation_versions cv where cv.employee_id = e.id
    loop
      v_seg_start := greatest(v_win_start, v.effective_from);
      v_seg_end := least(v_win_end, v.effective_to);
      continue when v_seg_end < v_seg_start or v.pay_type <> 'monthly';
      v_days := v_seg_end - v_seg_start + 1;
      if v_seg_start = p.period_start and v_seg_end = p.period_end then
        v_amount := v.basic_monthly;
      else
        v_amount := round(v.basic_monthly * least(v_days, v_dim) / v_dim, 2);
      end if;
      v_sort := v_sort + 1;
      insert into public.payroll_lines (record_id, kind, code, label, quantity, rate, amount, source_type, source_id, explanation, sort)
      values (r.id, 'earning', 'basic', 'Basic salary', v_days, v.basic_monthly, v_amount, 'compensation_version', v.id,
        case when v_seg_start = p.period_start and v_seg_end = p.period_end
             then format('Monthly basic %s %s, full month.', v_ccy, public._payroll_fmt(v.basic_monthly))
             else format('Monthly basic %s %s × %s of %s days (%s–%s).', v_ccy, public._payroll_fmt(v.basic_monthly),
                         v_days, v_dim, public._payroll_fmt_date(v_seg_start), public._payroll_fmt_date(v_seg_end)) end,
        v_sort);
    end loop;

    -- Hourly regular pay (rate in force at the end of the window).
    if v_latest.pay_type = 'hourly' then
      if h.id is null then
        v_att := v_att || jsonb_build_object('code', 'no_hours', 'severity', 'blocking',
          'message', 'Hourly employee with no hours entered for this month.');
      elsif h.status = 'pending' then
        v_att := v_att || jsonb_build_object('code', 'hours_pending', 'severity', 'blocking',
          'message', format('%s regular hours awaiting confirmation (≈ %s %s).', h.regular_hours, v_ccy,
                            public._payroll_fmt(round(h.regular_hours * v_latest.hourly_rate, 2))),
          'impact', round(h.regular_hours * v_latest.hourly_rate, 2));
      elsif h.regular_hours > 0 then
        v_sort := v_sort + 1;
        insert into public.payroll_lines (record_id, kind, code, label, quantity, rate, amount, source_type, source_id, explanation, sort)
        values (r.id, 'earning', 'hourly_pay', 'Hours worked', h.regular_hours, v_latest.hourly_rate,
          round(h.regular_hours * v_latest.hourly_rate, 2), 'payroll_hours', h.id,
          format('%s hours × %s %s per hour.', h.regular_hours, v_ccy, public._payroll_fmt(v_latest.hourly_rate)), v_sort);
      end if;
    end if;

    -- ------------------------------------------------------- allowances
    for c in
      select * from public.compensation_components cc
       where cc.employee_id = e.id and cc.effective_from <= v_win_end
         and (cc.effective_to is null or cc.effective_to >= v_win_start)
       order by cc.kind, cc.code
    loop
      v_seg_start := greatest(v_win_start, c.effective_from);
      v_seg_end := least(v_win_end, coalesce(c.effective_to, v_win_end));
      v_days := v_seg_end - v_seg_start + 1;
      if not c.prorate or (v_seg_start = p.period_start and v_seg_end = p.period_end) then
        v_amount := c.monthly_amount;
      else
        v_amount := round(c.monthly_amount * least(v_days, v_dim) / v_dim, 2);
      end if;
      v_sort := v_sort + 1;
      insert into public.payroll_lines (record_id, kind, code, label, quantity, rate, amount, source_type, source_id, explanation, sort)
      values (r.id, c.kind, c.code, c.label, v_days, c.monthly_amount, v_amount, 'compensation_component', c.id,
        case when v_amount = c.monthly_amount
             then format('Recurring %s %s %s per month.', case when c.kind = 'earning' then 'allowance' else 'deduction' end,
                         v_ccy, public._payroll_fmt(c.monthly_amount))
             else format('%s %s per month × %s of %s days.', v_ccy, public._payroll_fmt(c.monthly_amount), v_days, v_dim) end,
        v_sort);
    end loop;
  end if;

  -- ------------------------------------------------------------- overtime
  if not v_off and v_latest.id is not null then
    v_hourly_equiv := case when v_latest.pay_type = 'hourly' then v_latest.hourly_rate
                           else round(v_latest.basic_monthly / s.overtime_hour_divisor, 4) end;
    if h.id is null then
      if v_latest.pay_type = 'monthly' then
        v_att := v_att || jsonb_build_object('code', 'no_timesheet', 'severity', 'info',
          'message', 'No timesheet: salary paid for the employed days; no overtime included.');
      end if;
    elsif (h.overtime_hours + h.night_overtime_hours + h.holiday_hours) > 0 then
      if not v_latest.overtime_eligible then
        v_att := v_att || jsonb_build_object('code', 'ot_not_eligible', 'severity', 'warning',
          'message', format('%s overtime hours recorded, but this employee is not overtime-eligible. Nothing added.',
                            h.overtime_hours + h.night_overtime_hours + h.holiday_hours));
      elsif h.status = 'pending' then
        v_amount := round(h.overtime_hours * v_hourly_equiv * s.overtime_multiplier, 2)
                  + round(h.night_overtime_hours * v_hourly_equiv * s.night_overtime_multiplier, 2)
                  + round(h.holiday_hours * v_hourly_equiv * s.holiday_multiplier, 2);
        v_att := v_att || jsonb_build_object('code', 'overtime_pending', 'severity', 'warning',
          'message', format('Overtime awaiting confirmation (≈ %s %s). Confirm hours to include it.', v_ccy, public._payroll_fmt(v_amount)),
          'impact', v_amount);
      else
        if h.overtime_hours > 0 then
          v_sort := v_sort + 1;
          insert into public.payroll_lines (record_id, kind, code, label, quantity, rate, amount, source_type, source_id, explanation, sort)
          values (r.id, 'earning', 'overtime', 'Overtime', h.overtime_hours, round(v_hourly_equiv * s.overtime_multiplier, 4),
            round(h.overtime_hours * v_hourly_equiv * s.overtime_multiplier, 2), 'payroll_hours', h.id,
            format('%s h × %s %s hourly %s × %s.', h.overtime_hours, v_ccy, public._payroll_fmt(v_hourly_equiv),
                   case when v_latest.pay_type = 'hourly' then 'rate' else format('(basic ÷ %s)', s.overtime_hour_divisor) end,
                   s.overtime_multiplier), v_sort);
        end if;
        if h.night_overtime_hours > 0 then
          v_sort := v_sort + 1;
          insert into public.payroll_lines (record_id, kind, code, label, quantity, rate, amount, source_type, source_id, explanation, sort)
          values (r.id, 'earning', 'night_overtime', 'Night overtime', h.night_overtime_hours,
            round(v_hourly_equiv * s.night_overtime_multiplier, 4),
            round(h.night_overtime_hours * v_hourly_equiv * s.night_overtime_multiplier, 2), 'payroll_hours', h.id,
            format('%s h × %s %s × %s (10 pm–4 am).', h.night_overtime_hours, v_ccy, public._payroll_fmt(v_hourly_equiv),
                   s.night_overtime_multiplier), v_sort);
        end if;
        if h.holiday_hours > 0 then
          v_sort := v_sort + 1;
          insert into public.payroll_lines (record_id, kind, code, label, quantity, rate, amount, source_type, source_id, explanation, sort)
          values (r.id, 'earning', 'holiday_work', 'Rest day / public holiday work', h.holiday_hours,
            round(v_hourly_equiv * s.holiday_multiplier, 4),
            round(h.holiday_hours * v_hourly_equiv * s.holiday_multiplier, 2), 'payroll_hours', h.id,
            format('%s h × %s %s × %s.', h.holiday_hours, v_ccy, public._payroll_fmt(v_hourly_equiv), s.holiday_multiplier), v_sort);
        end if;
      end if;
    end if;
  end if;

  -- --------------------------------------------------------- unpaid leave
  -- One line per approved leave request; days are only those inside this
  -- period's employed window, so the same day can never be deducted twice.
  if not v_off and v_latest.pay_type = 'monthly' and v_win_end >= v_win_start then
    for lv in
      select lr.id, lr.start_date, lr.end_date, lt.name, lt.payroll_treatment,
             coalesce(lt.full_pay_days, 0) as full_days, coalesce(lt.half_pay_days, 0) as half_days,
             lr.leave_type_id
        from public.leave_requests lr
        join public.leave_types lt on lt.id = lr.leave_type_id
       where lr.employee_id = e.id and lr.status = 'approved'
         and lt.payroll_treatment in ('unpaid', 'tiered')
         and lr.start_date <= v_win_end and lr.end_date >= v_win_start
       order by lr.start_date
    loop
      v_unpaid_total := 0;
      v_unpaid_days := 0;
      for v_day in select generate_series(greatest(lv.start_date, v_win_start), least(lv.end_date, v_win_end), interval '1 day')::date loop
        if lv.payroll_treatment = 'unpaid' then
          v_fraction := 1;
        elsif e.probation_end_date is not null and v_day <= e.probation_end_date then
          -- Sick leave during probation is unpaid (Decree-Law 33/2021 Art. 31).
          v_fraction := 1;
        else
          -- Service year that contains this day (from the joining anniversary).
          v_year_start := coalesce(e.join_date, date '2000-01-01');
          while v_year_start + interval '1 year' <= v_day loop
            v_year_start := (v_year_start + interval '1 year')::date;
          end loop;
          select count(*) into v_ordinal
            from public.leave_requests lr2,
                 generate_series(greatest(lr2.start_date, v_year_start), least(lr2.end_date, v_day), interval '1 day') g
           where lr2.employee_id = e.id and lr2.leave_type_id = lv.leave_type_id and lr2.status = 'approved'
             and lr2.start_date <= v_day and lr2.end_date >= v_year_start;
          v_fraction := case when v_ordinal <= lv.full_days then 0
                             when v_ordinal <= lv.full_days + lv.half_days then 0.5
                             else 1 end;
        end if;
        continue when v_fraction = 0;
        v_daily := public._payroll_fixed_monthly_on(e.id, v_day, s.unpaid_leave_basis = 'basic_and_allowances') / v_dim;
        v_unpaid_total := v_unpaid_total + v_daily * v_fraction;
        v_unpaid_days := v_unpaid_days + v_fraction;
      end loop;
      if v_unpaid_days > 0 then
        v_sort := v_sort + 1;
        insert into public.payroll_lines (record_id, kind, code, label, quantity, rate, amount, source_type, source_id, explanation, sort)
        values (r.id, 'deduction', 'unpaid_leave', lv.name, v_unpaid_days, round(v_unpaid_total / v_unpaid_days, 4),
          round(v_unpaid_total, 2), 'leave_request', lv.id,
          format('%s unpaid day(s) %s–%s × daily rate (%s ÷ %s days)%s.', v_unpaid_days,
                 public._payroll_fmt_date(greatest(lv.start_date, v_win_start)), public._payroll_fmt_date(least(lv.end_date, v_win_end)),
                 case when s.unpaid_leave_basis = 'basic' then 'basic' else 'basic + allowances' end, v_dim,
                 case when lv.payroll_treatment = 'tiered' then '; sick-leave tiers applied' else '' end), v_sort);
      end if;
    end loop;
  end if;

  -- ------------------------------------------------------------------ tips
  for tp in
    select pl.id, pl.settlement, pl.pool_start, pl.pool_end, pl.method, l.name as location_name, ta.amount
      from public.tip_allocations ta
      join public.tip_pools pl on pl.id = ta.pool_id
      join public.locations l on l.id = pl.location_id
     where not v_off and pl.period_id = p.id and pl.voided_at is null and ta.employee_id = e.id and ta.amount > 0
  loop
    v_sort := v_sort + 1;
    insert into public.payroll_lines (record_id, kind, code, label, amount, source_type, source_id, explanation, sort)
    values (r.id, case when tp.settlement = 'payroll' then 'earning' else 'info' end,
      case when tp.settlement = 'payroll' then 'tips' else 'tips_cash' end,
      case when tp.settlement = 'payroll' then 'Tips' else 'Tips paid in cash' end,
      tp.amount, 'tip_pool', tp.id,
      format('%s pool %s–%s, %s split%s.', tp.location_name, public._payroll_fmt_date(tp.pool_start),
             public._payroll_fmt_date(tp.pool_end), replace(tp.method, '_', ' × '),
             case when tp.settlement = 'cash_paid' then '; already paid in cash, not added to net pay' else '' end), v_sort);
  end loop;

  -- ----------------------------------------------------------- adjustments
  for adj in
    select * from public.payroll_adjustments a
     where a.period_id = p.id and a.employee_id = e.id and a.voided_at is null
     order by a.created_at
  loop
    v_sort := v_sort + 1;
    insert into public.payroll_lines (record_id, kind, code, label, amount, source_type, source_id, explanation, sort)
    values (r.id, adj.kind, adj.code, initcap(replace(adj.code, '_', ' ')), adj.amount, 'payroll_adjustment', adj.id,
      adj.reason || case when adj.allocation = 'distributed' then ' (share of a distributed total)' else '' end, v_sort);
  end loop;

  -- -------------------------------------------------------------- advances
  for adv in
    select a.* from public.salary_advances a
     where not v_off and a.employee_id = e.id and a.status = 'active'
  loop
    if adv.disbursement_method = 'payroll' and adv.disbursed_on between p.period_start and p.period_end then
      v_sort := v_sort + 1;
      insert into public.payroll_lines (record_id, kind, code, label, amount, source_type, source_id, explanation, sort)
      values (r.id, 'earning', 'advance_paid', 'Salary advance', adv.amount, 'salary_advance', adv.id,
        format('Advance paid through payroll on %s: %s', public._payroll_fmt_date(adv.disbursed_on), adv.reason), v_sort);
    end if;
    continue when adv.repayment_start > p.period_end;
    select adv.amount - coalesce(sum(ar.amount), 0) into v_outstanding
      from public.advance_repayments ar
      join public.payroll_records rr on rr.id = ar.record_id
     where ar.advance_id = adv.id and rr.superseded_by_record_id is null and rr.period_id <> p.id;
    continue when v_outstanding <= 0;
    v_amount := least(adv.instalment_amount, v_outstanding);
    v_sort := v_sort + 1;
    insert into public.payroll_lines (record_id, kind, code, label, amount, source_type, source_id, explanation, sort)
    values (r.id, 'deduction', 'advance_repayment', 'Advance repayment', v_amount, 'salary_advance', adv.id,
      format('Instalment of %s %s; %s %s outstanding before this month, %s after.', v_ccy, public._payroll_fmt(v_amount),
             v_ccy, public._payroll_fmt(v_outstanding), public._payroll_fmt(v_outstanding - v_amount)), v_sort);
  end loop;

  -- ---------------------------------------------------------------- totals
  select coalesce(sum(amount) filter (where kind = 'earning'), 0),
         coalesce(sum(amount) filter (where kind = 'deduction'), 0),
         coalesce(sum(amount) filter (where kind = 'deduction' and code <> 'unpaid_leave'), 0)
    into v_gross, v_ded, v_capped
    from public.payroll_lines where record_id = r.id;

  if v_gross - v_ded < 0 then
    v_att := v_att || jsonb_build_object('code', 'negative_net', 'severity', 'blocking',
      'message', format('Deductions exceed earnings by %s %s. Reduce or defer a deduction.', v_ccy, public._payroll_fmt(v_ded - v_gross)));
  elsif v_capped > round((v_gross - (v_ded - v_capped)) * s.max_deduction_pct / 100, 2) then
    v_att := v_att || jsonb_build_object('code', 'deduction_cap', 'severity', 'warning',
      'message', format('Deductions (excluding unpaid leave) are %s %s, above the %s%% limit of pay.', v_ccy,
                        public._payroll_fmt(v_capped), s.max_deduction_pct));
  end if;
  if v_off then
    v_att := v_att || jsonb_build_object('code', 'off_cycle', 'severity', 'info',
      'message', 'Off-cycle payroll: only the adjustments added here are paid.');
  end if;
  if not s.confirmed then
    v_att := v_att || jsonb_build_object('code', 'settings_unconfirmed', 'severity', 'info',
      'message', 'Payroll settings still use the defaults. Review them in Payroll Settings.');
  end if;

  update public.payroll_records
     set gross = v_gross, deductions = v_ded, net = v_gross - v_ded,
         attention = v_att, calc_version = calc_version + 1,
         calculated_at = now(), calculated_by = auth.uid()
   where id = r.id;
end;
$$;
revoke all on function public._payroll_calculate(uuid) from public, anon, authenticated;

-- ------------------------------------------------ legacy payroll: read-only
-- Payroll v2 replaces the old run screen. Old runs and payslips stay
-- readable; the direct UPDATE that let a client skip status steps is closed.
revoke insert, update, delete on table public.payroll_runs from authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'add_employees_to_payroll_run(uuid)', 'create_payroll_revision(uuid)', 'delete_payslip_deduction(uuid)',
    'delete_timesheet_entry(uuid)', 'delete_tips_pool(uuid)',
    'materialize_payroll_from_payable_shifts(uuid, uuid, uuid[])', 'override_materialized_payable_shift(uuid, integer, text)',
    'record_payslip_deduction(uuid, uuid, text, numeric, text)', 'record_timesheet_entry(uuid, uuid, numeric, numeric, numeric, text)',
    'record_tips_pool(uuid, uuid, numeric, text)', 'run_payroll_calculation(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- ------------------------------------------ Pay card → effective-dated pay
-- The employee profile's Pay drawer keeps calling set_employee_compensation;
-- it now records a compensation version (from the first of the current
-- month, or the joining date for a first rate) so payroll v2 sees it.
create or replace function public.set_employee_compensation(p_employee_id uuid, p_pay_type text, p_pay_rate numeric,
  p_overtime_multiplier numeric default null, p_holiday_multiplier numeric default null, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  e public.employees;
  v_from date;
  v_cur public.compensation_versions;
begin
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  v_cur := public._payroll_comp_on(p_employee_id, (now() at time zone 'Asia/Dubai')::date);
  v_from := case when not exists (select 1 from public.compensation_versions where employee_id = p_employee_id)
                 then coalesce(e.join_date, date_trunc('month', (now() at time zone 'Asia/Dubai'))::date)
                 else greatest(date_trunc('month', (now() at time zone 'Asia/Dubai'))::date, coalesce(e.join_date, date '2000-01-01')) end;
  perform public.payroll_set_compensation(p_employee_id, v_from, p_pay_type,
    case when p_pay_type = 'monthly' then p_pay_rate end, case when p_pay_type = 'hourly' then p_pay_rate end,
    coalesce(v_cur.overtime_eligible, true), p_reason);
end;
$fn$;
revoke all on function public.set_employee_compensation(uuid, text, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.set_employee_compensation(uuid, text, numeric, numeric, numeric, text) to authenticated;
