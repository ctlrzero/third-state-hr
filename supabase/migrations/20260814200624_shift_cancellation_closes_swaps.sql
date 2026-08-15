
-- Phase 2.8: cancelling a shift must atomically close any swap request still
-- open/claimed against it — a manager can cancel a shift via a plain
-- .update({status:'cancelled'}) (shifts_access RLS already permits this; there
-- is no dedicated cancel-shift RPC), so this has to be a trigger to catch it
-- regardless of call path, the same "backstop regardless of write path"
-- pattern already used for enforce_payroll_child_immutability and
-- sync_shift_status.
create or replace function public.close_swaps_on_shift_cancellation() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_swap record;
begin
  if new.status <> 'cancelled' or old.status = 'cancelled' then
    return new;
  end if;

  for v_swap in
    select id, requested_by, claimed_by from shift_swap_requests
    where shift_id = new.id and status in ('open', 'claimed')
  loop
    update shift_swap_requests set status = 'cancelled', resolved_by = auth.uid(), resolved_at = now()
      where id = v_swap.id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('shift_swap_requests', v_swap.id, auth.uid(), 'swap_auto_closed_shift_cancelled',
      jsonb_build_object('shift_id', new.id), new.entity_id, new.location_id, v_swap.requested_by);

    perform public.create_notification(
      new.entity_id, null, v_swap.requested_by, 'swap_auto_closed', 'Shift swap closed — shift cancelled',
      'The shift behind your swap request was cancelled, so the request has been closed automatically.',
      'shift_swap_requests', v_swap.id, 'normal', 'swap_auto_closed:' || v_swap.id::text || ':requester'
    );

    if v_swap.claimed_by is not null then
      perform public.create_notification(
        new.entity_id, null, v_swap.claimed_by, 'swap_auto_closed', 'Shift swap closed — shift cancelled',
        'The shift you claimed in a swap was cancelled, so the request has been closed automatically.',
        'shift_swap_requests', v_swap.id, 'normal', 'swap_auto_closed:' || v_swap.id::text || ':claimant'
      );
    end if;
  end loop;

  return new;
end;
$$;

-- Trigger-callback function: fires regardless of the invoking role's EXECUTE
-- grant, so no grant to authenticated/anon is needed or wanted.
revoke all on function public.close_swaps_on_shift_cancellation() from public, anon, authenticated;

create trigger trg_close_swaps_on_shift_cancellation
  after update on public.shifts
  for each row
  execute function public.close_swaps_on_shift_cancellation();

