-- P0-6 (docs/HR_IMPLEMENTATION_PLAN.md): a reason is compulsory for published-shift changes.
--
-- The app already edits and cancels published shifts through
-- adjust_published_shift / cancel_published_shift, which set
-- app.shift_adjust_reason; the history trigger (record_published_shift_change)
-- stores it in shift_adjustments. A direct table update could still change a
-- published shift with no reason. This guard refuses that.
--
-- Guarded: any change to date, times, break, person, branch, role, status or
-- the published flag of a published shift, made by a signed-in user without
-- app.shift_adjust_reason. Not guarded: notes; drafts; database-internal calls
-- with no JWT subject (maintenance). Deletes are already guarded by
-- trg_guard_shift_delete.
--
-- The two other functions that change published shifts now record a reason:
-- approve_shift_swap ('Shift swap approved') and claim_open_shift ('Picked up
-- open shift').

create or replace function public.guard_published_shift_update()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if old.is_published
     and auth.uid() is not null
     and (new.shift_date, new.start_time, new.end_time, new.break_minutes, new.employee_id,
          new.location_id, new.position_id, new.status, new.is_published)
         is distinct from
         (old.shift_date, old.start_time, old.end_time, old.break_minutes, old.employee_id,
          old.location_id, old.position_id, old.status, old.is_published)
     and nullif(btrim(coalesce(current_setting('app.shift_adjust_reason', true), '')), '') is null then
    raise exception using errcode = '22023',
      message = 'A published shift can only be changed with a reason. Use Adjust or Cancel.';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_published_shift_update() from public, anon, authenticated;

drop trigger if exists trg_guard_published_shift_update on public.shifts;
create trigger trg_guard_published_shift_update
  before update on public.shifts
  for each row execute function public.guard_published_shift_update();

-- approve_shift_swap and claim_open_shift: record why the published shift changed
do $patch$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('public.approve_shift_swap(uuid, text)'::regprocedure);
  v_new := replace(v_def,
    E'    update shifts set employee_id = v_claimed_by where id = v_shift_id;\n',
    E'    perform set_config(''app.shift_adjust_reason'', ''Shift swap approved'', true);\n'
    || E'    update shifts set employee_id = v_claimed_by where id = v_shift_id;\n'
    || E'    perform set_config(''app.shift_adjust_reason'', '''', true);\n');
  if v_new = v_def then raise exception 'approve_shift_swap: update statement not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('public.claim_open_shift(uuid)'::regprocedure);
  v_new := replace(v_def,
    E'  update public.shifts set employee_id = my_employee_id(), status = ''assigned'' where id = p_shift_id;\n',
    E'  perform set_config(''app.shift_adjust_reason'', ''Picked up open shift'', true);\n'
    || E'  update public.shifts set employee_id = my_employee_id(), status = ''assigned'' where id = p_shift_id;\n'
    || E'  perform set_config(''app.shift_adjust_reason'', '''', true);\n');
  if v_new = v_def then raise exception 'claim_open_shift: update statement not found'; end if;
  execute v_new;
end
$patch$;
