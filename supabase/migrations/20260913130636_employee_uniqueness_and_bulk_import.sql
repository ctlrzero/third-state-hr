
-- ============================================================
-- BR-EMP-001 gap found while building bulk import: there is currently
-- NO uniqueness constraint on employees.email at all -- duplicate
-- emails within an entity would silently succeed today. Fixing this
-- at the database level (not just relying on app-layer checks),
-- consistent with "UI permissions do not replace server-side
-- permissions" already stated in CLAUDE.md for access control --
-- the same principle applies to data integrity constraints.
-- ============================================================

create unique index employees_entity_email_unique_idx
  on public.employees (entity_id, lower(email))
  where email is not null;

comment on index public.employees_entity_email_unique_idx is
  'BR-EMP-001: duplicate email within the same entity is rejected at the DB level. Case-insensitive. NULL emails (e.g. pre-boarding candidates without a work email yet) are not constrained against each other.';

-- ============================================================
-- BR-EMP-006 (Future, but scoped now): controlled bulk employee import.
-- Validates every row (entity/location/position ownership, required
-- fields, uniqueness) BEFORE committing anything -- if any row fails,
-- nothing is inserted, matching the acceptance criterion "Import
-- validates entity, branch, role, uniqueness and errors before commit."
-- ============================================================

create or replace function public.bulk_import_employees(p_entity_id uuid, p_rows jsonb)
returns table (row_index integer, success boolean, employee_id uuid, errors text[])
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row jsonb;
  v_idx integer := 0;
  v_errors text[];
  v_any_failed boolean := false;
  v_home_location_id uuid;
  v_position_id uuid;
  v_email text;
  v_new_id uuid;
  results record;
  temp_results uuid[] := array[]::uuid[];
begin
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and p_entity_id = my_entity())) then
    raise exception 'Not authorized to bulk import employees for this entity';
  end if;
  if p_entity_id is null or (select id from entities where id = p_entity_id) is null then
    raise exception 'Unknown entity_id %', p_entity_id;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a JSON array of employee objects';
  end if;

  -- Temp table to hold validated rows across the two passes
  create temporary table _bulk_import_staging (
    row_index integer, full_name text, email text, gender text,
    home_location_id uuid, position_id uuid, employment_type text,
    join_date date, errors text[]
  ) on commit drop;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_idx := v_idx + 1;
    v_errors := array[]::text[];

    if coalesce(trim(v_row->>'full_name'), '') = '' then
      v_errors := v_errors || 'full_name is required';
    end if;

    v_email := nullif(trim(v_row->>'email'), '');
    if v_email is not null and exists (
      select 1 from employees where entity_id = p_entity_id and lower(email) = lower(v_email)
    ) then
      v_errors := v_errors || format('email %s already exists in this entity', v_email);
    end if;
    if v_email is not null and exists (
      select 1 from jsonb_array_elements(p_rows) with ordinality as r(val, ord)
      where lower(r.val->>'email') = lower(v_email) and r.ord <> v_idx
    ) then
      v_errors := v_errors || format('email %s is duplicated within this import batch', v_email);
    end if;

    v_home_location_id := nullif(v_row->>'home_location_id','')::uuid;
    if v_home_location_id is not null and not exists (
      select 1 from locations where id = v_home_location_id and entity_id = p_entity_id
    ) then
      v_errors := v_errors || format('home_location_id %s does not belong to this entity', v_home_location_id);
    end if;

    v_position_id := nullif(v_row->>'position_id','')::uuid;
    if v_position_id is not null and not exists (
      select 1 from positions where id = v_position_id and entity_id = p_entity_id
    ) then
      v_errors := v_errors || format('position_id %s does not belong to this entity', v_position_id);
    end if;

    if v_row ? 'employment_type' and nullif(v_row->>'employment_type','') is not null
       and not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'employment_type' and e.enumlabel = v_row->>'employment_type') then
      v_errors := v_errors || format('employment_type %s is not a valid value', v_row->>'employment_type');
    end if;

    if array_length(v_errors, 1) > 0 then
      v_any_failed := true;
    end if;

    insert into _bulk_import_staging(row_index, full_name, email, gender, home_location_id, position_id, employment_type, join_date, errors)
    values (v_idx, v_row->>'full_name', v_email, nullif(v_row->>'gender',''), v_home_location_id, v_position_id,
            nullif(v_row->>'employment_type',''), nullif(v_row->>'join_date','')::date, v_errors);
  end loop;

  if v_any_failed then
    -- Nothing committed: return every row's validation result as-is.
    return query select s.row_index, (array_length(s.errors,1) is null), null::uuid, s.errors
      from _bulk_import_staging s order by s.row_index;
    return;
  end if;

  -- All rows valid: commit them all.
  for results in select * from _bulk_import_staging order by row_index
  loop
    insert into employees (entity_id, full_name, email, gender, home_location_id, position_id, employment_type, join_date, employment_status)
    values (p_entity_id, results.full_name, results.email, results.gender, results.home_location_id, results.position_id,
            coalesce(results.employment_type, 'full_time')::employment_type, results.join_date, 'pre_boarding')
    returning id into v_new_id;

    insert into audit_log(table_name, record_id, changed_by, action, new_value, entity_id)
    values ('employees', v_new_id, auth.uid(), 'bulk_import_created', jsonb_build_object('full_name', results.full_name, 'email', results.email), p_entity_id);

    return query select results.row_index, true, v_new_id, array[]::text[];
  end loop;
end;
$$;

comment on function public.bulk_import_employees(uuid, jsonb) is 'BR-EMP-006: validates every row (entity/location/position ownership, email uniqueness within-batch and against existing data, enum validity) before committing anything. Any row failing validation blocks the entire batch -- matches "errors before commit" acceptance criterion. All created employees land in pre_boarding status, same as manual creation.';
