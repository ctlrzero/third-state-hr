-- ============================================================================
-- F&B HR System — Scheduling / Shift-Swap / Leave Management Module
-- Adds: employee_availability, shifts, shift_swap_requests,
--       leave_types, leave_balances, leave_requests,
--       approve_shift_swap(), approve_leave_request()
--
-- Note on scope: staff don't have logins yet (self-service/ESS is Phase 2),
-- so "staff post their own shift to swap" and "staff request their own leave"
-- are, for now, manager-mediated — a manager records the request on the
-- employee's behalf and runs the approval. The data model doesn't change
-- when ESS ships; only who is allowed to create the initial row does.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- AVAILABILITY — one row per employee per day of week (0 = Sunday ... 6 = Saturday)
-- ----------------------------------------------------------------------------
create table employee_availability (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) on delete cascade not null,
  day_of_week int not null check (day_of_week between 0 and 6),
  is_available boolean not null default true,
  start_time time,
  end_time time,
  unique (employee_id, day_of_week)
);

create or replace function seed_employee_availability()
returns trigger as $$
begin
  insert into employee_availability (employee_id, day_of_week, is_available)
  select new.id, d, true from generate_series(0, 6) as d;
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_seed_availability
  after insert on employees
  for each row execute function seed_employee_availability();

-- ----------------------------------------------------------------------------
-- SHIFTS
-- ----------------------------------------------------------------------------
create table shifts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid references entities(id) on delete cascade not null,
  location_id uuid references locations(id) not null,
  position_id uuid references positions(id),
  employee_id uuid references employees(id), -- null = open/unassigned shift
  shift_date date not null,
  start_time time not null,
  end_time time not null,
  status text not null default 'open' check (status in ('open', 'assigned', 'cancelled')),
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz default now()
);

create index idx_shifts_location_date on shifts(location_id, shift_date);
create index idx_shifts_employee on shifts(employee_id);

-- keep status truthful to employee_id automatically (unless explicitly cancelled)
create or replace function sync_shift_status()
returns trigger as $$
begin
  if new.status <> 'cancelled' then
    new.status := case when new.employee_id is null then 'open' else 'assigned' end;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_shift_status
  before insert or update on shifts
  for each row execute function sync_shift_status();

-- ----------------------------------------------------------------------------
-- SHIFT SWAP REQUESTS
-- ----------------------------------------------------------------------------
create table shift_swap_requests (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid references shifts(id) on delete cascade not null,
  requested_by uuid references employees(id) not null,
  claimed_by uuid references employees(id),
  status text not null default 'open' check (status in ('open', 'claimed', 'approved', 'rejected', 'cancelled')),
  notes text,
  created_at timestamptz default now(),
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz
);

create or replace function approve_shift_swap(p_swap_id uuid, p_action text)
returns void as $$
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
$$ language plpgsql security definer;

grant execute on function approve_shift_swap(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- LEAVE TYPES (per entity)
-- ----------------------------------------------------------------------------
create table leave_types (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid references entities(id) on delete cascade not null,
  name text not null,
  accrual_days_per_year numeric(6,2) not null default 0,
  requires_approval boolean not null default true,
  created_at timestamptz default now(),
  unique (entity_id, name)
);

-- ----------------------------------------------------------------------------
-- LEAVE BALANCES — written only via triggers / approve_leave_request()
-- ----------------------------------------------------------------------------
create table leave_balances (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) on delete cascade not null,
  leave_type_id uuid references leave_types(id) on delete cascade not null,
  balance_days numeric(6,2) not null default 0,
  updated_at timestamptz default now(),
  unique (employee_id, leave_type_id)
);

create trigger trg_leave_balances_updated_at
  before update on leave_balances
  for each row execute function set_updated_at();

-- Full annual accrual granted immediately on seeding — a foundation-level
-- simplification; monthly/prorated accrual can replace this later without
-- changing the table shape.
create or replace function seed_leave_balances_for_employee()
returns trigger as $$
begin
  insert into leave_balances (employee_id, leave_type_id, balance_days)
  select new.id, lt.id, lt.accrual_days_per_year
  from leave_types lt
  where lt.entity_id = new.entity_id
  on conflict (employee_id, leave_type_id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_seed_leave_balances_employee
  after insert on employees
  for each row execute function seed_leave_balances_for_employee();

create or replace function seed_leave_balances_for_leave_type()
returns trigger as $$
begin
  insert into leave_balances (employee_id, leave_type_id, balance_days)
  select e.id, new.id, new.accrual_days_per_year
  from employees e
  where e.entity_id = new.entity_id
  on conflict (employee_id, leave_type_id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_seed_leave_balances_type
  after insert on leave_types
  for each row execute function seed_leave_balances_for_leave_type();

-- ----------------------------------------------------------------------------
-- LEAVE REQUESTS
-- ----------------------------------------------------------------------------
create table leave_requests (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) not null,
  leave_type_id uuid references leave_types(id) not null,
  start_date date not null,
  end_date date not null,
  days_requested numeric(6,2) not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reason text,
  requested_at timestamptz default now(),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  manager_notes text,
  check (end_date >= start_date)
);

create index idx_leave_requests_employee on leave_requests(employee_id);

create or replace function approve_leave_request(p_request_id uuid, p_action text)
returns void as $$
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
$$ language plpgsql security definer;

grant execute on function approve_leave_request(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------
alter table employee_availability enable row level security;
alter table shifts enable row level security;
alter table shift_swap_requests enable row level security;
alter table leave_types enable row level security;
alter table leave_balances enable row level security;
alter table leave_requests enable row level security;

-- availability: scoped like employees themselves
create policy "availability_access" on employee_availability for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = employee_availability.employee_id and e.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = employee_availability.employee_id and e.home_location_id = my_location()))
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = employee_availability.employee_id and e.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = employee_availability.employee_id and e.home_location_id = my_location()))
  );

-- shifts: owner (all), entity_admin (entity-wide), location_manager (their location only)
create policy "shifts_access" on shifts for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and shifts.entity_id = my_entity())
    or (my_role() = 'location_manager' and shifts.location_id = my_location())
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and shifts.entity_id = my_entity())
    or (my_role() = 'location_manager' and shifts.location_id = my_location())
  );

-- shift swaps: scoped via the underlying shift's location
create policy "swaps_access" on shift_swap_requests for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from shifts s where s.id = shift_swap_requests.shift_id and s.location_id = my_location()))
  );

-- leave_types: owner/entity_admin manage; location_manager can view (needed to file requests)
create policy "leave_types_select" on leave_types for select
  using (
    my_role() = 'owner'
    or (my_role() in ('entity_admin', 'location_manager') and leave_types.entity_id = my_entity())
  );
create policy "leave_types_insert" on leave_types for insert
  with check (my_role() = 'owner' or (my_role() = 'entity_admin' and leave_types.entity_id = my_entity()));
create policy "leave_types_update" on leave_types for update
  using (my_role() = 'owner' or (my_role() = 'entity_admin' and leave_types.entity_id = my_entity()))
  with check (my_role() = 'owner' or (my_role() = 'entity_admin' and leave_types.entity_id = my_entity()));

-- leave_balances: read-only via RLS; all writes via triggers/approve_leave_request()
create policy "leave_balances_select" on leave_balances for select
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_balances.employee_id and e.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_balances.employee_id and e.home_location_id = my_location()))
  );

-- leave_requests: owner/entity_admin (entity-wide), location_manager (their location's employees)
create policy "leave_requests_access" on leave_requests for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.home_location_id = my_location()))
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.entity_id = my_entity()))
    or (my_role() = 'location_manager' and exists (select 1 from employees e where e.id = leave_requests.employee_id and e.home_location_id = my_location()))
  );

