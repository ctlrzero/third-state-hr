
create or replace function public.my_home_location()
returns uuid
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select home_location_id from public.employees where auth_user_id = auth.uid();
$$;

revoke all on function public.my_home_location() from public, anon;
grant execute on function public.my_home_location() to authenticated;

create policy shifts_select_self on public.shifts
  for select
  to authenticated
  using (employee_id = my_employee_id());

create policy shifts_select_open_home_location on public.shifts
  for select
  to authenticated
  using (status = 'open' and location_id = my_home_location());

drop policy if exists swaps_insert on public.shift_swap_requests;
create policy swaps_insert on public.shift_swap_requests
  for insert
  to authenticated
  with check (
    (my_role() = 'owner')
    or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
  );

drop policy if exists swaps_update on public.shift_swap_requests;
create policy swaps_update on public.shift_swap_requests
  for update
  to authenticated
  using (
    (my_role() = 'owner')
    or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
  )
  with check (
    (my_role() = 'owner')
    or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
  );

drop policy if exists swaps_delete on public.shift_swap_requests;
create policy swaps_delete on public.shift_swap_requests
  for delete
  to authenticated
  using (
    (my_role() = 'owner')
    or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
  );

drop policy if exists swaps_select on public.shift_swap_requests;
create policy swaps_select on public.shift_swap_requests
  for select
  to authenticated
  using (
    requested_by = my_employee_id()
    or claimed_by = my_employee_id()
    or (status = 'open' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_home_location()))
    or (my_role() = 'owner')
    or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
  );

create or replace function public.request_shift_swap(p_shift_id uuid, p_notes text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_shift record;
  v_swap_id uuid;
begin
  select id, employee_id, shift_date, status into v_shift
    from public.shifts
    where id = p_shift_id and employee_id = my_employee_id();

  if v_shift.id is null then
    raise exception 'Shift not found or not assigned to you';
  end if;

  if not is_active_employee(my_employee_id()) then
    raise exception 'Inactive employees cannot request shift swaps';
  end if;

  if v_shift.status = 'cancelled' then
    raise exception 'Cannot request a swap for a cancelled shift';
  end if;

  if v_shift.shift_date < current_date then
    raise exception 'Cannot request a swap for a shift that has already passed';
  end if;

  if exists (select 1 from public.shift_swap_requests where shift_id = p_shift_id and status in ('open', 'claimed')) then
    raise exception 'There is already an open swap request for this shift';
  end if;

  insert into public.shift_swap_requests (shift_id, requested_by, status, notes)
  values (p_shift_id, my_employee_id(), 'open', p_notes)
  returning id into v_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('shift_swap_requests', v_swap_id, auth.uid(), 'swap_requested', jsonb_build_object('shift_id', p_shift_id));

  return v_swap_id;
end;
$$;

revoke all on function public.request_shift_swap(uuid, text) from public, anon;
grant execute on function public.request_shift_swap(uuid, text) to authenticated;

create or replace function public.claim_shift_swap(p_swap_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_swap record;
  v_shift record;
begin
  select id, shift_id, requested_by, claimed_by, status into v_swap
    from public.shift_swap_requests
    where id = p_swap_id;

  if v_swap.id is null then
    raise exception 'Swap request % not found', p_swap_id;
  end if;

  if v_swap.status <> 'open' or v_swap.claimed_by is not null then
    raise exception 'This swap request is no longer open';
  end if;

  if v_swap.requested_by = my_employee_id() then
    raise exception 'You cannot claim your own swap request';
  end if;

  if not is_active_employee(my_employee_id()) then
    raise exception 'Inactive employees cannot claim shift swaps';
  end if;

  select id, location_id, status into v_shift from public.shifts where id = v_swap.shift_id;

  if v_shift.status = 'cancelled' then
    raise exception 'Cannot claim a swap for a cancelled shift';
  end if;

  if v_shift.location_id <> my_home_location() then
    raise exception 'You can only claim shift swaps at your own location';
  end if;

  update public.shift_swap_requests
    set claimed_by = my_employee_id(), status = 'claimed'
    where id = p_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_claimed', jsonb_build_object('shift_id', v_swap.shift_id));
end;
$$;

revoke all on function public.claim_shift_swap(uuid) from public, anon;
grant execute on function public.claim_shift_swap(uuid) to authenticated;

create or replace function public.cancel_shift_swap_request(p_swap_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_swap record;
begin
  select id, requested_by, status into v_swap
    from public.shift_swap_requests
    where id = p_swap_id and requested_by = my_employee_id();

  if v_swap.id is null then
    raise exception 'Swap request not found or not yours to cancel';
  end if;

  if v_swap.status not in ('open', 'claimed') then
    raise exception 'This swap request has already been decided';
  end if;

  update public.shift_swap_requests
    set status = 'cancelled', resolved_by = auth.uid(), resolved_at = now()
    where id = p_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_cancelled', '{}'::jsonb);
end;
$$;

revoke all on function public.cancel_shift_swap_request(uuid) from public, anon;
grant execute on function public.cancel_shift_swap_request(uuid) to authenticated;
