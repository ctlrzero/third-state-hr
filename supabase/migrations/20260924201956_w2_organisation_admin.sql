-- ============================================================
-- W2 Organisation admin: entity/location codes, payroll day, soft
-- (in)activation, owner/entity_admin upsert RPCs and a dependency
-- summary shown before inactivation. No hard deletes: direct
-- INSERT/UPDATE/DELETE on entities/locations is revoked from
-- authenticated; every change goes through the audited RPCs below.
-- ============================================================

alter table public.entities
  add column code text,
  add column payroll_day smallint,
  add column is_active boolean not null default true,
  add column updated_at timestamptz not null default now();

alter table public.entities
  add constraint entities_code_format_check check (code is null or code ~ '^[A-Z0-9][A-Z0-9_-]{1,11}$'),
  add constraint entities_payroll_day_check check (payroll_day is null or payroll_day between 1 and 28),
  add constraint entities_code_key unique (code);

alter table public.locations
  add column code text,
  add column is_active boolean not null default true,
  add column updated_at timestamptz not null default now();

alter table public.locations
  add constraint locations_code_format_check check (code is null or code ~ '^[A-Z0-9][A-Z0-9_-]{1,11}$'),
  add constraint locations_entity_code_key unique (entity_id, code);

comment on column public.entities.code is 'Short unique business code (e.g. TSC). Upper-case A-Z/0-9/_/-, 2-12 chars.';
comment on column public.entities.payroll_day is 'Day of month (1-28) payroll is normally paid. Informational; no automatic run is triggered from it.';
comment on column public.entities.is_active is 'Soft inactivation flag. Entities are never hard-deleted.';
comment on column public.locations.is_active is 'Soft inactivation flag. Locations (branches) are never hard-deleted.';

-- Writes only via RPC (UI hiding is not security).
revoke insert, update, delete on table public.entities from authenticated;
revoke insert, update, delete on table public.locations from authenticated;

-- ------------------------------------------------------------
-- Internal: canonical emirate name (case-insensitive match).
-- ------------------------------------------------------------
create or replace function public._canonical_emirate(p_emirate text)
returns text
language sql
immutable
set search_path = ''
as $$
  select v.name
  from (values ('Abu Dhabi'), ('Dubai'), ('Sharjah'), ('Ajman'), ('Umm Al Quwain'), ('Ras Al Khaimah'), ('Fujairah')) as v(name)
  where lower(v.name) = lower(btrim(p_emirate));
$$;

revoke all on function public._canonical_emirate(text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- get_entity_dependency_summary: what would be affected by
-- inactivating an entity (p_location_id null) or one location.
-- ------------------------------------------------------------
create or replace function public.get_entity_dependency_summary(p_entity_id uuid, p_location_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_entity uuid := p_entity_id;
  v_loc_entity uuid;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_result jsonb;
begin
  if p_location_id is not null then
    select l.entity_id into v_loc_entity from public.locations l where l.id = p_location_id;
    if v_loc_entity is null then
      raise exception 'Location not found' using errcode = 'P0002';
    end if;
    if v_entity is not null and v_entity <> v_loc_entity then
      raise exception 'Location does not belong to the given entity' using errcode = '22023';
    end if;
    v_entity := v_loc_entity;
  end if;

  if v_entity is null or not exists (select 1 from public.entities e where e.id = v_entity) then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;

  if not (v_role = 'owner' or (v_role = 'entity_admin' and v_entity = public.my_entity())) then
    raise exception 'Not authorized to view dependencies for this entity' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'entity_id', v_entity,
    'location_id', p_location_id,
    'active_employees', (
      select count(*) from public.employees e
      where e.entity_id = v_entity
        and e.employment_status in ('active', 'pre_boarding')
        and (p_location_id is null or e.home_location_id = p_location_id)
    ),
    'future_shifts', (
      select count(*) from public.shifts s
      where s.entity_id = v_entity
        and s.shift_date >= v_today
        and s.status <> 'cancelled'
        and (p_location_id is null or s.location_id = p_location_id)
    ),
    'open_leave_requests', (
      select count(*) from public.leave_requests lr
      join public.employees e on e.id = lr.employee_id
      where e.entity_id = v_entity
        and lr.status = 'pending'
        and (p_location_id is null or e.home_location_id = p_location_id)
    ),
    -- Payroll runs are entity-scoped; for a location this is the entity's count.
    'draft_payroll_runs', (
      select count(*) from public.payroll_runs pr
      where pr.entity_id = v_entity and pr.status in ('draft', 'in_review')
    )
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_entity_dependency_summary(uuid, uuid) from public, anon;
grant execute on function public.get_entity_dependency_summary(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- admin_upsert_entity: owner only. p_id null = create.
-- Full-replacement semantics for optional fields on update
-- (null clears trade_license_no / emirate / payroll_day);
-- name and code are required; null currency keeps/defaults AED;
-- null is_active keeps the current value (true on create).
-- Inactivation is refused while active/pre-boarding employees exist.
-- ------------------------------------------------------------
create or replace function public.admin_upsert_entity(
  p_id uuid,
  p_name text,
  p_code text,
  p_trade_license_no text,
  p_emirate text,
  p_default_currency text,
  p_payroll_day smallint,
  p_is_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.entities;
  v_new public.entities;
  v_code text := upper(nullif(btrim(p_code), ''));
  v_name text := nullif(btrim(p_name), '');
  v_emirate text;
  v_currency text := upper(nullif(btrim(p_default_currency), ''));
  v_id uuid;
  v_active_emps integer;
  v_action text;
begin
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only an owner can create or change entities' using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'Entity name is required' using errcode = '22023';
  end if;
  if v_code is null then
    raise exception 'Entity code is required' using errcode = '22023';
  end if;
  if v_code !~ '^[A-Z0-9][A-Z0-9_-]{1,11}$' then
    raise exception 'Entity code must be 2-12 characters: letters, digits, _ or -' using errcode = '22023';
  end if;
  if p_emirate is not null and btrim(p_emirate) <> '' then
    v_emirate := public._canonical_emirate(p_emirate);
    if v_emirate is null then
      raise exception 'Unknown emirate: %', p_emirate using errcode = '22023';
    end if;
  end if;
  if v_currency is not null and v_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a 3-letter ISO code' using errcode = '22023';
  end if;
  if p_payroll_day is not null and (p_payroll_day < 1 or p_payroll_day > 28) then
    raise exception 'Payroll day must be between 1 and 28' using errcode = '22023';
  end if;
  if exists (select 1 from public.entities e where e.code = v_code and e.id is distinct from p_id) then
    raise exception 'Entity code % is already in use', v_code using errcode = '23505';
  end if;

  if p_id is null then
    insert into public.entities (name, code, trade_license_no, emirate, default_currency, payroll_day, is_active)
    values (v_name, v_code, nullif(btrim(p_trade_license_no), ''), v_emirate, coalesce(v_currency, 'AED'), p_payroll_day, coalesce(p_is_active, true))
    returning * into v_new;
    v_action := 'entity_created';
  else
    select * into v_old from public.entities where id = p_id for update;
    if v_old.id is null then
      raise exception 'Entity not found' using errcode = 'P0002';
    end if;

    if coalesce(p_is_active, v_old.is_active) = false and v_old.is_active then
      select count(*) into v_active_emps from public.employees e
      where e.entity_id = p_id and e.employment_status in ('active', 'pre_boarding');
      if v_active_emps > 0 then
        raise exception 'Cannot inactivate an entity with % active or pre-boarding employee(s); inactivate or move them first (see get_entity_dependency_summary)', v_active_emps
          using errcode = '23503';
      end if;
    end if;

    update public.entities set
      name = v_name,
      code = v_code,
      trade_license_no = nullif(btrim(p_trade_license_no), ''),
      emirate = v_emirate,
      default_currency = coalesce(v_currency, v_old.default_currency, 'AED'),
      payroll_day = p_payroll_day,
      is_active = coalesce(p_is_active, v_old.is_active),
      updated_at = now()
    where id = p_id
    returning * into v_new;

    v_action := case
      when v_old.is_active and not v_new.is_active then 'entity_deactivated'
      when not v_old.is_active and v_new.is_active then 'entity_reactivated'
      else 'entity_updated' end;
  end if;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id)
  values ('entities', v_new.id, auth.uid(), v_action,
    case when v_old.id is null then null else to_jsonb(v_old) end,
    to_jsonb(v_new), v_new.id);

  return v_new.id;
end;
$$;

revoke all on function public.admin_upsert_entity(uuid, text, text, text, text, text, smallint, boolean) from public, anon;
grant execute on function public.admin_upsert_entity(uuid, text, text, text, text, text, smallint, boolean) to authenticated;

-- ------------------------------------------------------------
-- admin_upsert_location: owner, or entity_admin of that entity.
-- p_id null = create. A location cannot be moved between entities.
-- Inactivation refused while active/pre-boarding employees are
-- homed there. New locations cannot be added to inactive entities.
-- ------------------------------------------------------------
create or replace function public.admin_upsert_location(
  p_id uuid,
  p_entity_id uuid,
  p_name text,
  p_code text,
  p_address text,
  p_is_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_old public.locations;
  v_new public.locations;
  v_entity public.entities;
  v_name text := nullif(btrim(p_name), '');
  v_code text := upper(nullif(btrim(p_code), ''));
  v_active_emps integer;
  v_action text;
begin
  if p_id is not null then
    select * into v_old from public.locations where id = p_id for update;
    if v_old.id is null then
      raise exception 'Location not found' using errcode = 'P0002';
    end if;
    if p_entity_id is not null and p_entity_id <> v_old.entity_id then
      raise exception 'A location cannot be moved to a different entity' using errcode = '22023';
    end if;
  end if;

  select * into v_entity from public.entities where id = coalesce(p_entity_id, v_old.entity_id);
  if v_entity.id is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;

  if not (v_role = 'owner' or (v_role = 'entity_admin' and v_entity.id = public.my_entity())) then
    raise exception 'Not authorized to manage locations for this entity' using errcode = '42501';
  end if;

  if v_name is null then
    raise exception 'Location name is required' using errcode = '22023';
  end if;
  if v_code is not null and v_code !~ '^[A-Z0-9][A-Z0-9_-]{1,11}$' then
    raise exception 'Location code must be 2-12 characters: letters, digits, _ or -' using errcode = '22023';
  end if;
  if v_code is not null and exists (
    select 1 from public.locations l where l.entity_id = v_entity.id and l.code = v_code and l.id is distinct from p_id
  ) then
    raise exception 'Location code % is already used in this entity', v_code using errcode = '23505';
  end if;

  if p_id is null then
    if not v_entity.is_active then
      raise exception 'Cannot add a location to an inactive entity' using errcode = '22023';
    end if;
    insert into public.locations (entity_id, name, code, address, is_active)
    values (v_entity.id, v_name, v_code, nullif(btrim(p_address), ''), coalesce(p_is_active, true))
    returning * into v_new;
    v_action := 'location_created';
  else
    if coalesce(p_is_active, v_old.is_active) = false and v_old.is_active then
      select count(*) into v_active_emps from public.employees e
      where e.home_location_id = p_id and e.employment_status in ('active', 'pre_boarding');
      if v_active_emps > 0 then
        raise exception 'Cannot inactivate a location with % active or pre-boarding employee(s) homed there (see get_entity_dependency_summary)', v_active_emps
          using errcode = '23503';
      end if;
    end if;
    if coalesce(p_is_active, v_old.is_active) and not v_old.is_active and not v_entity.is_active then
      raise exception 'Reactivate the entity before reactivating its locations' using errcode = '22023';
    end if;

    update public.locations set
      name = v_name,
      code = v_code,
      address = nullif(btrim(p_address), ''),
      is_active = coalesce(p_is_active, v_old.is_active),
      updated_at = now()
    where id = p_id
    returning * into v_new;

    v_action := case
      when v_old.is_active and not v_new.is_active then 'location_deactivated'
      when not v_old.is_active and v_new.is_active then 'location_reactivated'
      else 'location_updated' end;
  end if;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id)
  values ('locations', v_new.id, auth.uid(), v_action,
    case when v_old.id is null then null else to_jsonb(v_old) end,
    to_jsonb(v_new), v_new.entity_id, v_new.id);

  return v_new.id;
end;
$$;

revoke all on function public.admin_upsert_location(uuid, uuid, text, text, text, boolean) from public, anon;
grant execute on function public.admin_upsert_location(uuid, uuid, text, text, text, boolean) to authenticated;
