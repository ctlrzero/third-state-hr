-- ============================================================
-- W5: activation requires key documents.
--  * employee_missing_key_documents(p_employee_id): internal helper,
--    returns the key documents (passport, visa, emirates_id, contract)
--    that do not have a current, approved, unexpired version.
--    Visa is waived for UAE nationals (nationality UAE / Emirati /
--    United Arab Emirates, case-insensitive).
--  * set_employee_status: any move to 'active' (pre_boarding -> active
--    and inactive -> active reactivation) is refused with 22023 while
--    any key document is missing. No override.
--  * get_employee_completeness: uses the same helper, so the profile
--    bar and the activation gate always agree (visa waiver included).
-- ============================================================

create or replace function public.employee_missing_key_documents(p_employee_id uuid)
returns text[]
language sql
stable
set search_path to ''
as $function$
  select coalesce(array_agg(d.doc || '_document' order by d.ord), array[]::text[])
  from unnest(array['passport', 'visa', 'emirates_id', 'contract']::text[]) with ordinality as d(doc, ord)
  where not (
      d.doc = 'visa'
      and exists (
        select 1 from public.employees e
        where e.id = p_employee_id
          and lower(btrim(coalesce(e.nationality, ''))) in ('uae', 'emirati', 'united arab emirates')
      )
    )
    and not exists (
      select 1 from public.employee_documents ed
      where ed.employee_id = p_employee_id
        and ed.doc_type = d.doc::public.document_type
        and ed.is_current
        and ed.review_status = 'approved'
        and (ed.expiry_date is null or ed.expiry_date >= (now() at time zone 'Asia/Dubai')::date)
    );
$function$;

revoke all on function public.employee_missing_key_documents(uuid) from public, anon, authenticated;

create or replace function public.get_employee_completeness(p_employee_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  v_emp public.employees;
  v_missing text[] := array[]::text[];
  v_total integer := 8;
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
    v_missing := array_append(v_missing, 'contact'::text);
  end if;
  if v_emp.emergency_contact_name is null or v_emp.emergency_contact_phone is null then
    v_missing := array_append(v_missing, 'emergency_contact'::text);
  end if;
  if v_emp.position_id is null then
    v_missing := array_append(v_missing, 'position'::text);
  end if;
  if v_emp.join_date is null then
    v_missing := array_append(v_missing, 'join_date'::text);
  end if;

  v_missing := v_missing || public.employee_missing_key_documents(p_employee_id);

  return jsonb_build_object(
    'percent', round(100.0 * (v_total - cardinality(v_missing)) / v_total)::integer,
    'missing', to_jsonb(v_missing),
    'total', v_total,
    'complete', v_total - cardinality(v_missing)
  );
end;
$function$;

create or replace function public.set_employee_status(p_employee_id uuid, p_new_status employee_status, p_reason text)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
  v_missing_docs text[];
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

  if p_new_status = 'active' then
    v_missing_docs := public.employee_missing_key_documents(p_employee_id);
    if cardinality(v_missing_docs) > 0 then
      raise exception 'Cannot activate: approved, unexpired key documents are missing (%)',
        array_to_string(v_missing_docs, ', ')
        using errcode = '22023',
              hint = 'Upload and approve the missing documents on the employee''s Documents tab, then activate.';
    end if;
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
$function$;

revoke all on function public.set_employee_status(uuid, public.employee_status, text) from public, anon;
grant execute on function public.set_employee_status(uuid, public.employee_status, text) to authenticated;
revoke all on function public.get_employee_completeness(uuid) from public, anon;
grant execute on function public.get_employee_completeness(uuid) to authenticated;
