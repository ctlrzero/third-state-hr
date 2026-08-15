
-- Phase 1.1: payroll run immutability. Previously timesheet_entries/
-- tips_pools/payslip_deductions RLS only checked entity/location match —
-- never the parent run's status — so an owner/entity_admin (and, for
-- timesheet_entries, a location_manager) could edit hours/tips/deductions
-- on an approved or paid run directly against the table, bypassing the
-- UI's editing lock entirely. Fixed with two independent layers per the
-- remediation spec: RLS policies now also require the parent run to be
-- 'draft', AND a BEFORE trigger enforces the same rule regardless of RLS
-- (so even a SECURITY DEFINER function or a role that bypasses RLS can't
-- silently mutate a locked run's inputs). Corrections to an
-- approved/paid run must go through a new revision run instead of ever
-- touching the original snapshot.

alter table public.payroll_runs
  add column revises_payroll_run_id uuid references public.payroll_runs(id);

create index if not exists payroll_runs_revises_idx
  on public.payroll_runs (revises_payroll_run_id)
  where revises_payroll_run_id is not null;

-- --- Trigger: hard lock at the database level, independent of RLS -----

create or replace function public.enforce_payroll_child_immutability()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_run_id uuid;
  v_status text;
begin
  v_run_id := coalesce(new.payroll_run_id, old.payroll_run_id);

  select status into v_status from public.payroll_runs where id = v_run_id;

  if v_status is null then
    raise exception 'Payroll run % not found', v_run_id;
  end if;

  if v_status <> 'draft' then
    -- Log the blocked attempt itself, not just successful changes, before
    -- raising — this fires whether the caller is a human via the UI, a
    -- direct REST/RPC call, or (since this is a trigger, not just RLS) a
    -- SECURITY DEFINER function that forgot its own status check.
    insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value)
    values (
      tg_table_name, coalesce(new.id, old.id), auth.uid(), 'payroll_change_blocked_locked_run',
      jsonb_build_object('payroll_run_id', v_run_id, 'run_status', v_status, 'operation', tg_op),
      case when tg_op = 'DELETE' then null else to_jsonb(new) end
    );
    raise exception 'Cannot modify % while payroll run % is ''%'' (only draft runs are editable). Create a revision run for corrections instead.',
      tg_table_name, v_run_id, v_status;
  end if;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value)
  values (
    tg_table_name, coalesce(new.id, old.id), auth.uid(), lower(tg_op) || '_payroll_input',
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_timesheet_immutability on public.timesheet_entries;
create trigger trg_timesheet_immutability
  before insert or update or delete on public.timesheet_entries
  for each row execute function public.enforce_payroll_child_immutability();

drop trigger if exists trg_tips_immutability on public.tips_pools;
create trigger trg_tips_immutability
  before insert or update or delete on public.tips_pools
  for each row execute function public.enforce_payroll_child_immutability();

drop trigger if exists trg_deductions_immutability on public.payslip_deductions;
create trigger trg_deductions_immutability
  before insert or update or delete on public.payslip_deductions
  for each row execute function public.enforce_payroll_child_immutability();

-- --- RLS: same rule, second independent layer -------------------------

drop policy if exists timesheet_insert on public.timesheet_entries;
create policy timesheet_insert on public.timesheet_entries
  for insert
  to authenticated
  with check (
    exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
      or (my_role() = 'location_manager' and exists (select 1 from public.employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
    )
  );

drop policy if exists timesheet_update on public.timesheet_entries;
create policy timesheet_update on public.timesheet_entries
  for update
  to authenticated
  using (
    exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
      or (my_role() = 'location_manager' and exists (select 1 from public.employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
    )
  )
  with check (
    exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
      or (my_role() = 'location_manager' and exists (select 1 from public.employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
    )
  );

drop policy if exists timesheet_delete on public.timesheet_entries;
create policy timesheet_delete on public.timesheet_entries
  for delete
  to authenticated
  using (
    exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = timesheet_entries.payroll_run_id and pr.entity_id = my_entity()))
      or (my_role() = 'location_manager' and exists (select 1 from public.employees e where e.id = timesheet_entries.employee_id and e.home_location_id = my_location()))
    )
  );

drop policy if exists tips_modify on public.tips_pools;
create policy tips_modify on public.tips_pools
  for all
  to authenticated
  using (
    exists (select 1 from public.payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.entity_id = my_entity()))
      or (my_role() = 'location_manager' and tips_pools.location_id = my_location())
    )
  )
  with check (
    exists (select 1 from public.payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = tips_pools.payroll_run_id and pr.entity_id = my_entity()))
      or (my_role() = 'location_manager' and tips_pools.location_id = my_location())
    )
  );

drop policy if exists deductions_access on public.payslip_deductions;
create policy deductions_access on public.payslip_deductions
  for all
  to authenticated
  using (
    exists (select 1 from public.payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.entity_id = my_entity()))
    )
  )
  with check (
    exists (select 1 from public.payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.status = 'draft')
    and (
      my_role() = 'owner'
      or (my_role() = 'entity_admin' and exists (select 1 from public.payroll_runs pr where pr.id = payslip_deductions.payroll_run_id and pr.entity_id = my_entity()))
    )
  );

-- --- Revision run RPC --------------------------------------------------

create or replace function public.create_payroll_revision(p_source_run_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_source record;
  v_new_id uuid;
begin
  select * into v_source from public.payroll_runs where id = p_source_run_id;

  if v_source.id is null then
    raise exception 'Payroll run % not found', p_source_run_id;
  end if;

  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_source.entity_id = my_entity())) then
    raise exception 'Not authorized to create a revision of this payroll run';
  end if;

  if v_source.status not in ('approved', 'paid') then
    raise exception 'Only an approved or paid run can be revised (current status: %). Edit the draft directly instead.', v_source.status;
  end if;

  insert into public.payroll_runs (
    entity_id, period_start, period_end, status, tip_distribution_rule, created_by, revises_payroll_run_id
  ) values (
    v_source.entity_id, v_source.period_start, v_source.period_end, 'draft', v_source.tip_distribution_rule, auth.uid(), p_source_run_id
  )
  returning id into v_new_id;

  -- Seed the revision from the source run's inputs so a correction starts
  -- from "what was actually paid" rather than a blank slate — the source
  -- run's own rows are never touched, only copied.
  insert into public.timesheet_entries (payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes)
  select v_new_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes
  from public.timesheet_entries where payroll_run_id = p_source_run_id;

  insert into public.tips_pools (payroll_run_id, location_id, total_amount, notes)
  select v_new_id, location_id, total_amount, notes
  from public.tips_pools where payroll_run_id = p_source_run_id;

  insert into public.payslip_deductions (payroll_run_id, employee_id, deduction_type, amount, notes)
  select v_new_id, employee_id, deduction_type, amount, notes
  from public.payslip_deductions where payroll_run_id = p_source_run_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('payroll_runs', v_new_id, auth.uid(), 'payroll_revision_created',
    jsonb_build_object('revises_payroll_run_id', p_source_run_id));

  return v_new_id;
end;
$function$;

revoke all on function public.create_payroll_revision(uuid) from public, anon;
grant execute on function public.create_payroll_revision(uuid) to authenticated;

