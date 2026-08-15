
create or replace function public.cancel_interview(p_interview_id uuid, p_reason text) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'A cancellation reason is required'; end if;

  select jr.entity_id, jr.location_id into v_entity_id, v_location_id
    from public.interviews iv
    join public.job_applications ja on ja.id = iv.application_id
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where iv.id = p_interview_id;

  if v_entity_id is null then raise exception 'Interview % not found', p_interview_id; end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then raise exception 'Not authorized to cancel this interview'; end if;

  update public.interviews set cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_interview_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id)
  values ('interviews', p_interview_id, auth.uid(), 'interview_cancelled', jsonb_build_object('reason', p_reason), v_entity_id, v_location_id);
end;
$$;

create or replace function public.cancel_shift_swap_request(p_swap_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_swap record;
begin
  select ssr.id, ssr.requested_by, ssr.status, s.entity_id, s.location_id into v_swap
    from public.shift_swap_requests ssr
    join public.shifts s on s.id = ssr.shift_id
    where ssr.id = p_swap_id and ssr.requested_by = my_employee_id();

  if v_swap.id is null then raise exception 'Swap request not found or not yours to cancel'; end if;
  if v_swap.status not in ('open', 'claimed') then raise exception 'This swap request has already been decided'; end if;

  update public.shift_swap_requests set status = 'cancelled', resolved_by = auth.uid(), resolved_at = now()
    where id = p_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_cancelled', '{}'::jsonb, v_swap.entity_id, v_swap.location_id, my_employee_id());
end;
$$;

create or replace function public.claim_open_shift(p_shift_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_shift record;
begin
  select id, employee_id, status, location_id, entity_id into v_shift from public.shifts where id = p_shift_id;

  if v_shift.id is null then raise exception 'Shift % not found', p_shift_id; end if;
  if v_shift.status <> 'open' or v_shift.employee_id is not null then raise exception 'This shift is no longer open'; end if;
  if not is_active_employee(my_employee_id()) then raise exception 'Inactive employees cannot pick up shifts'; end if;
  if v_shift.location_id <> my_home_location() then raise exception 'You can only pick up open shifts at your own location'; end if;

  update public.shifts set employee_id = my_employee_id(), status = 'assigned' where id = p_shift_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shifts', p_shift_id, auth.uid(), 'shift_claimed', jsonb_build_object('employee_id', my_employee_id()), v_shift.entity_id, v_shift.location_id, my_employee_id());
end;
$$;

create or replace function public.claim_shift_swap(p_swap_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_swap record;
  v_shift record;
begin
  select id, shift_id, requested_by, claimed_by, status into v_swap from public.shift_swap_requests where id = p_swap_id;

  if v_swap.id is null then raise exception 'Swap request % not found', p_swap_id; end if;
  if v_swap.status <> 'open' or v_swap.claimed_by is not null then raise exception 'This swap request is no longer open'; end if;
  if v_swap.requested_by = my_employee_id() then raise exception 'You cannot claim your own swap request'; end if;
  if not is_active_employee(my_employee_id()) then raise exception 'Inactive employees cannot claim shift swaps'; end if;

  select id, location_id, status, entity_id into v_shift from public.shifts where id = v_swap.shift_id;

  if v_shift.status = 'cancelled' then raise exception 'Cannot claim a swap for a cancelled shift'; end if;
  if v_shift.location_id <> my_home_location() then raise exception 'You can only claim shift swaps at your own location'; end if;

  update public.shift_swap_requests set claimed_by = my_employee_id(), status = 'claimed' where id = p_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shift_swap_requests', p_swap_id, auth.uid(), 'swap_claimed', jsonb_build_object('shift_id', v_swap.shift_id), v_shift.entity_id, v_shift.location_id, my_employee_id());
end;
$$;

create or replace function public.request_shift_swap(p_shift_id uuid, p_notes text default null) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_shift record;
  v_swap_id uuid;
begin
  select id, employee_id, shift_date, status, entity_id, location_id into v_shift
    from public.shifts where id = p_shift_id and employee_id = my_employee_id();

  if v_shift.id is null then raise exception 'Shift not found or not assigned to you'; end if;
  if not is_active_employee(my_employee_id()) then raise exception 'Inactive employees cannot request shift swaps'; end if;
  if v_shift.status = 'cancelled' then raise exception 'Cannot request a swap for a cancelled shift'; end if;
  if v_shift.shift_date < current_date then raise exception 'Cannot request a swap for a shift that has already passed'; end if;
  if exists (select 1 from public.shift_swap_requests where shift_id = p_shift_id and status in ('open', 'claimed')) then
    raise exception 'There is already an open swap request for this shift';
  end if;

  insert into public.shift_swap_requests (shift_id, requested_by, status, notes)
  values (p_shift_id, my_employee_id(), 'open', p_notes) returning id into v_swap_id;

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('shift_swap_requests', v_swap_id, auth.uid(), 'swap_requested', jsonb_build_object('shift_id', p_shift_id), v_shift.entity_id, v_shift.location_id, my_employee_id());

  return v_swap_id;
end;
$$;

create or replace function public.log_employee_changes() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if tg_op = 'UPDATE' then
    insert into audit_log(table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
    values ('employees', new.id, auth.uid(), 'update', to_jsonb(old), to_jsonb(new), new.entity_id, new.home_location_id, new.id);
  elsif tg_op = 'INSERT' then
    insert into audit_log(table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('employees', new.id, auth.uid(), 'insert', to_jsonb(new), new.entity_id, new.home_location_id, new.id);
  end if;
  return new;
end;
$$;

create or replace function public.log_offer_changes() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
begin
  select jr.entity_id, jr.location_id into v_entity_id, v_location_id
    from public.job_applications ja join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = new.application_id;

  if tg_op = 'UPDATE' then
    insert into audit_log(table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id)
    values ('offers', new.id, auth.uid(), 'update', to_jsonb(old), to_jsonb(new), v_entity_id, v_location_id);
  elsif tg_op = 'INSERT' then
    insert into audit_log(table_name, record_id, changed_by, action, new_value, entity_id, location_id)
    values ('offers', new.id, auth.uid(), 'insert', to_jsonb(new), v_entity_id, v_location_id);
  end if;
  return new;
end;
$$;
