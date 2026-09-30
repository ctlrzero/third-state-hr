-- "Ask for everything missing": one tap per employee, or for a whole branch/company at once.
-- Works out what each employee is missing — key documents (passport, visa, Emirates ID, contract),
-- verified bank / payment details, and personal details (phone, emergency contact, date of birth,
-- nationality, home address) — and sends one request per item through create_employee_request, so every
-- existing rule applies (sender's scope, branch managers can't ask for restricted documents, no duplicate
-- open requests, notifications, auto-close when done, daily reminders when overdue).
-- Items that can't be requested are reported back, not treated as errors.

create or replace function public.request_all_missing(p_employee_id uuid, p_note text default null, p_due_date date default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  e public.employees;
  v_doc text;
  v_fields text[];
  v_created jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if public.my_role() not in ('owner', 'entity_admin', 'location_manager') then
    raise exception using errcode = '42501', message = 'Only an owner, Company Admin or Branch Manager can send requests';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then
    raise exception using errcode = 'P0002', message = 'Employee not found';
  end if;
  if not public._emp_req_can_manage(p_employee_id) then
    raise exception using errcode = '42501', message = 'You can only send requests to employees in your branch';
  end if;

  -- Key documents
  foreach v_doc in array public.employee_missing_key_documents(e.id) loop
    v_doc := replace(v_doc, '_document', '');
    begin
      perform public.create_employee_request(e.id, 'document', v_doc::public.document_type, null, p_note, p_due_date);
      v_created := v_created || to_jsonb(initcap(replace(v_doc, '_', ' ')));
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('item', initcap(replace(v_doc, '_', ' ')), 'reason', sqlerrm);
    end;
  end loop;

  -- Bank / payment details
  if not exists (select 1 from public.employee_payment_details d where d.employee_id = e.id and d.status = 'verified') then
    begin
      perform public.create_employee_request(e.id, 'payment_details', null, null, p_note, p_due_date);
      v_created := v_created || to_jsonb('Bank details'::text);
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('item', 'Bank details', 'reason', sqlerrm);
    end;
  end if;

  -- Personal details
  select array_agg(f) into v_fields
  from unnest(array['phone', 'emergency_contact', 'dob', 'nationality', 'residential_address']::text[]) f
  where public._emp_req_field_missing(e, f);
  if v_fields is not null then
    begin
      perform public.create_employee_request(e.id, 'profile_info', null, v_fields, p_note, p_due_date);
      v_created := v_created || to_jsonb('Personal details'::text);
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('item', 'Personal details', 'reason', sqlerrm);
    end;
  end if;

  return jsonb_build_object('ok', true, 'employee', coalesce(e.preferred_name, e.full_name),
                            'created', v_created, 'skipped', v_skipped);
end;
$function$;
revoke all on function public.request_all_missing(uuid, text, date) from public, anon;
grant execute on function public.request_all_missing(uuid, text, date) to authenticated;

-- Everyone in a company, or one branch of it. Branch managers are always limited to their own branch.
create or replace function public.request_all_missing_for_many(
  p_entity_id uuid, p_location_id uuid default null, p_note text default null, p_due_date date default null)
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
    v_res := public.request_all_missing(r.id, p_note, p_due_date);
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
revoke all on function public.request_all_missing_for_many(uuid, uuid, text, date) from public, anon;
grant execute on function public.request_all_missing_for_many(uuid, uuid, text, date) to authenticated;
