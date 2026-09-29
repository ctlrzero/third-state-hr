-- A. Published payslips (payroll v2) can never change; corrections create a new version.

create or replace function public.guard_published_payroll_record()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public._maintenance_bypass() then
    return coalesce(new, old);
  end if;
  if old.published_at is null then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    raise exception 'A published payslip cannot be deleted; create a correction instead' using errcode = '42501';
  end if;
  -- The only permitted change: linking the correction that replaces it (once).
  if (to_jsonb(new) - 'superseded_by_record_id') is distinct from (to_jsonb(old) - 'superseded_by_record_id')
     or (old.superseded_by_record_id is not null and new.superseded_by_record_id is distinct from old.superseded_by_record_id) then
    raise exception 'A published payslip cannot be changed; create a correction instead' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_published_payroll_record on public.payroll_records;
create trigger trg_guard_published_payroll_record
  before update or delete on public.payroll_records
  for each row execute function public.guard_published_payroll_record();

create or replace function public.guard_published_payroll_lines()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public._maintenance_bypass() then
    return coalesce(new, old);
  end if;
  if exists (select 1 from public.payroll_records r
              where r.id in (coalesce(new.record_id, old.record_id), old.record_id)
                and r.published_at is not null) then
    raise exception 'Lines of a published payslip cannot be changed; create a correction instead' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_guard_published_payroll_lines on public.payroll_lines;
create trigger trg_guard_published_payroll_lines
  before insert or update or delete on public.payroll_lines
  for each row execute function public.guard_published_payroll_lines();

revoke all on function public.guard_published_payroll_record() from public, anon, authenticated;
revoke all on function public.guard_published_payroll_lines() from public, anon, authenticated;

-- Return to draft: no longer allowed once the payslip is published (it used to unpublish and overwrite it).
create or replace function public.payroll_return_to_draft(p_record_ids uuid[], p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
      when r.published_at is not null then 'Payslip already published; create a correction instead'
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
           submitted_by = null, submitted_at = null,
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
$function$;

-- Correction: now also available for a published payslip that hasn't been paid yet.
create or replace function public.payroll_create_correction(p_record_id uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
  if r.published_at is null
     and not exists (select 1 from public.payroll_payments where record_id = r.id and status = 'recorded') then
    return jsonb_build_object('ok', false, 'reason', 'Not published or paid yet; use "Return to draft" instead');
  end if;
  update public.payroll_records set superseded_by_record_id = v_new where id = r.id;
  insert into public.payroll_records (id, period_id, employee_id, supersedes_record_id, correction_reason)
  values (v_new, r.period_id, r.employee_id, r.id, btrim(p_reason));
  delete from public.advance_repayments where record_id = r.id;
  perform public._payroll_audit(v_entity, 'payroll_records', v_new, 'payroll_correction_created',
    jsonb_build_object('original', r.id, 'net', r.net), jsonb_build_object('reason', p_reason), r.employee_id);
  perform public._payroll_calculate(v_new);
  return jsonb_build_object('ok', true, 'record_id', v_new);
end;
$function$;

-- B. Never pay the same month twice across the old and new payroll screens.

create or replace function public.payroll_open_period(p_entity_id uuid, p_month date)
 returns uuid
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date;
  v_id uuid;
  v_legacy text;
begin
  perform public._payroll_require(p_entity_id, 'prepare');
  select id into v_id from public.payroll_periods where entity_id = p_entity_id and kind = 'regular' and period_start = v_start;
  if v_id is null then
    select status into v_legacy from public.payroll_runs
     where entity_id = p_entity_id and period_start <= v_end and period_end >= v_start
     order by created_at limit 1;
    if v_legacy is not null then
      raise exception '% was already run in the previous payroll screen (status: %). Open it there, or use an off-cycle payroll for any extra payment.',
        to_char(v_start, 'FMMonth YYYY'), v_legacy using errcode = '22023';
    end if;
    insert into public.payroll_periods (entity_id, kind, period_start, period_end, created_by)
    values (p_entity_id, 'regular', v_start, v_end, auth.uid())
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
$function$;

create or replace function public.guard_legacy_run_vs_v2_period()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public._maintenance_bypass() then
    return new;
  end if;
  if exists (select 1 from public.payroll_periods p
              where p.entity_id = new.entity_id and p.kind = 'regular'
                and p.period_start <= new.period_end and p.period_end >= new.period_start) then
    raise exception 'This month is already open in the new payroll screen; run it there' using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_legacy_run_vs_v2_period on public.payroll_runs;
create trigger trg_guard_legacy_run_vs_v2_period
  before insert on public.payroll_runs
  for each row when (new.revises_payroll_run_id is null)
  execute function public.guard_legacy_run_vs_v2_period();

revoke all on function public.guard_legacy_run_vs_v2_period() from public, anon, authenticated;;
