-- Ask for the missing details the admin SELECTS (not everything):
--   get_missing_items(employee)            → what this employee is missing, item by item, and whether it was already asked
--   request_selected_missing(employee, keys[], note, due_date)
--   request_selected_missing_for_many(company, branch, keys[], note, due_date)   — same choice for a whole branch/company
-- Item keys: doc:passport | doc:visa | doc:emirates_id | doc:contract | payment | field:phone | field:emergency_contact |
--            field:dob | field:nationality | field:residential_address.
-- Everything goes through create_employee_request, so its rules apply (sender scope, restricted documents for
-- branch managers, no duplicate open requests, notifications, auto-close when done, daily reminders).
-- Only items that are actually missing for that person are sent; the rest are reported as "not missing".

create or replace function public._missing_item_label(p_key text)
returns text
language sql
immutable
set search_path to ''
as $function$
  select case p_key
    when 'doc:passport' then 'Passport'
    when 'doc:visa' then 'Visa'
    when 'doc:emirates_id' then 'Emirates ID'
    when 'doc:contract' then 'Contract'
    when 'payment' then 'Bank details'
    when 'field:phone' then 'Phone number'
    when 'field:emergency_contact' then 'Emergency contact'
    when 'field:dob' then 'Date of birth'
    when 'field:nationality' then 'Nationality'
    when 'field:residential_address' then 'Home address'
    else null end;
$function$;
revoke all on function public._missing_item_label(text) from public, anon, authenticated;

create or replace function public.get_missing_items(p_employee_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  e public.employees;
  v_items jsonb := '[]'::jsonb;
  v_doc text;
  f text;
  k text;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if v_role is null or v_role not in ('owner', 'entity_admin', 'location_manager') then
    raise exception using errcode = '42501', message = 'Only an owner, Company Admin or Branch Manager can do this';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception using errcode = 'P0002', message = 'Employee not found';
  end if;
  if not public._emp_req_can_manage(p_employee_id) then
    raise exception using errcode = '42501', message = 'You can only do this for employees in your branch';
  end if;

  foreach v_doc in array public.employee_missing_key_documents(e.id) loop
    v_doc := replace(v_doc, '_document', '');
    k := 'doc:' || v_doc;
    v_items := v_items || jsonb_build_object(
      'key', k, 'group', 'Documents', 'label', public._missing_item_label(k),
      'already_asked', exists (select 1 from public.employee_requests r where r.employee_id = e.id and r.status = 'open'
                                 and r.kind = 'document' and r.doc_type::text = v_doc),
      'can_request', not (v_role = 'location_manager' and public.is_restricted_doc_type(v_doc::public.document_type)));
  end loop;

  if not exists (select 1 from public.employee_payment_details d where d.employee_id = e.id and d.status = 'verified') then
    v_items := v_items || jsonb_build_object(
      'key', 'payment', 'group', 'Bank details', 'label', public._missing_item_label('payment'),
      'already_asked', exists (select 1 from public.employee_requests r where r.employee_id = e.id and r.status = 'open' and r.kind = 'payment_details'),
      'can_request', true);
  end if;

  foreach f in array array['phone', 'emergency_contact', 'dob', 'nationality', 'residential_address'] loop
    if public._emp_req_field_missing(e, f) then
      k := 'field:' || f;
      v_items := v_items || jsonb_build_object(
        'key', k, 'group', 'Personal details', 'label', public._missing_item_label(k),
        'already_asked', exists (select 1 from public.employee_requests r where r.employee_id = e.id and r.status = 'open'
                                   and r.kind = 'profile_info' and f = any (r.fields)),
        'can_request', true);
    end if;
  end loop;

  return jsonb_build_object('employee_id', e.id, 'employee', coalesce(e.preferred_name, e.full_name), 'items', v_items);
end;
$function$;
revoke all on function public.get_missing_items(uuid) from public, anon;
grant execute on function public.get_missing_items(uuid) to authenticated;

create or replace function public.request_selected_missing(
  p_employee_id uuid, p_keys text[], p_note text default null, p_due_date date default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  e public.employees;
  k text;
  v_docs text[];
  v_pay_missing boolean;
  v_fields text[] := '{}';
  v_created jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_not_missing jsonb := '[]'::jsonb;
  v_field_labels text[] := '{}';
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if public.my_role() is null or public.my_role() not in ('owner', 'entity_admin', 'location_manager') then
    raise exception using errcode = '42501', message = 'Only an owner, Company Admin or Branch Manager can send requests';
  end if;
  if p_keys is null or cardinality(p_keys) = 0 then
    raise exception using errcode = '22023', message = 'Choose what to ask for';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception using errcode = 'P0002', message = 'Employee not found';
  end if;
  if not public._emp_req_can_manage(p_employee_id) then
    raise exception using errcode = '42501', message = 'You can only send requests to employees in your branch';
  end if;

  v_docs := array(select replace(d, '_document', '') from unnest(public.employee_missing_key_documents(e.id)) d);
  v_pay_missing := not exists (select 1 from public.employee_payment_details d where d.employee_id = e.id and d.status = 'verified');

  foreach k in array (select array_agg(distinct x) from unnest(p_keys) x) loop
    if public._missing_item_label(k) is null then
      v_skipped := v_skipped || jsonb_build_object('item', k, 'reason', 'Unknown item');
    elsif k like 'doc:%' then
      if not (substr(k, 5) = any (v_docs)) then
        v_not_missing := v_not_missing || to_jsonb(public._missing_item_label(k));
      else
        begin
          perform public.create_employee_request(e.id, 'document', substr(k, 5)::public.document_type, null, p_note, p_due_date);
          v_created := v_created || to_jsonb(public._missing_item_label(k));
        exception when others then
          v_skipped := v_skipped || jsonb_build_object('item', public._missing_item_label(k), 'reason', sqlerrm);
        end;
      end if;
    elsif k = 'payment' then
      if not v_pay_missing then
        v_not_missing := v_not_missing || to_jsonb(public._missing_item_label(k));
      else
        begin
          perform public.create_employee_request(e.id, 'payment_details', null, null, p_note, p_due_date);
          v_created := v_created || to_jsonb(public._missing_item_label(k));
        exception when others then
          v_skipped := v_skipped || jsonb_build_object('item', public._missing_item_label(k), 'reason', sqlerrm);
        end;
      end if;
    else  -- field:*
      if not public._emp_req_field_missing(e, substr(k, 7)) then
        v_not_missing := v_not_missing || to_jsonb(public._missing_item_label(k));
      else
        v_fields := v_fields || substr(k, 7);
        v_field_labels := v_field_labels || public._missing_item_label(k);
      end if;
    end if;
  end loop;

  if cardinality(v_fields) > 0 then
    begin
      perform public.create_employee_request(e.id, 'profile_info', null, v_fields, p_note, p_due_date);
      v_created := v_created || to_jsonb(array_to_string(v_field_labels, ', '));
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('item', array_to_string(v_field_labels, ', '), 'reason', sqlerrm);
    end;
  end if;

  return jsonb_build_object('ok', true, 'employee', coalesce(e.preferred_name, e.full_name),
                            'created', v_created, 'skipped', v_skipped, 'not_missing', v_not_missing);
end;
$function$;
revoke all on function public.request_selected_missing(uuid, text[], text, date) from public, anon;
grant execute on function public.request_selected_missing(uuid, text[], text, date) to authenticated;

create or replace function public.request_selected_missing_for_many(
  p_entity_id uuid, p_location_id uuid, p_keys text[], p_note text default null, p_due_date date default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  v_loc uuid := p_location_id;
  r record;
  v_res jsonb;
  v_people int := 0;
  v_requests int := 0;
  v_skipped int := 0;
  v_names jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())) then
    raise exception using errcode = '42501', message = 'Only an owner, Company Admin or Branch Manager can send requests';
  end if;
  if p_keys is null or cardinality(p_keys) = 0 then
    raise exception using errcode = '22023', message = 'Choose what to ask for';
  end if;
  if v_role = 'location_manager' then
    v_loc := public.my_location();
  end if;

  for r in
    select e.id from public.employees e
    where e.entity_id = p_entity_id and e.employment_status in ('active', 'pre_boarding')
      and (v_loc is null or e.home_location_id = v_loc)
      and e.id is distinct from public.my_employee_id()
    order by e.full_name
  loop
    v_res := public.request_selected_missing(r.id, p_keys, p_note, p_due_date);
    if jsonb_array_length(v_res->'created') > 0 then
      v_people := v_people + 1;
      v_requests := v_requests + jsonb_array_length(v_res->'created');
      v_names := v_names || to_jsonb(v_res->>'employee');
    end if;
    v_skipped := v_skipped + jsonb_array_length(v_res->'skipped');
  end loop;

  return jsonb_build_object('ok', true, 'people', v_people, 'requests', v_requests, 'skipped', v_skipped, 'names', v_names);
end;
$function$;
revoke all on function public.request_selected_missing_for_many(uuid, uuid, text[], text, date) from public, anon;
grant execute on function public.request_selected_missing_for_many(uuid, uuid, text[], text, date) to authenticated;
