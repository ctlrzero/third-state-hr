-- Fix: fill_my_requested_profile_info built its 'updated' list with text[] || 'literal', which Postgres reads
-- as array || array and fails. Use array_append.

create or replace function public.fill_my_requested_profile_info(p_values jsonb)
returns jsonb
language plpgsql security definer
set search_path to ''
as $function$
declare
  v_emp uuid := public.my_employee_id();
  e public.employees;
  v_allowed text[];
  v_phone text := nullif(btrim(coalesce(p_values->>'phone', '')), '');
  v_ec_name text := nullif(btrim(coalesce(p_values->>'emergency_contact_name', '')), '');
  v_ec_phone text := nullif(btrim(coalesce(p_values->>'emergency_contact_phone', '')), '');
  v_nat text := nullif(btrim(coalesce(p_values->>'nationality', '')), '');
  v_addr text := nullif(btrim(coalesce(p_values->>'residential_address', '')), '');
  v_dob date;
  v_updated text[] := '{}';
  v_closed int;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if v_emp is null then raise exception 'Your account is not linked to an employee record' using errcode = '42501'; end if;
  select * into e from public.employees where id = v_emp for update;
  select array_agg(distinct f) into v_allowed
    from public.employee_requests r, unnest(r.fields) f
   where r.employee_id = v_emp and r.status = 'open' and r.kind = 'profile_info';
  if v_allowed is null then raise exception 'Nobody has asked you for profile details right now' using errcode = '22023'; end if;

  begin
    v_dob := nullif(btrim(coalesce(p_values->>'dob', '')), '')::date;
  exception when others then
    raise exception 'Enter your date of birth as a date' using errcode = '22023';
  end;

  if v_phone is not null and v_phone !~ '^\+?[0-9 ()-]{6,20}$' then
    raise exception 'Enter a phone number with digits only, for example +971 50 123 4567' using errcode = '22023';
  end if;
  if v_ec_phone is not null and v_ec_phone !~ '^\+?[0-9 ()-]{6,20}$' then
    raise exception 'Enter the emergency contact phone with digits only' using errcode = '22023';
  end if;
  if v_dob is not null and (v_dob > (now() at time zone 'Asia/Dubai')::date - interval '14 years' or v_dob < date '1930-01-01') then
    raise exception 'Please check your date of birth' using errcode = '22023';
  end if;
  if greatest(length(v_ec_name), length(v_nat)) > 100 or length(v_addr) > 300 then
    raise exception 'One of the answers is too long' using errcode = '22023';
  end if;

  if 'phone' = any(v_allowed) and public._emp_req_field_missing(e, 'phone') and v_phone is not null then
    e.phone := v_phone; v_updated := array_append(v_updated, 'phone');
  end if;
  if 'emergency_contact' = any(v_allowed) and public._emp_req_field_missing(e, 'emergency_contact') then
    if v_ec_name is not null and nullif(btrim(coalesce(e.emergency_contact_name, '')), '') is null then
      e.emergency_contact_name := v_ec_name; v_updated := array_append(v_updated, 'emergency_contact_name');
    end if;
    if v_ec_phone is not null and nullif(btrim(coalesce(e.emergency_contact_phone, '')), '') is null then
      e.emergency_contact_phone := v_ec_phone; v_updated := array_append(v_updated, 'emergency_contact_phone');
    end if;
  end if;
  if 'dob' = any(v_allowed) and e.dob is null and v_dob is not null then
    e.dob := v_dob; v_updated := array_append(v_updated, 'dob');
  end if;
  if 'nationality' = any(v_allowed) and public._emp_req_field_missing(e, 'nationality') and v_nat is not null then
    e.nationality := v_nat; v_updated := array_append(v_updated, 'nationality');
  end if;
  if 'residential_address' = any(v_allowed) and public._emp_req_field_missing(e, 'residential_address') and v_addr is not null then
    e.residential_address := v_addr; v_updated := array_append(v_updated, 'residential_address');
  end if;

  if cardinality(v_updated) = 0 then
    raise exception 'Please fill in the details you were asked for' using errcode = '22023';
  end if;

  update public.employees
     set phone = e.phone, emergency_contact_name = e.emergency_contact_name, emergency_contact_phone = e.emergency_contact_phone,
         dob = e.dob, nationality = e.nationality, residential_address = e.residential_address
   where id = v_emp;
  v_closed := public._emp_req_check(v_emp);  -- the trigger already did it; this just counts (0 if done)
  return jsonb_build_object('ok', true, 'updated', to_jsonb(v_updated),
    'still_open', (select count(*) from public.employee_requests where employee_id = v_emp and status = 'open' and kind = 'profile_info'));
end;
$function$;
