-- MEDIUM FIX 1: BR-PAY-001 says a manager gets zero payroll-period access; the
-- app schema said "no payroll periods" but payroll_runs_select still let
-- location_manager see status/period rows for their entity. Amounts were never
-- exposed (payslips/employee_compensation already excluded them), but tighten to
-- match the requirement exactly: owner/entity_admin only.
drop policy if exists payroll_runs_select on public.payroll_runs;
create policy payroll_runs_select
on public.payroll_runs
for select
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
);

-- MEDIUM FIX 2: harden search_path on every function the linter flagged (prevents
-- search_path hijacking). Bodies are unchanged from what is currently deployed.

create or replace function public.my_role()
returns user_role
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select role from profiles where id = auth.uid();
$function$;

create or replace function public.my_entity()
returns uuid
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select entity_id from profiles where id = auth.uid();
$function$;

create or replace function public.my_location()
returns uuid
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select location_id from profiles where id = auth.uid();
$function$;

create or replace function public.my_employee_id()
returns uuid
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select id from employees where auth_user_id = auth.uid();
$function$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

create or replace function public.sync_shift_status()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.status <> 'cancelled' then
    new.status := case when new.employee_id is null then 'open' else 'assigned' end;
  end if;
  return new;
end;
$function$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, new.raw_user_meta_data->>'full_name', 'staff');
  return new;
end;
$function$;

create or replace function public.log_employee_changes()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'UPDATE' then
    insert into audit_log(table_name, record_id, changed_by, action, old_value, new_value)
    values ('employees', new.id, auth.uid(), 'update', to_jsonb(old), to_jsonb(new));
  elsif tg_op = 'INSERT' then
    insert into audit_log(table_name, record_id, changed_by, action, new_value)
    values ('employees', new.id, auth.uid(), 'insert', to_jsonb(new));
  end if;
  return new;
end;
$function$;

create or replace function public.seed_employee_availability()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into employee_availability (employee_id, day_of_week, is_available)
  select new.id, d, true from generate_series(0, 6) as d;
  return new;
end;
$function$;

create or replace function public.seed_employee_compensation()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into employee_compensation (employee_id) values (new.id);
  return new;
end;
$function$;

create or replace function public.seed_leave_balances_for_employee()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into leave_balances (employee_id, leave_type_id, balance_days)
  select new.id, lt.id, lt.accrual_days_per_year
  from leave_types lt
  where lt.entity_id = new.entity_id
  on conflict (employee_id, leave_type_id) do nothing;
  return new;
end;
$function$;

create or replace function public.seed_leave_balances_for_leave_type()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into leave_balances (employee_id, leave_type_id, balance_days)
  select e.id, new.id, new.accrual_days_per_year
  from employees e
  where e.entity_id = new.entity_id
  on conflict (employee_id, leave_type_id) do nothing;
  return new;
end;
$function$;

create or replace function public.seed_onboarding_checklist()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into onboarding_checklist_items (employee_id, item_key, item_label, sort_order) values
    (new.id, 'documents_verified',   'Verify ID, visa & bank documents',        1),
    (new.id, 'uniform_issued',       'Issue uniform & name badge',              2),
    (new.id, 'system_login_created', 'Create POS / ordering system login',      3),
    (new.id, 'food_safety_induction','Complete food safety induction',          4),
    (new.id, 'buddy_assigned',       'Assign onboarding buddy',                 5),
    (new.id, 'day1_induction',       'Complete Day 1 induction',                6);
  return new;
end;
$function$;

create or replace function public.approve_leave_request(p_request_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_employee_id uuid;
  v_entity_id uuid;
  v_home_location uuid;
  v_leave_type_id uuid;
  v_days numeric;
begin
  select lr.employee_id, e.entity_id, e.home_location_id, lr.leave_type_id, lr.days_requested
    into v_employee_id, v_entity_id, v_home_location, v_leave_type_id, v_days
  from leave_requests lr
  join employees e on e.id = lr.employee_id
  where lr.id = p_request_id;

  if v_employee_id is null then
    raise exception 'Leave request % not found', p_request_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_home_location = my_location())
  ) then
    raise exception 'Not authorized to decide this leave request';
  end if;

  if p_action = 'approve' then
    update leave_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where id = p_request_id;
    update leave_balances set balance_days = balance_days - v_days, updated_at = now()
      where employee_id = v_employee_id and leave_type_id = v_leave_type_id;
  elsif p_action = 'reject' then
    update leave_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = p_request_id;
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$function$;

create or replace function public.approve_shift_swap(p_swap_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_shift_id uuid;
  v_claimed_by uuid;
  v_entity_id uuid;
  v_location_id uuid;
begin
  select ss.shift_id, ss.claimed_by, s.entity_id, s.location_id
    into v_shift_id, v_claimed_by, v_entity_id, v_location_id
  from shift_swap_requests ss
  join shifts s on s.id = ss.shift_id
  where ss.id = p_swap_id;

  if v_shift_id is null then
    raise exception 'Swap request % not found', p_swap_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then
    raise exception 'Not authorized to decide this swap request';
  end if;

  if p_action = 'approve' then
    if v_claimed_by is null then
      raise exception 'This swap has not been claimed by anyone yet';
    end if;
    update shifts set employee_id = v_claimed_by where id = v_shift_id;
    update shift_swap_requests set status = 'approved', resolved_by = auth.uid(), resolved_at = now() where id = p_swap_id;
  elsif p_action = 'reject' then
    update shift_swap_requests set status = 'rejected', resolved_by = auth.uid(), resolved_at = now() where id = p_swap_id;
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$function$;

-- MEDIUM FIX 3: internal/trigger-only functions have no legitimate direct-RPC use
-- case; remove them from the callable API entirely (trigger firing is unaffected --
-- it does not go through PostgREST's role-EXECUTE grant path).
revoke execute on function public.log_employee_changes() from anon, authenticated;
revoke execute on function public.log_offer_changes() from anon, authenticated;
revoke execute on function public.handle_new_user() from anon, authenticated;
revoke execute on function public.set_updated_at() from anon, authenticated;
revoke execute on function public.sync_shift_status() from anon, authenticated;
revoke execute on function public.seed_employee_availability() from anon, authenticated;
revoke execute on function public.seed_employee_compensation() from anon, authenticated;
revoke execute on function public.seed_leave_balances_for_employee() from anon, authenticated;
revoke execute on function public.seed_leave_balances_for_leave_type() from anon, authenticated;
revoke execute on function public.seed_onboarding_checklist() from anon, authenticated;

-- App-facing RPCs must stay callable by signed-in users, just not by anon
-- (each already rejects internally, this is defense-in-depth per the advisor).
revoke execute on function public.approve_leave_request(uuid, text) from anon;
revoke execute on function public.approve_shift_swap(uuid, text) from anon;
revoke execute on function public.convert_offer_to_employee(uuid) from anon;
revoke execute on function public.run_payroll_calculation(uuid) from anon;

-- my_role/my_entity/my_location/my_employee_id are used inside every RLS policy,
-- so `authenticated` must keep EXECUTE -- only drop the unauthenticated path.
revoke execute on function public.my_role() from anon;
revoke execute on function public.my_entity() from anon;
revoke execute on function public.my_location() from anon;
revoke execute on function public.my_employee_id() from anon;

