-- Migration 010 — activation guard. Deployed together with the onboarding UI
-- (feat/payroll-v2 + feat/onboarding merged to main and confirmed live at
-- hr.thirdstate.ae before this was applied). Body = live set_employee_status
-- + the guard block marked "ONBOARDING GUARD". Nothing else changed.
create or replace function public.set_employee_status(p_employee_id uuid, p_new_status public.employee_status, p_reason text)
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

  -- ONBOARDING GUARD: first activation only through approve_and_activate_employee(),
  -- which sets app.onboarding_activation to a ready instance of this employee.
  if v_emp.employment_status = 'pre_boarding' and p_new_status = 'active' then
    if not exists (
      select 1 from public.onboarding_instances oi
       where oi.employee_id = v_emp.id
         and oi.id::text = coalesce(current_setting('app.onboarding_activation', true), '')
         and oi.status = 'ready_for_activation'
    ) then
      raise exception 'Pre-boarding employees are activated from their onboarding (Approve and activate)'
        using errcode = '42501',
              hint = 'Open Onboarding, resolve the blocking items, then use Approve and activate.';
    end if;
  end if;
  -- END ONBOARDING GUARD

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
$function$;;
