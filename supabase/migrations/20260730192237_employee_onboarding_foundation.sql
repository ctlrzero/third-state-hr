-- ============================================================================
-- F&B HR System — Foundation Migration
-- Module: Employee Database (EDB) & Onboarding (subset of REC)
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- ENUMS
-- ----------------------------------------------------------------------------
create type user_role as enum ('owner', 'entity_admin', 'location_manager', 'staff');
create type employment_type as enum ('full_time', 'part_time', 'on_call', 'seasonal');
create type employee_status as enum ('candidate', 'pre_boarding', 'active', 'inactive');
create type document_type as enum (
  'passport', 'visa', 'labor_card', 'health_card', 'emirates_id',
  'offer_letter', 'contract', 'other'
);

-- ----------------------------------------------------------------------------
-- ORG HIERARCHY: entities -> locations -> positions
-- ----------------------------------------------------------------------------
create table entities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  trade_license_no text,
  emirate text,
  default_currency text default 'AED',
  created_at timestamptz default now()
);

create table locations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid references entities(id) on delete cascade not null,
  name text not null,
  address text,
  created_at timestamptz default now()
);

create table positions (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid references entities(id) on delete cascade not null,
  title text not null,
  department text,
  created_at timestamptz default now()
);

create index idx_locations_entity on locations(entity_id);
create index idx_positions_entity on positions(entity_id);

-- ----------------------------------------------------------------------------
-- PROFILES: links auth.users to a role + scope (entity/location)
-- ----------------------------------------------------------------------------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role user_role not null default 'staff',
  entity_id uuid references entities(id),
  location_id uuid references locations(id),
  created_at timestamptz default now()
);

-- Auto-create a profile row whenever someone signs up (defaults to 'staff';
-- promote the first account to 'owner' manually — see README).
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, new.raw_user_meta_data->>'full_name', 'staff');
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Helper functions used throughout RLS policies
create or replace function my_role() returns user_role
language sql stable security definer as $$
  select role from profiles where id = auth.uid();
$$;

create or replace function my_entity() returns uuid
language sql stable security definer as $$
  select entity_id from profiles where id = auth.uid();
$$;

create or replace function my_location() returns uuid
language sql stable security definer as $$
  select location_id from profiles where id = auth.uid();
$$;

-- ----------------------------------------------------------------------------
-- EMPLOYEES
-- ----------------------------------------------------------------------------
create table employees (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid references entities(id) on delete cascade not null,
  home_location_id uuid references locations(id),
  position_id uuid references positions(id),
  auth_user_id uuid references auth.users(id), -- linked once self-service (Phase 2) is enabled

  full_name text not null,
  preferred_name text,
  photo_url text,
  dob date,
  gender text,
  nationality text,
  phone text,
  email text,
  emergency_contact_name text,
  emergency_contact_phone text,

  national_id_no text,
  passport_no text,
  passport_exp date,
  visa_no text,
  visa_exp date,
  labor_card_no text,
  labor_card_exp date,
  health_card_no text,
  health_card_exp date,

  bank_name text,
  bank_iban text,

  employment_type employment_type default 'full_time',
  employment_status employee_status default 'candidate',
  join_date date,
  probation_end_date date,
  notes text,

  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index idx_employees_entity on employees(entity_id);
create index idx_employees_location on employees(home_location_id);
create index idx_employees_status on employees(employment_status);

create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_employees_updated_at
  before update on employees
  for each row execute function set_updated_at();

-- ----------------------------------------------------------------------------
-- DOCUMENT VAULT
-- ----------------------------------------------------------------------------
create table employee_documents (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) on delete cascade not null,
  doc_type document_type not null,
  file_url text not null,
  expiry_date date,
  uploaded_by uuid references auth.users(id),
  uploaded_at timestamptz default now(),
  notes text
);

create index idx_documents_employee on employee_documents(employee_id);

-- ----------------------------------------------------------------------------
-- ONBOARDING CHECKLIST (auto-seeded per new employee)
-- ----------------------------------------------------------------------------
create table onboarding_checklist_items (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) on delete cascade not null,
  item_key text not null,
  item_label text not null,
  is_complete boolean default false,
  completed_by uuid references auth.users(id),
  completed_at timestamptz,
  sort_order int default 0
);

create index idx_checklist_employee on onboarding_checklist_items(employee_id);

create or replace function seed_onboarding_checklist()
returns trigger as $$
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
$$ language plpgsql security definer;

create trigger trg_seed_onboarding_checklist
  after insert on employees
  for each row execute function seed_onboarding_checklist();

-- ----------------------------------------------------------------------------
-- AUDIT LOG (lightweight, append-only)
-- ----------------------------------------------------------------------------
create table audit_log (
  id uuid primary key default gen_random_uuid(),
  table_name text not null,
  record_id uuid not null,
  changed_by uuid references auth.users(id),
  changed_at timestamptz default now(),
  action text,
  old_value jsonb,
  new_value jsonb
);

create or replace function log_employee_changes()
returns trigger as $$
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
$$ language plpgsql security definer;

create trigger trg_employees_audit
  after insert or update on employees
  for each row execute function log_employee_changes();

-- ----------------------------------------------------------------------------
-- COMPLIANCE VIEW: one row per tracked document per employee, nearest expiry first
-- ----------------------------------------------------------------------------
create or replace view compliance_alerts as
select
  d.id as employee_id,
  d.full_name,
  d.entity_id,
  d.home_location_id,
  d.doc_type,
  d.expiry_date,
  (d.expiry_date - current_date) as days_remaining,
  case
    when (d.expiry_date - current_date) < 7 then 'critical'
    when (d.expiry_date - current_date) < 30 then 'warning'
    else 'ok'
  end as urgency
from (
  select id, full_name, entity_id, home_location_id, 'passport'::text as doc_type, passport_exp as expiry_date from employees
  union all
  select id, full_name, entity_id, home_location_id, 'visa', visa_exp from employees
  union all
  select id, full_name, entity_id, home_location_id, 'labor_card', labor_card_exp from employees
  union all
  select id, full_name, entity_id, home_location_id, 'health_card', health_card_exp from employees
) d
where d.expiry_date is not null
order by d.expiry_date asc;

-- ----------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------
alter table entities enable row level security;
alter table locations enable row level security;
alter table positions enable row level security;
alter table profiles enable row level security;
alter table employees enable row level security;
alter table employee_documents enable row level security;
alter table onboarding_checklist_items enable row level security;
alter table audit_log enable row level security;

-- profiles
create policy "profiles_select" on profiles for select
  using (id = auth.uid() or my_role() = 'owner');
create policy "profiles_update_own" on profiles for update
  using (id = auth.uid());

-- entities: everyone scoped can read; only owner/entity_admin (within their own entity) can write
create policy "entities_select" on entities for select
  using (my_role() = 'owner' or entities.id = my_entity());
create policy "entities_write" on entities for insert with check (my_role() = 'owner');
create policy "entities_update" on entities for update
  using (my_role() = 'owner' or (my_role() = 'entity_admin' and entities.id = my_entity()));

-- locations
create policy "locations_select" on locations for select
  using (my_role() = 'owner' or locations.entity_id = my_entity());
create policy "locations_modify" on locations for all
  using (my_role() = 'owner' or (my_role() = 'entity_admin' and locations.entity_id = my_entity()))
  with check (my_role() = 'owner' or (my_role() = 'entity_admin' and locations.entity_id = my_entity()));

-- positions
create policy "positions_select" on positions for select
  using (my_role() = 'owner' or positions.entity_id = my_entity());
create policy "positions_modify" on positions for all
  using (my_role() = 'owner' or (my_role() = 'entity_admin' and positions.entity_id = my_entity()))
  with check (my_role() = 'owner' or (my_role() = 'entity_admin' and positions.entity_id = my_entity()));

-- employees
create policy "employees_select" on employees for select
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and employees.entity_id = my_entity())
    or (my_role() = 'location_manager' and employees.home_location_id = my_location())
  );
create policy "employees_modify" on employees for all
  using (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and employees.entity_id = my_entity())
    or (my_role() = 'location_manager' and employees.home_location_id = my_location())
  )
  with check (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and employees.entity_id = my_entity())
    or (my_role() = 'location_manager' and employees.home_location_id = my_location())
  );

-- employee_documents (scoped via parent employee)
create policy "documents_access" on employee_documents for all
  using (
    exists (
      select 1 from employees e where e.id = employee_documents.employee_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and e.entity_id = my_entity())
        or (my_role() = 'location_manager' and e.home_location_id = my_location())
      )
    )
  )
  with check (
    exists (
      select 1 from employees e where e.id = employee_documents.employee_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and e.entity_id = my_entity())
        or (my_role() = 'location_manager' and e.home_location_id = my_location())
      )
    )
  );

-- onboarding checklist (scoped via parent employee)
create policy "checklist_access" on onboarding_checklist_items for all
  using (
    exists (
      select 1 from employees e where e.id = onboarding_checklist_items.employee_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and e.entity_id = my_entity())
        or (my_role() = 'location_manager' and e.home_location_id = my_location())
      )
    )
  )
  with check (
    exists (
      select 1 from employees e where e.id = onboarding_checklist_items.employee_id
      and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and e.entity_id = my_entity())
        or (my_role() = 'location_manager' and e.home_location_id = my_location())
      )
    )
  );

-- audit log: read-only, owner + entity_admin only
create policy "audit_select" on audit_log for select
  using (my_role() in ('owner', 'entity_admin'));

-- ----------------------------------------------------------------------------
-- STORAGE: private bucket for the document vault
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('employee-documents', 'employee-documents', false)
on conflict (id) do nothing;

create policy "doc_bucket_read" on storage.objects for select
  using (bucket_id = 'employee-documents' and auth.role() = 'authenticated');
create policy "doc_bucket_write" on storage.objects for insert
  with check (bucket_id = 'employee-documents' and auth.role() = 'authenticated');

