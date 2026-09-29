-- Deleting shifts: allowed for drafts and cancelled shifts, never for live published ones or shifts with
-- clock-in / payable time. Every deletion is kept in shift_adjustments + audit_log.

create or replace function public.guard_shift_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_reason text := nullif(btrim(current_setting('app.shift_adjust_reason', true)), '');
  v_swaps jsonb;
begin
  if public._maintenance_bypass() then
    return old;
  end if;

  if exists (select 1 from public.attendance_records a where a.shift_id = old.id) then
    raise exception using errcode = '22023', message = 'This shift has clock-in records, so it cannot be deleted';
  end if;
  if exists (select 1 from public.payable_shift_records p where p.shift_id = old.id) then
    raise exception using errcode = '22023', message = 'This shift has payable time recorded, so it cannot be deleted';
  end if;
  if old.is_published and old.status <> 'cancelled' then
    raise exception using errcode = '22023', message = 'Cancel this published shift first, then delete it';
  end if;
  if old.is_published and v_role is not null and v_role not in ('owner', 'entity_admin') then
    raise exception using errcode = '42501', message = 'Only an admin can delete a cancelled shift';
  end if;

  select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into v_swaps
    from public.shift_swap_requests s where s.shift_id = old.id;

  insert into public.shift_adjustments
    (shift_id, entity_id, location_id, employee_id, previous_employee_id, change_type, reason, old_values, new_values, changed_by)
  values
    (old.id, old.entity_id, old.location_id, old.employee_id, old.employee_id, 'deleted', v_reason,
     (to_jsonb(old) - 'created_by' - 'created_at') || jsonb_build_object('swap_requests', v_swaps), null, auth.uid());

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('shifts', old.id, auth.uid(),
          case when old.status = 'cancelled' then 'cancelled_shift_deleted' else 'draft_shift_deleted' end,
          to_jsonb(old) - 'created_by' - 'created_at',
          jsonb_build_object('reason', v_reason, 'was_published', old.is_published),
          old.entity_id, old.location_id, old.employee_id);

  return old;
end;
$$;

drop trigger if exists trg_guard_shift_delete on public.shifts;
create trigger trg_guard_shift_delete
  before delete on public.shifts
  for each row execute function public.guard_shift_delete();

revoke all on function public.guard_shift_delete() from public, anon, authenticated;

-- The update-history trigger no longer logs deletes (the guard above does, for every shift).
drop trigger if exists trg_record_published_shift_change on public.shifts;
create trigger trg_record_published_shift_change
  after update on public.shifts
  for each row execute function public.record_published_shift_change();

-- Admin action: delete one or many cancelled shifts, with an optional reason.
create or replace function public.delete_cancelled_shifts(p_shift_ids uuid[], p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  s record;
  v_done integer := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_why text;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception using errcode = '42501', message = 'Only an admin can delete cancelled shifts';
  end if;

  perform set_config('app.shift_adjust_reason', coalesce(btrim(p_reason), ''), true);

  for s in select * from public.shifts where id = any(p_shift_ids) loop
    v_why := case
      when v_role = 'entity_admin' and s.entity_id <> public.my_entity() then 'Not in your company'
      when s.status <> 'cancelled' then 'Not cancelled'
      when exists (select 1 from public.attendance_records a where a.shift_id = s.id) then 'Has clock-in records'
      when exists (select 1 from public.payable_shift_records p where p.shift_id = s.id) then 'Has payable time'
    end;
    if v_why is not null then
      v_skipped := v_skipped || jsonb_build_object('id', s.id, 'shift_date', s.shift_date, 'reason', v_why);
      continue;
    end if;
    delete from public.shifts where id = s.id;
    v_done := v_done + 1;
  end loop;

  perform set_config('app.shift_adjust_reason', '', true);
  return jsonb_build_object('ok', true, 'deleted', v_done, 'skipped', v_skipped);
end;
$$;

revoke all on function public.delete_cancelled_shifts(uuid[], text) from public, anon;
grant execute on function public.delete_cancelled_shifts(uuid[], text) to authenticated;;
