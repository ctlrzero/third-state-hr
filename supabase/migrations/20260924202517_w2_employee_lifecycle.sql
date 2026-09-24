-- ============================================================
-- W2 Employee lifecycle:
--   set_employee_status, update_employee_details (whitelisted,
--   role-scoped, before/after audited), get_employee_completeness.
-- Direct UPDATE/DELETE on employees is revoked from authenticated
-- (no hard deletes; field whitelists cannot be bypassed), and direct
-- INSERT is narrowed to non-privileged columns (auth_user_id and
-- employment_status can no longer be set by a client insert).
-- ============================================================

revoke update, delete on table public.employees from authenticated;
revoke insert on table public.employees from authenticated;
grant insert (entity_id, home_location_id, position_id, full_name, preferred_name, photo_url, dob, gender,
              nationality, phone, email, emergency_contact_name, emergency_contact_phone, passport_exp,
              visa_exp, labor_card_exp, health_card_exp, employment_type, join_date, probation_end_date, notes)
  on table public.employees to authenticated;

-- ------------------------------------------------------------
-- set_employee_status
--   candidate -> pre_boarding -> active; any of those -> inactive;
--   inactive -> active (owner/entity_admin only).
--   location_manager: pre_boarding -> active for own location only.
--   Going inactive: reason required; linked login deactivated;
--   future UNPUBLISHED shifts cancelled; history untouched.
--   Reactivation does NOT restore the login (use admin_grant_access).
-- ------------------------------------------------------------
create or replace function public.set_employee_status(
  p_employee_id uuid,
  p_new_status public.employee_status,
  p_reason text
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_emp public.employees;
  v_reason text := nullif(btrim(p_reason), '');
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_allowed boolean;
  v_cancelled integer := 0;
  v_published_left integer := 0;
  v_profile public.profiles;
  v_profile_deactivated boolean := false;
begin
  if v_role is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_new_status is null then
    raise exception 'A new status is required' using errcode = '22023';
  end if;

  select * into v_emp from public.employees where id = p_employee_id for update;
  if v_emp.id is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = public.my_location())
  ) then
    raise exception 'Not authorized to change this employee''s status' using errcode = '42501';
  end if;

  if v_emp.id = public.my_employee_id() then
    raise exception 'You cannot change your own employment status' using errcode = '42501';
  end if;

  if v_emp.employment_status = p_new_status then
    raise exception 'Employee is already %', p_new_status using errcode = '22023';
  end if;

  v_allowed := case
    when v_emp.employment_status = 'candidate' and p_new_status in ('pre_boarding', 'inactive') then true
    when v_emp.employment_status = 'pre_boarding' and p_new_status in ('active', 'inactive') then true
    when v_emp.employment_status = 'active' and p_new_status = 'inactive' then true
    when v_emp.employment_status = 'inactive' and p_new_status = 'active' then true
    else false
  end;
  if not v_allowed then
    raise exception 'Status change % -> % is not allowed', v_emp.employment_status, p_new_status using errcode = '22023';
  end if;

  if v_role = 'location_manager' and not (v_emp.employment_status = 'pre_boarding' and p_new_status = 'active') then
    raise exception 'Location managers can only activate pre-boarding employees' using errcode = '42501';
  end if;
  if v_emp.employment_status = 'inactive' and v_role not in ('owner', 'entity_admin') then
    raise exception 'Only an owner or entity admin can reactivate an employee' using errcode = '42501';
  end if;
  if (p_new_status = 'inactive' or v_emp.employment_status = 'inactive') and v_reason is null then
    raise exception 'A reason is required to inactivate or reactivate an employee' using errcode = '22023';
  end if;

  if p_new_status = 'inactive' and v_emp.auth_user_id is not null then
    select * into v_profile from public.profiles where id = v_emp.auth_user_id for update;
    if v_profile.id is not null and v_profile.role = 'owner' and v_role <> 'owner' then
      raise exception 'Only an owner can inactivate an employee linked to an owner login' using errcode = '42501';
    end if;
  end if;

  update public.employees set employment_status = p_new_status, updated_at = now() where id = p_employee_id;

  if p_new_status = 'inactive' then
    -- Revoke the linked login (keeps the profile row for history).
    if v_profile.id is not null and v_profile.is_active then
      update public.profiles
         set is_active = false, deactivated_at = now(), deactivated_by = auth.uid(),
             deactivation_reason = 'Employee inactivated: ' || v_reason
       where id = v_profile.id;
      update public.access_grants
         set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
             revoke_reason = 'Employee inactivated: ' || v_reason, updated_at = now()
       where applied_user_id = v_profile.id and status = 'applied';
      v_profile_deactivated := true;
    end if;
    -- Pending grants for this employee can no longer be applied.
    update public.access_grants
       set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
           revoke_reason = 'Employee inactivated: ' || v_reason, updated_at = now()
     where employee_id = p_employee_id and status = 'pending';

    -- Cancel future draft (unpublished) shifts; published history and
    -- published future shifts are left for the manager to reassign.
    update public.shifts
       set status = 'cancelled'
     where employee_id = p_employee_id
       and shift_date > v_today
       and is_published = false
       and status <> 'cancelled';
    get diagnostics v_cancelled = row_count;

    select count(*) into v_published_left
      from public.shifts s
     where s.employee_id = p_employee_id and s.shift_date > v_today
       and s.is_published and s.status <> 'cancelled';
  end if;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('employees', p_employee_id, auth.uid(),
    case when p_new_status = 'inactive' then 'employee_deactivated'
         when v_emp.employment_status = 'inactive' then 'employee_reactivated'
         else 'employee_status_changed' end,
    jsonb_build_object('employment_status', v_emp.employment_status),
    jsonb_build_object('employment_status', p_new_status, 'reason', v_reason, 'actor_role', v_role,
                       'login_deactivated', v_profile_deactivated,
                       'draft_future_shifts_cancelled', v_cancelled,
                       'published_future_shifts_remaining', v_published_left),
    v_emp.entity_id, v_emp.home_location_id, p_employee_id);
end;
$$;

revoke all on function public.set_employee_status(uuid, public.employee_status, text) from public, anon;
grant execute on function public.set_employee_status(uuid, public.employee_status, text) to authenticated;

-- ------------------------------------------------------------
-- update_employee_details: whitelisted, role-scoped field edits.
-- ------------------------------------------------------------
create or replace function public.update_employee_details(p_employee_id uuid, p_changes jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_old public.employees;
  v_new public.employees;
  v_all_fields text[] := array[
    'full_name', 'preferred_name', 'photo_url', 'dob', 'gender', 'nationality', 'phone', 'email',
    'emergency_contact_name', 'emergency_contact_phone', 'passport_exp', 'visa_exp', 'labor_card_exp',
    'health_card_exp', 'employment_type', 'join_date', 'probation_end_date', 'notes', 'position_id',
    'home_location_id'
  ];
  v_manager_fields text[] := array[
    'phone', 'email', 'emergency_contact_name', 'emergency_contact_phone', 'preferred_name', 'position_id'
  ];
  v_keys text[];
  v_unknown text[];
  v_forbidden text[];
  v_changes jsonb;
  v_old_diff jsonb := '{}'::jsonb;
  v_new_diff jsonb := '{}'::jsonb;
  k text;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin', 'location_manager') then
    raise exception 'Not authorized to edit employee details' using errcode = '42501';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'p_changes must be a non-empty JSON object' using errcode = '22023';
  end if;

  select * into v_old from public.employees where id = p_employee_id for update;
  if v_old.id is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;
  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_old.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v_old.home_location_id = public.my_location())
  ) then
    raise exception 'Not authorized to edit this employee' using errcode = '42501';
  end if;

  select array_agg(key order by key) into v_keys from jsonb_object_keys(p_changes) as key;
  select array_agg(x order by x) into v_unknown from unnest(v_keys) x where not (x = any (v_all_fields));
  if v_unknown is not null then
    raise exception 'Unknown or non-editable field(s): %', array_to_string(v_unknown, ', ') using errcode = '22023';
  end if;
  if v_role = 'location_manager' then
    select array_agg(x order by x) into v_forbidden from unnest(v_keys) x where not (x = any (v_manager_fields));
    if v_forbidden is not null then
      raise exception 'Location managers cannot edit: %', array_to_string(v_forbidden, ', ') using errcode = '42501';
    end if;
  end if;

  -- Normalise strings: trim, empty string -> null.
  select jsonb_object_agg(key,
           case when jsonb_typeof(value) = 'string' and btrim(value #>> '{}') = '' then 'null'::jsonb
                when jsonb_typeof(value) = 'string' then to_jsonb(btrim(value #>> '{}'))
                else value end)
    into v_changes
    from jsonb_each(p_changes);

  if v_changes ? 'email' and v_changes->>'email' is not null then
    v_changes := jsonb_set(v_changes, '{email}', to_jsonb(lower(v_changes->>'email')));
    if (v_changes->>'email') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      raise exception 'Invalid email address' using errcode = '22023';
    end if;
  end if;
  if v_changes ? 'full_name' and v_changes->>'full_name' is null then
    raise exception 'full_name cannot be empty' using errcode = '22023';
  end if;
  if v_changes ? 'gender' and v_changes->>'gender' is not null and v_changes->>'gender' not in ('female', 'male') then
    raise exception 'gender must be female or male' using errcode = '22023';
  end if;

  v_new := jsonb_populate_record(v_old, v_changes);

  if v_new.position_id is distinct from v_old.position_id and v_new.position_id is not null
     and not exists (select 1 from public.positions po where po.id = v_new.position_id and po.entity_id = v_old.entity_id) then
    raise exception 'Position does not belong to this employee''s entity' using errcode = '22023';
  end if;
  if v_new.home_location_id is distinct from v_old.home_location_id and v_new.home_location_id is not null
     and not exists (select 1 from public.locations l where l.id = v_new.home_location_id and l.entity_id = v_old.entity_id and l.is_active) then
    raise exception 'Home location must be an active location of this employee''s entity' using errcode = '22023';
  end if;
  if v_new.probation_end_date is not null and v_new.join_date is not null and v_new.probation_end_date < v_new.join_date then
    raise exception 'Probation end date cannot be before the join date' using errcode = '22023';
  end if;

  foreach k in array v_keys loop
    if (to_jsonb(v_old) -> k) is distinct from (to_jsonb(v_new) -> k) then
      v_old_diff := v_old_diff || jsonb_build_object(k, to_jsonb(v_old) -> k);
      v_new_diff := v_new_diff || jsonb_build_object(k, to_jsonb(v_new) -> k);
    end if;
  end loop;

  if v_new_diff = '{}'::jsonb then
    return; -- nothing actually changed
  end if;

  update public.employees set
    full_name = v_new.full_name,
    preferred_name = v_new.preferred_name,
    photo_url = v_new.photo_url,
    dob = v_new.dob,
    gender = v_new.gender,
    nationality = v_new.nationality,
    phone = v_new.phone,
    email = v_new.email,
    emergency_contact_name = v_new.emergency_contact_name,
    emergency_contact_phone = v_new.emergency_contact_phone,
    passport_exp = v_new.passport_exp,
    visa_exp = v_new.visa_exp,
    labor_card_exp = v_new.labor_card_exp,
    health_card_exp = v_new.health_card_exp,
    employment_type = v_new.employment_type,
    join_date = v_new.join_date,
    probation_end_date = v_new.probation_end_date,
    notes = v_new.notes,
    position_id = v_new.position_id,
    home_location_id = v_new.home_location_id,
    updated_at = now()
  where id = p_employee_id;

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
  values ('employees', p_employee_id, auth.uid(), 'employee_details_updated',
    v_old_diff, v_new_diff || jsonb_build_object('actor_role', v_role),
    v_old.entity_id, coalesce(v_new.home_location_id, v_old.home_location_id), p_employee_id);
end;
$$;

revoke all on function public.update_employee_details(uuid, jsonb) from public, anon;
grant execute on function public.update_employee_details(uuid, jsonb) to authenticated;

-- ------------------------------------------------------------
-- get_employee_completeness: {percent, missing[], total, complete}
-- Required: contact (phone + email), emergency contact (name + phone),
-- position, join_date, and a current (approved, not expired) passport,
-- visa, emirates_id and contract document. Only presence is reported,
-- never document contents or numbers.
-- ------------------------------------------------------------
create or replace function public.get_employee_completeness(p_employee_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_emp public.employees;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_missing text[] := array[]::text[];
  v_total integer := 8;
  d text;
begin
  select * into v_emp from public.employees where id = p_employee_id;
  if v_emp.id is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;
  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = public.my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = public.my_location())
    or v_emp.id = public.my_employee_id()
  ) then
    raise exception 'Not authorized to view this employee' using errcode = '42501';
  end if;

  if v_emp.phone is null or v_emp.email is null then
    v_missing := v_missing || 'contact';
  end if;
  if v_emp.emergency_contact_name is null or v_emp.emergency_contact_phone is null then
    v_missing := v_missing || 'emergency_contact';
  end if;
  if v_emp.position_id is null then
    v_missing := v_missing || 'position';
  end if;
  if v_emp.join_date is null then
    v_missing := v_missing || 'join_date';
  end if;

  foreach d in array array['passport', 'visa', 'emirates_id', 'contract'] loop
    if not exists (
      select 1 from public.employee_documents ed
      where ed.employee_id = p_employee_id
        and ed.doc_type = d::public.document_type
        and ed.is_current
        and ed.review_status = 'approved'
        and (ed.expiry_date is null or ed.expiry_date >= v_today)
    ) then
      v_missing := v_missing || (d || '_document');
    end if;
  end loop;

  return jsonb_build_object(
    'percent', round(100.0 * (v_total - cardinality(v_missing)) / v_total)::integer,
    'missing', to_jsonb(v_missing),
    'total', v_total,
    'complete', v_total - cardinality(v_missing)
  );
end;
$$;

revoke all on function public.get_employee_completeness(uuid) from public, anon;
grant execute on function public.get_employee_completeness(uuid) to authenticated;
