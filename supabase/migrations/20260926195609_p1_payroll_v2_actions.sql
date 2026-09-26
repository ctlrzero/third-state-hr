-- ============================================================
-- Payroll v2 — actions. Every action accepts one employee/record or a
-- selection and returns a summary: {ok, processed, skipped[{id,name,reason}], total}.
-- Preview (p_preview = true) returns the same summary without writing.
-- ============================================================

create or replace function public._payroll_audit(p_entity_id uuid, p_table text, p_record_id uuid, p_action text,
                                                 p_old jsonb, p_new jsonb, p_employee_id uuid default null)
returns void language sql security definer set search_path to '' as $$
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values (p_table, p_record_id, auth.uid(), p_action, p_old, p_new, p_entity_id, p_employee_id);
$$;
revoke all on function public._payroll_audit(uuid, text, uuid, text, jsonb, jsonb, uuid) from public, anon, authenticated;

-- Payments across a record and every record it corrects.
create or replace function public._payroll_money(p_record_id uuid)
returns table (paid numeric, outstanding numeric, payment_status text, failed_attempts integer)
language sql stable security definer set search_path to '' as $$
  with recursive chain(id) as (
    select p_record_id
    union all
    select r.supersedes_record_id from public.payroll_records r join chain c on c.id = r.id
     where r.supersedes_record_id is not null
  ),
  pay as (
    select coalesce(sum(amount) filter (where status = 'recorded'), 0) as paid,
           count(*) filter (where status = 'failed')::integer as failed
      from public.payroll_payments where record_id in (select id from chain)
  )
  select pay.paid,
         r.net - pay.paid,
         case when r.record_status <> 'approved' then 'not_approved'
              when r.net - pay.paid < 0 then 'overpaid'
              when r.net - pay.paid = 0 and (pay.paid > 0 or r.net = 0) then 'paid'
              when pay.paid > 0 then 'partial'
              when pay.failed > 0 then 'failed'
              else 'unpaid' end,
         pay.failed
    from public.payroll_records r, pay where r.id = p_record_id;
$$;
revoke all on function public._payroll_money(uuid) from public, anon, authenticated;

create or replace function public._payroll_require(p_entity_id uuid, p_cap text)
returns void language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.payroll_can(p_entity_id, p_cap) then
    raise exception 'You do not have payroll permission to do this (%).', p_cap using errcode = '42501';
  end if;
end;
$$;
revoke all on function public._payroll_require(uuid, text) from public, anon, authenticated;

-- Eligibility of an employee for a period: null when eligible, else the reason.
create or replace function public._payroll_ineligible_reason(p_employee_id uuid, p_period_id uuid)
returns text language sql stable security definer set search_path to '' as $$
  select case
    when e.id is null then 'Employee not found'
    when e.entity_id <> p.entity_id then 'Belongs to another company'
    when e.employment_status in ('candidate', 'pre_boarding') then 'Not activated yet'
    when e.join_date is not null and e.join_date > p.period_end then 'Joins after this month'
    when e.last_working_date is not null and e.last_working_date < p.period_start then 'Left before this month'
    when e.employment_status = 'inactive' and e.last_working_date is null then 'Inactive with no last working day'
    else null end
  from public.payroll_periods p left join public.employees e on e.id = p_employee_id
  where p.id = p_period_id;
$$;
revoke all on function public._payroll_ineligible_reason(uuid, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------ workspace
create or replace function public.payroll_open_period(p_entity_id uuid, p_month date)
returns uuid language plpgsql security definer set search_path to '' as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_id uuid;
begin
  perform public._payroll_require(p_entity_id, 'prepare');
  select id into v_id from public.payroll_periods where entity_id = p_entity_id and kind = 'regular' and period_start = v_start;
  if v_id is null then
    insert into public.payroll_periods (entity_id, kind, period_start, period_end, created_by)
    values (p_entity_id, 'regular', v_start, (v_start + interval '1 month' - interval '1 day')::date, auth.uid())
    on conflict do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.payroll_periods where entity_id = p_entity_id and kind = 'regular' and period_start = v_start;
    else
      perform public._payroll_audit(p_entity_id, 'payroll_periods', v_id, 'payroll_period_opened', null,
        jsonb_build_object('period_start', v_start), null);
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.payroll_open_off_cycle(p_entity_id uuid, p_pay_date date, p_label text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_id uuid;
begin
  perform public._payroll_require(p_entity_id, 'prepare');
  if nullif(btrim(p_label), '') is null then
    raise exception 'Give the off-cycle payroll a label (e.g. "Final settlement – Ali")' using errcode = '22023';
  end if;
  insert into public.payroll_periods (entity_id, kind, period_start, period_end, label, created_by)
  values (p_entity_id, 'off_cycle', p_pay_date, p_pay_date, btrim(p_label), auth.uid())
  returning id into v_id;
  perform public._payroll_audit(p_entity_id, 'payroll_periods', v_id, 'payroll_off_cycle_opened', null,
    jsonb_build_object('pay_date', p_pay_date, 'label', p_label), null);
  return v_id;
end;
$$;

-- ------------------------------------------------------------- prepare
create or replace function public.payroll_prepare(p_period_id uuid, p_employee_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  p public.payroll_periods;
  e record;
  r public.payroll_records;
  v_reason text;
  v_created integer := 0;
  v_recalc integer := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if p.id is null then raise exception 'Payroll month not found' using errcode = 'P0002'; end if;
  perform public._payroll_require(p.entity_id, 'prepare');

  for e in
    select em.id, em.full_name from public.employees em
     where (p_employee_ids is null and em.entity_id = p.entity_id)
        or em.id = any(p_employee_ids)
     order by em.full_name
  loop
    select * into r from public.payroll_records
     where period_id = p.id and employee_id = e.id and superseded_by_record_id is null;
    if r.id is null then
      v_reason := public._payroll_ineligible_reason(e.id, p.id);
      if p.kind = 'off_cycle' and v_reason in ('Left before this month', 'Joins after this month') then
        v_reason := null;  -- off-cycle runs (final settlements) may include leavers
      end if;
      if v_reason is not null then
        if p_employee_ids is not null or v_reason not in ('Joins after this month', 'Left before this month', 'Belongs to another company') then
          v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.full_name, 'reason', v_reason);
        end if;
        continue;
      end if;
      if p.kind = 'off_cycle' and p_employee_ids is null then
        continue;  -- off-cycle runs only include explicitly chosen employees
      end if;
      insert into public.payroll_records (period_id, employee_id) values (p.id, e.id) returning * into r;
      v_created := v_created + 1;
    end if;
    if r.record_status <> 'draft' then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.full_name,
        'reason', format('Already %s; return it to draft to change it', replace(r.record_status, '_', ' ')));
      continue;
    end if;
    perform public._payroll_calculate(r.id);
    v_recalc := v_recalc + 1;
  end loop;

  perform public._payroll_audit(p.entity_id, 'payroll_periods', p.id, 'payroll_prepared', null,
    jsonb_build_object('created', v_created, 'calculated', v_recalc, 'selection', p_employee_ids), null);
  return jsonb_build_object('ok', true, 'created', v_created, 'processed', v_recalc, 'skipped', v_skipped,
    'total', (select coalesce(sum(net), 0) from public.payroll_records where period_id = p.id and superseded_by_record_id is null));
end;
$$;

create or replace function public.payroll_recalculate(p_record_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r record;
  v_done integer := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  for r in
    select pr.id, pr.record_status, pr.superseded_by_record_id, pp.entity_id, e.full_name
      from public.payroll_records pr join public.payroll_periods pp on pp.id = pr.period_id
      join public.employees e on e.id = pr.employee_id
     where pr.id = any(p_record_ids)
  loop
    if not public.payroll_can(r.entity_id, 'prepare') then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', 'No permission');
    elsif r.superseded_by_record_id is not null then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', 'Replaced by a correction');
    elsif r.record_status <> 'draft' then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name,
        'reason', format('Already %s; return it to draft first', replace(r.record_status, '_', ' ')));
    else
      perform public._payroll_calculate(r.id);
      v_done := v_done + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'processed', v_done, 'skipped', v_skipped);
end;
$$;

-- Recalculate the live draft record of one employee in a period, if any (internal).
create or replace function public._payroll_refresh(p_period_id uuid, p_employee_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare v_id uuid;
begin
  select id into v_id from public.payroll_records
   where period_id = p_period_id and employee_id = p_employee_id
     and superseded_by_record_id is null and record_status = 'draft';
  if v_id is not null then
    perform public._payroll_calculate(v_id);
  end if;
end;
$$;
revoke all on function public._payroll_refresh(uuid, uuid) from public, anon, authenticated;

-- Blocks input changes for employees whose record is frozen.
create or replace function public._payroll_frozen_reason(p_period_id uuid, p_employee_id uuid)
returns text language sql stable security definer set search_path to '' as $$
  select case when record_status = 'approved' then 'Record is approved; return it to draft (or create a correction) to change it'
              when record_status = 'in_review' then 'Record is in review; return it to draft to change it'
              end
    from public.payroll_records
   where period_id = p_period_id and employee_id = p_employee_id and superseded_by_record_id is null;
$$;
revoke all on function public._payroll_frozen_reason(uuid, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------ hours
create or replace function public.payroll_set_hours(p_period_id uuid, p_employee_id uuid,
  p_regular numeric, p_overtime numeric, p_night_overtime numeric, p_holiday numeric,
  p_confirm boolean default false, p_notes text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_reason text;
  v_old jsonb;
begin
  if not public.payroll_can_input_for(p_employee_id) then
    raise exception 'You cannot enter hours for this employee' using errcode = '42501';
  end if;
  if public.payroll_period_entity(p_period_id) is distinct from public.payroll_employee_entity(p_employee_id) then
    raise exception 'Employee belongs to another company' using errcode = '42501';
  end if;
  if least(p_regular, p_overtime, p_night_overtime, p_holiday) < 0 then
    raise exception 'Hours cannot be negative' using errcode = '22023';
  end if;
  v_reason := public._payroll_frozen_reason(p_period_id, p_employee_id);
  if v_reason is not null then
    return jsonb_build_object('ok', false, 'reason', v_reason);
  end if;
  select to_jsonb(h) into v_old from public.payroll_hours h where period_id = p_period_id and employee_id = p_employee_id;
  insert into public.payroll_hours (period_id, employee_id, regular_hours, overtime_hours, night_overtime_hours, holiday_hours,
                                    status, source, notes, entered_by, entered_at, confirmed_by, confirmed_at)
  values (p_period_id, p_employee_id, coalesce(p_regular, 0), coalesce(p_overtime, 0), coalesce(p_night_overtime, 0),
          coalesce(p_holiday, 0), case when p_confirm then 'confirmed' else 'pending' end, 'manual', p_notes,
          auth.uid(), now(), case when p_confirm then auth.uid() end, case when p_confirm then now() end)
  on conflict (period_id, employee_id) do update
    set regular_hours = excluded.regular_hours, overtime_hours = excluded.overtime_hours,
        night_overtime_hours = excluded.night_overtime_hours, holiday_hours = excluded.holiday_hours,
        status = excluded.status, source = 'manual', notes = excluded.notes,
        entered_by = excluded.entered_by, entered_at = excluded.entered_at,
        confirmed_by = excluded.confirmed_by, confirmed_at = excluded.confirmed_at;
  perform public._payroll_audit(public.payroll_period_entity(p_period_id), 'payroll_hours', p_period_id, 'payroll_hours_set',
    v_old, jsonb_build_object('regular', p_regular, 'overtime', p_overtime, 'night', p_night_overtime,
                              'holiday', p_holiday, 'confirmed', p_confirm), p_employee_id);
  perform public._payroll_refresh(p_period_id, p_employee_id);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.payroll_confirm_hours(p_period_id uuid, p_employee_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  h record;
  v_done integer := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_reason text;
begin
  for h in
    select ph.*, e.full_name from public.payroll_hours ph join public.employees e on e.id = ph.employee_id
     where ph.period_id = p_period_id and ph.employee_id = any(p_employee_ids)
  loop
    v_reason := case when not public.payroll_can_input_for(h.employee_id) then 'No permission'
                     when h.status = 'confirmed' then 'Already confirmed'
                     else public._payroll_frozen_reason(p_period_id, h.employee_id) end;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', h.employee_id, 'name', h.full_name, 'reason', v_reason);
      continue;
    end if;
    update public.payroll_hours set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now() where id = h.id;
    perform public._payroll_audit(public.payroll_period_entity(p_period_id), 'payroll_hours', h.id, 'payroll_hours_confirmed',
      null, jsonb_build_object('regular', h.regular_hours, 'overtime', h.overtime_hours), h.employee_id);
    perform public._payroll_refresh(p_period_id, h.employee_id);
    v_done := v_done + 1;
  end loop;
  v_skipped := v_skipped || coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.full_name, 'reason', 'No hours entered'))
      from public.employees e
     where e.id = any(p_employee_ids)
       and not exists (select 1 from public.payroll_hours x where x.period_id = p_period_id and x.employee_id = e.id)), '[]'::jsonb);
  return jsonb_build_object('ok', true, 'processed', v_done, 'skipped', v_skipped);
end;
$$;

-- Approved attendance → regular hours (replaces, never adds: re-running is safe).
create or replace function public.payroll_import_attendance(p_period_id uuid, p_employee_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  p public.payroll_periods;
  a record;
  v_done integer := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_reason text;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if p.id is null then raise exception 'Payroll month not found' using errcode = 'P0002'; end if;
  if not (public.payroll_can(p.entity_id, 'prepare') or public.payroll_can(p.entity_id, 'inputs')) then
    raise exception 'No permission' using errcode = '42501';
  end if;
  for a in
    select psr.employee_id, e.full_name, round(sum(psr.final_payable_minutes) / 60.0, 2) as hours,
           count(*) filter (where psr.status = 'pending') as pending_shifts
      from public.payable_shift_records psr
      join public.shifts s on s.id = psr.shift_id
      join public.employees e on e.id = psr.employee_id
     where psr.entity_id = p.entity_id and s.shift_date between p.period_start and p.period_end
       and psr.final_payable_minutes is not null
       and (p_employee_ids is null or psr.employee_id = any(p_employee_ids))
     group by psr.employee_id, e.full_name
  loop
    v_reason := case when not public.payroll_can_input_for(a.employee_id) then 'No permission'
                     else public._payroll_frozen_reason(p.id, a.employee_id) end;
    if v_reason is null and exists (select 1 from public.payroll_hours h where h.period_id = p.id
                                     and h.employee_id = a.employee_id and h.source = 'manual' and h.status = 'confirmed') then
      v_reason := 'Hours were entered and confirmed manually; not overwritten';
    end if;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', a.employee_id, 'name', a.full_name, 'reason', v_reason);
      continue;
    end if;
    insert into public.payroll_hours (period_id, employee_id, regular_hours, status, source, notes, entered_by)
    values (p.id, a.employee_id, a.hours, 'pending', 'attendance',
            format('Imported from attendance%s', case when a.pending_shifts > 0 then format(' (%s shifts not yet final)', a.pending_shifts) else '' end),
            auth.uid())
    on conflict (period_id, employee_id) do update
      set regular_hours = excluded.regular_hours, status = 'pending', source = 'attendance',
          notes = excluded.notes, entered_by = excluded.entered_by, entered_at = now(),
          confirmed_by = null, confirmed_at = null;
    perform public._payroll_refresh(p.id, a.employee_id);
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('ok', true, 'processed', v_done, 'skipped', v_skipped);
end;
$$;

-- ------------------------------------------------------------ adjustments
create or replace function public.payroll_add_adjustment(p_period_id uuid, p_employee_ids uuid[], p_kind text, p_code text,
  p_amount numeric, p_mode text, p_reason text, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  p public.payroll_periods;
  v_targets uuid[] := array[]::uuid[];
  v_names text[] := array[]::text[];
  v_skipped jsonb := '[]'::jsonb;
  v_reason text;
  e record;
  v_n integer;
  v_cents bigint;
  v_base bigint;
  v_extra integer;
  v_items jsonb := '[]'::jsonb;
  v_batch uuid := gen_random_uuid();
  v_amt numeric;
  i integer;
begin
  select * into p from public.payroll_periods where id = p_period_id;
  if p.id is null then raise exception 'Payroll month not found' using errcode = 'P0002'; end if;
  perform public._payroll_require(p.entity_id, 'prepare');
  if p_mode not in ('individual', 'per_employee', 'distributed') then
    raise exception 'Choose "amount per employee" or "distribute a total"' using errcode = '22023';
  end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Amount must be more than zero' using errcode = '22023'; end if;
  if round(p_amount, 2) <> p_amount then raise exception 'Use at most 2 decimal places' using errcode = '22023'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;

  for e in select em.id, em.full_name from public.employees em where em.id = any(p_employee_ids) order by em.full_name loop
    v_reason := coalesce(public._payroll_ineligible_reason(e.id, p.id), public._payroll_frozen_reason(p.id, e.id));
    if p.kind = 'off_cycle' and v_reason in ('Left before this month', 'Joins after this month') then v_reason := null; end if;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.full_name, 'reason', v_reason);
    else
      v_targets := v_targets || e.id;
      v_names := v_names || e.full_name;
    end if;
  end loop;
  v_n := coalesce(array_length(v_targets, 1), 0);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'processed', 0, 'skipped', v_skipped, 'total', 0, 'items', '[]'::jsonb,
                              'reason', 'No eligible employees in the selection');
  end if;

  -- Distributed totals are split in whole fils; the first employees get
  -- the remainder so the shares add up exactly to the total.
  v_cents := round(p_amount * 100)::bigint;
  v_base := v_cents / v_n;
  v_extra := (v_cents - v_base * v_n)::integer;
  for i in 1 .. v_n loop
    v_amt := case when p_mode = 'distributed' then (v_base + case when i <= v_extra then 1 else 0 end) / 100.0 else p_amount end;
    v_items := v_items || jsonb_build_object('id', v_targets[i], 'name', v_names[i], 'amount', v_amt);
  end loop;

  if not p_preview then
    for i in 0 .. v_n - 1 loop
      v_amt := (v_items -> i ->> 'amount')::numeric;
      continue when v_amt <= 0;
      insert into public.payroll_adjustments (period_id, employee_id, kind, code, amount, reason, batch_id, allocation, created_by)
      values (p.id, (v_items -> i ->> 'id')::uuid, p_kind, p_code, v_amt, btrim(p_reason), v_batch,
              case when v_n = 1 and p_mode <> 'distributed' then 'individual' else p_mode end, auth.uid());
      if not exists (select 1 from public.payroll_records where period_id = p.id and employee_id = (v_items -> i ->> 'id')::uuid
                        and superseded_by_record_id is null) then
        insert into public.payroll_records (period_id, employee_id) values (p.id, (v_items -> i ->> 'id')::uuid);
      end if;
      perform public._payroll_refresh(p.id, (v_items -> i ->> 'id')::uuid);
    end loop;
    perform public._payroll_audit(p.entity_id, 'payroll_adjustments', v_batch, 'payroll_adjustment_added', null,
      jsonb_build_object('kind', p_kind, 'code', p_code, 'amount', p_amount, 'mode', p_mode, 'employees', v_n, 'reason', p_reason), null);
  end if;

  return jsonb_build_object('ok', true, 'preview', p_preview, 'batch_id', case when p_preview then null else v_batch end,
    'processed', v_n, 'skipped', v_skipped, 'items', v_items,
    'total', case when p_mode = 'distributed' then p_amount else p_amount * v_n end,
    'impact', case when p_kind = 'earning' then 1 else -1 end * case when p_mode = 'distributed' then p_amount else p_amount * v_n end);
end;
$$;

create or replace function public.payroll_void_adjustment(p_adjustment_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  a public.payroll_adjustments;
  v_reason text;
begin
  select * into a from public.payroll_adjustments where id = p_adjustment_id;
  if a.id is null then raise exception 'Adjustment not found' using errcode = 'P0002'; end if;
  perform public._payroll_require(public.payroll_period_entity(a.period_id), 'prepare');
  if a.voided_at is not null then return jsonb_build_object('ok', false, 'reason', 'Already removed'); end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  v_reason := public._payroll_frozen_reason(a.period_id, a.employee_id);
  if v_reason is not null then return jsonb_build_object('ok', false, 'reason', v_reason); end if;
  update public.payroll_adjustments set voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason) where id = a.id;
  perform public._payroll_audit(public.payroll_period_entity(a.period_id), 'payroll_adjustments', a.id, 'payroll_adjustment_removed',
    to_jsonb(a), jsonb_build_object('reason', p_reason), a.employee_id);
  perform public._payroll_refresh(a.period_id, a.employee_id);
  return jsonb_build_object('ok', true);
end;
$$;

-- ----------------------------------------------------------- review/approve
create or replace function public.payroll_submit_for_review(p_record_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r record;
  v_done integer := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_reason text;
begin
  for r in
    select pr.*, pp.entity_id, e.full_name from public.payroll_records pr
      join public.payroll_periods pp on pp.id = pr.period_id join public.employees e on e.id = pr.employee_id
     where pr.id = any(p_record_ids)
  loop
    v_reason := case when not public.payroll_can(r.entity_id, 'prepare') then 'No permission'
                     when r.superseded_by_record_id is not null then 'Replaced by a correction'
                     when r.record_status <> 'draft' then format('Already %s', replace(r.record_status, '_', ' '))
                     when r.calc_version = 0 then 'Not calculated yet'
                     when exists (select 1 from jsonb_array_elements(r.attention) x where x ->> 'severity' = 'blocking')
                       then 'Needs attention: ' || (select string_agg(x ->> 'message', ' ') from jsonb_array_elements(r.attention) x where x ->> 'severity' = 'blocking')
                     end;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', v_reason);
      continue;
    end if;
    update public.payroll_records set record_status = 'in_review', submitted_by = auth.uid(), submitted_at = now() where id = r.id;
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('ok', true, 'processed', v_done, 'skipped', v_skipped);
end;
$$;

-- p_items: [{"record_id": uuid, "calc_version": int}] — approval is against
-- the version the approver looked at; a stale version is refused.
create or replace function public.payroll_approve(p_items jsonb, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  it jsonb;
  r record;
  s public.payroll_settings;
  v_reason text;
  v_done integer := 0;
  v_total numeric := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_single boolean;
  ln record;
  v_out numeric;
begin
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    select pr.*, pp.entity_id, pp.period_start, e.full_name into r
      from public.payroll_records pr join public.payroll_periods pp on pp.id = pr.period_id
      join public.employees e on e.id = pr.employee_id
     where pr.id = (it ->> 'record_id')::uuid;
    if r.id is null then
      v_skipped := v_skipped || jsonb_build_object('id', it ->> 'record_id', 'name', null, 'reason', 'Record not found');
      continue;
    end if;
    s := public._payroll_settings(r.entity_id, r.period_start);
    v_single := public.my_role() = 'owner'
             or exists (select 1 from public.payroll_permissions pm where pm.user_id = auth.uid()
                         and pm.entity_id = r.entity_id and pm.can_single_step_approve);
    v_reason := case
      when not public.payroll_can(r.entity_id, 'approve') then 'No permission to approve'
      when r.superseded_by_record_id is not null then 'Replaced by a correction'
      when r.record_status = 'approved' then 'Already approved'
      when s.approval_mode = 'review_then_approve' and r.record_status <> 'in_review' then 'Send it for review first'
      when s.approval_mode <> 'review_then_approve' and r.record_status <> 'draft' then format('Record is %s', replace(r.record_status, '_', ' '))
      when (it ->> 'calc_version') is null or (it ->> 'calc_version')::integer <> r.calc_version
        then 'Amounts changed since you loaded them; refresh and review again'
      when exists (select 1 from jsonb_array_elements(r.attention) x where x ->> 'severity' = 'blocking')
        then 'Needs attention: ' || (select string_agg(x ->> 'message', ' ') from jsonb_array_elements(r.attention) x where x ->> 'severity' = 'blocking')
      when s.approval_mode = 'review_then_approve' and r.submitted_by = auth.uid() and not v_single
        then 'You sent it for review; a different person must approve'
      when s.approval_mode = 'two_step' and r.calculated_by = auth.uid()
        then 'You prepared it; a different person must approve (or enable owner single-step approval in Payroll Settings)'
      when s.approval_mode = 'owner_single_step' and r.calculated_by = auth.uid() and not v_single
        then 'Only the owner (or a user granted single-step approval) may approve their own preparation'
      end;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', v_reason);
      continue;
    end if;
    v_done := v_done + 1;
    v_total := v_total + r.net;
    continue when p_preview;

    update public.payroll_records
       set record_status = 'approved', approved_version = calc_version, approved_by = auth.uid(), approved_at = now(),
           returned_reason = null
     where id = r.id;
    -- Lock advance repayments to this approved record.
    for ln in select * from public.payroll_lines where record_id = r.id and code = 'advance_repayment' loop
      insert into public.advance_repayments (advance_id, record_id, period_id, amount)
      values (ln.source_id, r.id, r.period_id, ln.amount) on conflict do nothing;
      select a.amount - coalesce((select sum(ar.amount) from public.advance_repayments ar
                                    join public.payroll_records rr on rr.id = ar.record_id
                                   where ar.advance_id = a.id and rr.superseded_by_record_id is null), 0)
        into v_out from public.salary_advances a where a.id = ln.source_id;
      if v_out <= 0 then
        update public.salary_advances set status = 'settled' where id = ln.source_id and status = 'active';
      end if;
    end loop;
    perform public._payroll_audit(r.entity_id, 'payroll_records', r.id, 'payroll_record_approved', null,
      jsonb_build_object('version', r.calc_version, 'net', r.net), r.employee_id);
  end loop;
  return jsonb_build_object('ok', true, 'preview', p_preview, 'processed', v_done, 'total', v_total, 'skipped', v_skipped);
end;
$$;

create or replace function public.payroll_return_to_draft(p_record_ids uuid[], p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r record;
  v_reason text;
  v_done integer := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_exports integer;
begin
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  for r in
    select pr.*, pp.entity_id, e.full_name from public.payroll_records pr
      join public.payroll_periods pp on pp.id = pr.period_id join public.employees e on e.id = pr.employee_id
     where pr.id = any(p_record_ids)
  loop
    v_reason := case
      when not public.payroll_can(r.entity_id, 'prepare') then 'No permission'
      when r.superseded_by_record_id is not null then 'Replaced by a correction'
      when r.record_status = 'draft' then 'Already draft'
      when exists (select 1 from public.payroll_payments pm where pm.record_id = r.id and pm.status = 'recorded')
        then 'A payment is recorded; create a correction instead'
      end;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', v_reason);
      continue;
    end if;
    delete from public.advance_repayments where record_id = r.id;
    update public.salary_advances a set status = 'active'
     where a.status = 'settled' and exists (select 1 from public.payroll_lines l where l.record_id = r.id
                                             and l.code = 'advance_repayment' and l.source_id = a.id);
    update public.payroll_exports x set invalidated_at = now(),
           invalidated_reason = format('%s returned to draft: %s', r.full_name, btrim(p_reason))
     where x.invalidated_at is null and exists (select 1 from public.payroll_export_items i where i.export_id = x.id and i.record_id = r.id);
    get diagnostics v_exports = row_count;
    update public.payroll_records
       set record_status = 'draft', approved_version = null, approved_by = null, approved_at = null,
           submitted_by = null, submitted_at = null, published_at = null, published_by = null,
           returned_reason = btrim(p_reason)
     where id = r.id;
    perform public._payroll_audit(r.entity_id, 'payroll_records', r.id, 'payroll_record_returned',
      jsonb_build_object('status', r.record_status, 'net', r.net),
      jsonb_build_object('reason', p_reason, 'exports_invalidated', v_exports), r.employee_id);
    perform public._payroll_calculate(r.id);
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('ok', true, 'processed', v_done, 'skipped', v_skipped);
end;
$$;

-- Paid (or part-paid) record: a new draft record supersedes it; payments
-- already made stay on the original and count toward the correction.
create or replace function public.payroll_create_correction(p_record_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r public.payroll_records;
  v_entity uuid;
  v_new uuid := gen_random_uuid();
begin
  select * into r from public.payroll_records where id = p_record_id for update;
  if r.id is null then raise exception 'Record not found' using errcode = 'P0002'; end if;
  v_entity := public.payroll_period_entity(r.period_id);
  perform public._payroll_require(v_entity, 'prepare');
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if r.superseded_by_record_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'This record already has a correction');
  end if;
  if r.record_status <> 'approved' then
    return jsonb_build_object('ok', false, 'reason', 'Only approved records need a correction; edit the draft instead');
  end if;
  if not exists (select 1 from public.payroll_payments where record_id = r.id and status = 'recorded') then
    return jsonb_build_object('ok', false, 'reason', 'Nothing has been paid yet; use "Return to draft" instead');
  end if;
  update public.payroll_records set superseded_by_record_id = v_new where id = r.id;
  insert into public.payroll_records (id, period_id, employee_id, supersedes_record_id, correction_reason)
  values (v_new, r.period_id, r.employee_id, r.id, btrim(p_reason));
  -- Repayments locked to the original move to the correction when it is approved.
  delete from public.advance_repayments where record_id = r.id;
  perform public._payroll_audit(v_entity, 'payroll_records', v_new, 'payroll_correction_created',
    jsonb_build_object('original', r.id, 'net', r.net), jsonb_build_object('reason', p_reason), r.employee_id);
  perform public._payroll_calculate(v_new);
  return jsonb_build_object('ok', true, 'record_id', v_new);
end;
$$;

-- --------------------------------------------------------------- publish
create or replace function public.payroll_publish(p_record_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r record;
  v_reason text;
  v_done integer := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  for r in
    select pr.*, pp.entity_id, pp.period_start, pp.period_end, pp.label, e.full_name
      from public.payroll_records pr join public.payroll_periods pp on pp.id = pr.period_id
      join public.employees e on e.id = pr.employee_id
     where pr.id = any(p_record_ids)
  loop
    v_reason := case when not public.payroll_can(r.entity_id, 'approve') then 'No permission'
                     when r.record_status <> 'approved' then 'Approve it first'
                     when r.published_at is not null then 'Already published' end;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', v_reason);
      continue;
    end if;
    update public.payroll_records set published_at = now(), published_by = auth.uid() where id = r.id;
    perform public.create_notification(r.entity_id, null, r.employee_id, 'payslip_available', 'Payslip ready',
      format('Your payslip for %s is ready to view.', coalesce(r.label, to_char(r.period_start, 'FMMonth YYYY'))),
      'payroll_records', r.id, 'normal', 'payslip_v2:' || r.id::text);
    perform public._payroll_audit(r.entity_id, 'payroll_records', r.id, 'payroll_payslip_published', null,
      jsonb_build_object('net', r.net), r.employee_id);
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('ok', true, 'processed', v_done, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------- exports
create or replace function public.payroll_create_export(p_record_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  r record;
  v_period uuid;
  v_entity uuid;
  v_rows jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_id uuid;
  m record;
begin
  for r in
    select pr.*, pp.entity_id, e.full_name, l.name as branch
      from public.payroll_records pr join public.payroll_periods pp on pp.id = pr.period_id
      join public.employees e on e.id = pr.employee_id left join public.locations l on l.id = e.home_location_id
     where pr.id = any(p_record_ids) order by e.full_name
  loop
    if v_period is null then v_period := r.period_id; v_entity := r.entity_id; end if;
    select * into m from public._payroll_money(r.id);
    if not public.payroll_can(r.entity_id, 'pay') then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', 'No permission');
    elsif r.period_id <> v_period then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', 'Different payroll month');
    elsif r.superseded_by_record_id is not null then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', 'Replaced by a correction');
    elsif r.record_status <> 'approved' then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', 'Not approved');
    elsif m.outstanding <= 0 then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', 'Nothing outstanding');
    else
      v_rows := v_rows || jsonb_build_object('record_id', r.id, 'employee_id', r.employee_id, 'name', r.full_name,
        'branch', r.branch, 'amount', m.outstanding, 'already_paid', m.paid);
      v_total := v_total + m.outstanding;
    end if;
  end loop;
  if jsonb_array_length(v_rows) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'Nothing to export', 'skipped', v_skipped);
  end if;
  insert into public.payroll_exports (period_id, total_amount, employee_count, created_by)
  values (v_period, v_total, jsonb_array_length(v_rows), auth.uid()) returning id into v_id;
  insert into public.payroll_export_items (export_id, record_id, amount)
  select v_id, (x ->> 'record_id')::uuid, (x ->> 'amount')::numeric from jsonb_array_elements(v_rows) x;
  perform public._payroll_audit(v_entity, 'payroll_exports', v_id, 'payroll_payment_list_exported', null,
    jsonb_build_object('employees', jsonb_array_length(v_rows), 'total', v_total), null);
  return jsonb_build_object('ok', true, 'export_id', v_id, 'rows', v_rows, 'total', v_total, 'skipped', v_skipped);
end;
$$;

-- -------------------------------------------------------------- payments
-- p_items: [{"record_id": uuid, "amount": numeric|null}] — null amount = full outstanding.
-- p_request_key makes a submission idempotent: re-sending it records nothing twice.
create or replace function public.payroll_record_payments(p_items jsonb, p_paid_on date, p_method text,
  p_reference text, p_status text, p_request_key text, p_failure_reason text default null, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  it jsonb;
  r record;
  m record;
  v_amt numeric;
  v_reason text;
  v_done integer := 0;
  v_total numeric := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_batch uuid := gen_random_uuid();
  v_key text;
begin
  if p_status not in ('recorded', 'failed') then raise exception 'Status must be recorded or failed' using errcode = '22023'; end if;
  if nullif(btrim(p_request_key), '') is null then raise exception 'Missing request key' using errcode = '22023'; end if;
  if p_status = 'failed' and nullif(btrim(p_failure_reason), '') is null then
    raise exception 'Say why the payment failed' using errcode = '22023';
  end if;
  if p_paid_on is null or p_paid_on > (now() at time zone 'Asia/Dubai')::date then
    raise exception 'Payment date cannot be in the future' using errcode = '22023';
  end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    select pr.*, pp.entity_id, e.full_name into r from public.payroll_records pr
      join public.payroll_periods pp on pp.id = pr.period_id join public.employees e on e.id = pr.employee_id
     where pr.id = (it ->> 'record_id')::uuid for update of pr;
    if r.id is null then
      v_skipped := v_skipped || jsonb_build_object('id', it ->> 'record_id', 'reason', 'Record not found');
      continue;
    end if;
    select * into m from public._payroll_money(r.id);
    v_amt := coalesce((it ->> 'amount')::numeric, m.outstanding);
    v_key := btrim(p_request_key) || ':' || r.id::text;
    v_reason := case
      when not public.payroll_can(r.entity_id, 'pay') then 'No permission'
      when exists (select 1 from public.payroll_payments where idempotency_key = v_key) then 'Already recorded in this submission'
      when r.superseded_by_record_id is not null then 'Replaced by a correction; record payment on the correction'
      when r.record_status <> 'approved' then 'Not approved'
      when v_amt is null or v_amt <= 0 then 'Nothing outstanding'
      when round(v_amt, 2) <> v_amt then 'Use at most 2 decimal places'
      when p_status = 'recorded' and v_amt > m.outstanding then
        format('Amount is more than the %s outstanding', public._payroll_fmt(m.outstanding))
      end;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', r.id, 'name', r.full_name, 'reason', v_reason);
      continue;
    end if;
    v_done := v_done + 1;
    v_total := v_total + v_amt;
    continue when p_preview;
    insert into public.payroll_payments (record_id, amount, paid_on, method, reference, status, failure_reason,
                                         batch_id, idempotency_key, created_by)
    values (r.id, v_amt, p_paid_on, p_method, nullif(btrim(p_reference), ''), p_status, nullif(btrim(p_failure_reason), ''),
            v_batch, v_key, auth.uid());
    perform public._payroll_audit(r.entity_id, 'payroll_payments', r.id,
      case when p_status = 'recorded' then 'payroll_payment_recorded' else 'payroll_payment_failed' end, null,
      jsonb_build_object('amount', v_amt, 'paid_on', p_paid_on, 'method', p_method, 'reference', p_reference), r.employee_id);
  end loop;
  return jsonb_build_object('ok', true, 'preview', p_preview, 'processed', v_done, 'total', v_total, 'skipped', v_skipped);
end;
$$;

-- -------------------------------------------------------------- grants
do $$
declare f text;
begin
  foreach f in array array[
    'payroll_open_period(uuid, date)', 'payroll_open_off_cycle(uuid, date, text)',
    'payroll_prepare(uuid, uuid[])', 'payroll_recalculate(uuid[])',
    'payroll_set_hours(uuid, uuid, numeric, numeric, numeric, numeric, boolean, text)',
    'payroll_confirm_hours(uuid, uuid[])', 'payroll_import_attendance(uuid, uuid[])',
    'payroll_add_adjustment(uuid, uuid[], text, text, numeric, text, text, boolean)',
    'payroll_void_adjustment(uuid, text)', 'payroll_submit_for_review(uuid[])',
    'payroll_approve(jsonb, boolean)', 'payroll_return_to_draft(uuid[], text)',
    'payroll_create_correction(uuid, text)', 'payroll_publish(uuid[])', 'payroll_create_export(uuid[])',
    'payroll_record_payments(jsonb, date, text, text, text, text, text, boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
