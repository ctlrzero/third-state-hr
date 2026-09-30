-- "Ask an employee for something": an owner, company admin (entity_admin) or branch manager
-- (location_manager, own branch only) asks one employee to
--   (a) upload a document of a given type      kind = 'document'        (also opens a document requirement,
--                                                                        so the Upload button shows in Documents)
--   (b) add or update bank / payment details   kind = 'payment_details'
--   (c) fill in missing profile information    kind = 'profile_info'    (fields: phone, emergency_contact,
--                                                                        dob, nationality, residential_address)
-- with an optional note and due date. The employee sees open requests on Home. A request closes by itself
-- when fulfilled (triggers on employee_documents / employee_payment_details / employees), or the sender
-- (or an owner / company admin) cancels it. The employee is notified when asked; the sender when it's done.
-- The daily HR reminders job nudges the employee once per day while a request is overdue.
-- Shift supervisors and staff cannot send requests.

create table public.employee_requests (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('document', 'payment_details', 'profile_info')),
  doc_type public.document_type,
  fields text[],
  note text check (note is null or length(note) <= 500),
  due_date date,
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  requested_by uuid not null references auth.users(id),
  requested_role public.user_role,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid references auth.users(id),
  last_reminded_on date,
  constraint employee_requests_doc_type_chk check ((kind = 'document') = (doc_type is not null)),
  constraint employee_requests_fields_chk check (
    (kind = 'profile_info') = (coalesce(cardinality(fields), 0) > 0)
    and (fields is null or fields <@ array['phone', 'emergency_contact', 'dob', 'nationality', 'residential_address']::text[]))
);
create unique index employee_requests_one_open_doc on public.employee_requests (employee_id, doc_type)
  where status = 'open' and kind = 'document';
create unique index employee_requests_one_open_other on public.employee_requests (employee_id, kind)
  where status = 'open' and kind <> 'document';
create index employee_requests_employee on public.employee_requests (employee_id, created_at desc);
create index employee_requests_open_due on public.employee_requests (due_date) where status = 'open';

alter table public.employee_requests enable row level security;
revoke all on table public.employee_requests from public, anon, authenticated;
-- No policies: reads and writes go through the RPCs below only.

-- ---------------------------------------------------------------------------------------------
-- Helpers (not callable from the API)
-- ---------------------------------------------------------------------------------------------
create or replace function public._emp_req_can_manage(p_employee_id uuid)
returns boolean
language sql stable security definer
set search_path to ''
as $function$
  select exists (
    select 1 from public.employees e
    where e.id = p_employee_id
      and (public.my_role() = 'owner'
           or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
           or (public.my_role() = 'location_manager' and e.home_location_id = public.my_location()))
  );
$function$;
revoke all on function public._emp_req_can_manage(uuid) from public, anon, authenticated;

create or replace function public._emp_req_label(p_kind text, p_doc_type public.document_type, p_fields text[])
returns text
language sql immutable
set search_path to ''
as $function$
  select case p_kind
    when 'document' then
      case p_doc_type::text when 'emirates_id' then 'Emirates ID' when 'labor_card' then 'Labour card'
                            when 'health_card' then 'Health card' when 'bank_payment_document' then 'Bank / payment document'
                            when 'compensation_document' then 'Salary document'
                            else initcap(replace(p_doc_type::text, '_', ' ')) end
    when 'payment_details' then 'Bank / payment details'
    else 'Missing profile details: ' || (
      select string_agg(case f when 'phone' then 'phone number' when 'emergency_contact' then 'emergency contact'
                               when 'dob' then 'date of birth' when 'nationality' then 'nationality'
                               when 'residential_address' then 'home address' else f end, ', ')
      from unnest(p_fields) f)
  end;
$function$;
revoke all on function public._emp_req_label(text, public.document_type, text[]) from public, anon;

-- True when this profile field is still empty for the employee.
create or replace function public._emp_req_field_missing(e public.employees, p_field text)
returns boolean
language sql immutable
set search_path to ''
as $function$
  select case p_field
    when 'phone' then nullif(btrim(coalesce(e.phone, '')), '') is null
    when 'emergency_contact' then nullif(btrim(coalesce(e.emergency_contact_name, '')), '') is null
                               or nullif(btrim(coalesce(e.emergency_contact_phone, '')), '') is null
    when 'dob' then e.dob is null
    when 'nationality' then nullif(btrim(coalesce(e.nationality, '')), '') is null
    when 'residential_address' then nullif(btrim(coalesce(e.residential_address, '')), '') is null
    else false end;
$function$;
revoke all on function public._emp_req_field_missing(public.employees, text) from public, anon, authenticated;

-- Close every open request of this employee that is now fulfilled; tell the sender. Returns how many closed.
create or replace function public._emp_req_check(p_employee_id uuid)
returns int
language plpgsql security definer
set search_path to ''
as $function$
declare
  r record;
  e public.employees;
  v_done boolean;
  v_n int := 0;
  v_name text;
begin
  if not exists (select 1 from public.employee_requests where employee_id = p_employee_id and status = 'open') then
    return 0;
  end if;
  select * into e from public.employees where id = p_employee_id;
  v_name := coalesce(e.preferred_name, e.full_name);
  for r in select * from public.employee_requests where employee_id = p_employee_id and status = 'open' for update loop
    v_done := case r.kind
      when 'document' then exists (
        select 1 from public.employee_documents d
        where d.employee_id = r.employee_id and d.doc_type = r.doc_type and d.upload_confirmed
          and d.archived_at is null and d.submitted_at >= r.created_at)
      when 'payment_details' then exists (
        select 1 from public.employee_payment_details pd
        where pd.employee_id = r.employee_id and pd.status in ('submitted', 'verified') and pd.submitted_at >= r.created_at)
      else not exists (select 1 from unnest(r.fields) f where public._emp_req_field_missing(e, f))
    end;
    continue when not v_done;

    update public.employee_requests set status = 'done', closed_at = now(), closed_by = auth.uid() where id = r.id;
    update public.notifications set resolved_at = now()
     where target_type = 'employee_requests' and target_id = r.id and resolved_at is null;
    perform public.create_notification(r.entity_id, r.requested_by, null, 'employee_request_done',
      format('%s sent what you asked for', v_name),
      public._emp_req_label(r.kind, r.doc_type, r.fields)
        || case when r.kind = 'document' then ' — uploaded. Please review it in Documents.'
                when r.kind = 'payment_details' then ' — sent. Payroll needs to check them.'
                else ' — filled in.' end,
      'employees', r.employee_id, 'normal', 'emp_req:' || r.id || ':done');
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;
revoke all on function public._emp_req_check(uuid) from public, anon, authenticated;

-- Triggers: never block the underlying save if the check fails.
create or replace function public._emp_req_trg()
returns trigger
language plpgsql security definer
set search_path to ''
as $function$
begin
  begin
    if tg_table_name = 'employees' then
      perform public._emp_req_check(new.id);
    elsif tg_table_name = 'employee_documents' then
      if new.upload_confirmed then perform public._emp_req_check(new.employee_id); end if;
    else
      if new.status in ('submitted', 'verified') then perform public._emp_req_check(new.employee_id); end if;
    end if;
  exception when others then
    raise warning 'employee request auto-close failed: %', sqlerrm;
  end;
  return null;
end;
$function$;
revoke all on function public._emp_req_trg() from public, anon, authenticated;

create trigger trg_emp_req_on_document after insert or update of upload_confirmed on public.employee_documents
  for each row execute function public._emp_req_trg();
create trigger trg_emp_req_on_payment after insert or update of status on public.employee_payment_details
  for each row execute function public._emp_req_trg();
create trigger trg_emp_req_on_profile after update of phone, emergency_contact_name, emergency_contact_phone, dob, nationality, residential_address
  on public.employees for each row execute function public._emp_req_trg();

-- ---------------------------------------------------------------------------------------------
-- Sender RPCs
-- ---------------------------------------------------------------------------------------------
create or replace function public.create_employee_request(
  p_employee_id uuid, p_kind text, p_doc_type public.document_type default null, p_fields text[] default null,
  p_note text default null, p_due_date date default null)
returns jsonb
language plpgsql security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
  e public.employees;
  v_fields text[];
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
  v_label text;
  v_sender text;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if v_role is null or v_role not in ('owner', 'entity_admin', 'location_manager') then
    raise exception 'Only an owner, Company Admin or Branch Manager can send requests' using errcode = '42501';
  end if;
  select * into e from public.employees where id = p_employee_id;
  if e.id is null then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  if not public._emp_req_can_manage(p_employee_id) then
    raise exception 'You can only send requests to employees in your branch' using errcode = '42501';
  end if;
  if e.id = public.my_employee_id() then
    raise exception 'You can''t send a request to yourself' using errcode = '22023';
  end if;
  if e.employment_status not in ('active', 'pre_boarding') then
    raise exception 'You can only send requests to active or starting employees' using errcode = '22023';
  end if;
  if p_kind is null or p_kind not in ('document', 'payment_details', 'profile_info') then
    raise exception 'Choose what you want to ask for' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 500 then
    raise exception 'The note is too long (500 characters at most)' using errcode = '22023';
  end if;
  if p_due_date is not null and p_due_date < (now() at time zone 'Asia/Dubai')::date then
    raise exception 'The due date can''t be in the past' using errcode = '22023';
  end if;

  if p_kind = 'document' then
    if p_doc_type is null then raise exception 'Choose a document type' using errcode = '22023'; end if;
    if v_role = 'location_manager' and public.is_restricted_doc_type(p_doc_type) then
      raise exception 'Only an owner or Company Admin can ask for this document' using errcode = '42501';
    end if;
  elsif p_kind = 'profile_info' then
    if p_fields is null or cardinality(p_fields) = 0 then
      raise exception 'Choose at least one detail to ask for' using errcode = '22023';
    end if;
    if not (p_fields <@ array['phone', 'emergency_contact', 'dob', 'nationality', 'residential_address']::text[]) then
      raise exception 'One of the chosen details can''t be requested' using errcode = '22023';
    end if;
    select array_agg(distinct f order by f) into v_fields from unnest(p_fields) f where public._emp_req_field_missing(e, f);
    if v_fields is null then
      raise exception 'These details are already filled in' using errcode = '22023';
    end if;
  end if;

  if exists (select 1 from public.employee_requests
             where employee_id = e.id and status = 'open' and kind = p_kind
               and coalesce(doc_type::text, '') = coalesce(case when p_kind = 'document' then p_doc_type::text end, '')) then
    raise exception 'There is already an open request for this. Cancel it first if you want to change it.' using errcode = '22023';
  end if;

  insert into public.employee_requests (entity_id, employee_id, kind, doc_type, fields, note, due_date, requested_by, requested_role)
  values (e.entity_id, e.id, p_kind, case when p_kind = 'document' then p_doc_type end,
          case when p_kind = 'profile_info' then v_fields end, v_note, p_due_date, auth.uid(), v_role)
  returning id into v_id;

  -- Documents: make sure the employee gets an Upload button in Documents (re-open a satisfied requirement).
  if p_kind = 'document' then
    insert into public.employee_document_requirements (employee_id, doc_type, status, created_by)
    values (e.id, p_doc_type, 'missing', auth.uid())
    on conflict (employee_id, doc_type) do update
      set status = 'missing', waived_by = null, waived_reason = null, waived_at = null, updated_at = now()
      where public.employee_document_requirements.status in ('approved', 'waived', 'archived', 'expiring');
  end if;

  v_label := public._emp_req_label(p_kind, p_doc_type, v_fields);
  select coalesce(nullif(btrim(p.full_name), ''), 'Your manager') into v_sender from public.profiles p where p.id = auth.uid();
  perform public.create_notification(e.entity_id, null, e.id, 'employee_request',
    case p_kind when 'document' then format('Please upload your %s', v_label)
                when 'payment_details' then 'Please add your bank / payment details'
                else 'Please complete your profile' end,
    format('%s asked you for: %s.', coalesce(v_sender, 'Your manager'), v_label)
      || case when p_due_date is not null then format(' Please do it by %s.', to_char(p_due_date, 'Dy DD Mon')) else '' end
      || case when v_note is not null then ' Note: ' || left(v_note, 300) else '' end,
    'employee_requests', v_id, 'high', 'emp_req:' || v_id || ':new');

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_requests', v_id, auth.uid(), 'employee_request_created',
    jsonb_build_object('kind', p_kind, 'doc_type', p_doc_type, 'fields', v_fields, 'due_date', p_due_date),
    e.entity_id, e.home_location_id, e.id);

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

create or replace function public.cancel_employee_request(p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path to ''
as $function$
declare
  r public.employee_requests;
  v_role public.user_role := public.my_role();
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  select * into r from public.employee_requests where id = p_request_id for update;
  if r.id is null then raise exception 'This request no longer exists' using errcode = 'P0002'; end if;
  if not (
    (r.requested_by = auth.uid() and v_role in ('owner', 'entity_admin', 'location_manager') and public._emp_req_can_manage(r.employee_id))
    or v_role = 'owner'
    or (v_role = 'entity_admin' and r.entity_id = public.my_entity())
  ) then
    raise exception 'Only the person who sent this request can cancel it' using errcode = '42501';
  end if;
  if r.status <> 'open' then raise exception 'This request is already closed' using errcode = '22023'; end if;
  update public.employee_requests set status = 'cancelled', closed_at = now(), closed_by = auth.uid() where id = r.id;
  update public.notifications set resolved_at = now()
   where target_type = 'employee_requests' and target_id = r.id and resolved_at is null;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_requests', r.id, auth.uid(), 'employee_request_cancelled', jsonb_build_object('kind', r.kind), r.entity_id, r.employee_id);
  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function public.get_employee_requests(p_employee_id uuid, p_include_closed boolean default false)
returns table (id uuid, employee_id uuid, kind text, doc_type public.document_type, fields text[], label text, note text,
               due_date date, status text, requested_by uuid, requested_by_name text, created_at timestamptz,
               closed_at timestamptz, is_overdue boolean, can_cancel boolean)
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_role public.user_role := public.my_role();
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if v_role is null or v_role not in ('owner', 'entity_admin', 'location_manager') or not public._emp_req_can_manage(p_employee_id) then
    raise exception 'Not authorized to see requests for this employee' using errcode = '42501';
  end if;
  return query
    select r.id, r.employee_id, r.kind, r.doc_type, r.fields, public._emp_req_label(r.kind, r.doc_type, r.fields), r.note,
           r.due_date, r.status, r.requested_by, p.full_name, r.created_at, r.closed_at,
           r.status = 'open' and r.due_date is not null and r.due_date < (now() at time zone 'Asia/Dubai')::date,
           r.status = 'open' and (r.requested_by = auth.uid() or v_role = 'owner' or (v_role = 'entity_admin' and r.entity_id = public.my_entity()))
    from public.employee_requests r
    left join public.profiles p on p.id = r.requested_by
    where r.employee_id = p_employee_id and (coalesce(p_include_closed, false) or r.status = 'open')
    order by (r.status = 'open') desc, r.created_at desc
    limit 50;
end;
$function$;

-- ---------------------------------------------------------------------------------------------
-- Employee RPCs
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_my_employee_requests()
returns table (id uuid, kind text, doc_type public.document_type, fields text[], label text, note text, due_date date,
               requested_by_name text, created_at timestamptz, is_overdue boolean)
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_emp uuid := public.my_employee_id();
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if v_emp is null then return; end if;
  return query
    select r.id, r.kind, r.doc_type, r.fields, public._emp_req_label(r.kind, r.doc_type, r.fields), r.note, r.due_date,
           p.full_name, r.created_at,
           r.due_date is not null and r.due_date < (now() at time zone 'Asia/Dubai')::date
    from public.employee_requests r
    left join public.profiles p on p.id = r.requested_by
    where r.employee_id = v_emp and r.status = 'open'
    order by r.due_date nulls last, r.created_at;
end;
$function$;

-- Fill in profile details the employee was asked for. Only fields named in an open request and still
-- empty can be written here (changing an existing value still goes through a change request).
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
    e.phone := v_phone; v_updated := v_updated || 'phone';
  end if;
  if 'emergency_contact' = any(v_allowed) and public._emp_req_field_missing(e, 'emergency_contact') then
    if v_ec_name is not null and nullif(btrim(coalesce(e.emergency_contact_name, '')), '') is null then
      e.emergency_contact_name := v_ec_name; v_updated := v_updated || 'emergency_contact_name';
    end if;
    if v_ec_phone is not null and nullif(btrim(coalesce(e.emergency_contact_phone, '')), '') is null then
      e.emergency_contact_phone := v_ec_phone; v_updated := v_updated || 'emergency_contact_phone';
    end if;
  end if;
  if 'dob' = any(v_allowed) and e.dob is null and v_dob is not null then
    e.dob := v_dob; v_updated := v_updated || 'dob';
  end if;
  if 'nationality' = any(v_allowed) and public._emp_req_field_missing(e, 'nationality') and v_nat is not null then
    e.nationality := v_nat; v_updated := v_updated || 'nationality';
  end if;
  if 'residential_address' = any(v_allowed) and public._emp_req_field_missing(e, 'residential_address') and v_addr is not null then
    e.residential_address := v_addr; v_updated := v_updated || 'residential_address';
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

-- Send bank / payment details because a manager asked for them (outside onboarding). Replaces any earlier
-- submitted or verified details; payroll must verify the new ones (verify_payment_details) before pay day.
create or replace function public.submit_requested_payment_details(
  p_method text, p_bank_name text, p_account_name text, p_iban text, p_routing_code text default null)
returns jsonb
language plpgsql security definer
set search_path to ''
as $function$
declare
  v_emp uuid := public.my_employee_id();
  v_iban text := nullif(upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g')), '');
  v_id uuid;
  v_entity uuid;
  v_inst uuid;
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
  if v_emp is null then raise exception 'Your account is not linked to an employee record' using errcode = '42501'; end if;
  if not exists (select 1 from public.employee_requests where employee_id = v_emp and status = 'open' and kind = 'payment_details') then
    raise exception 'Nobody has asked you for bank details right now' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('bank_transfer', 'exchange_house', 'wps_card', 'cash') then
    raise exception 'Choose how you want to be paid' using errcode = '22023';
  end if;
  if p_method = 'bank_transfer' and (v_iban is null or v_iban !~ '^AE[0-9]{21}$') then
    raise exception 'Enter a UAE IBAN: AE followed by 21 digits' using errcode = '22023';
  end if;
  if p_method <> 'bank_transfer' and v_iban is not null and v_iban !~ '^AE[0-9]{21}$' then
    raise exception 'Enter a UAE IBAN: AE followed by 21 digits' using errcode = '22023';
  end if;
  select entity_id into v_entity from public.employees where id = v_emp;

  update public.employee_payment_details set status = 'superseded'
   where employee_id = v_emp and status in ('submitted', 'verified');
  insert into public.employee_payment_details (employee_id, method, bank_name, account_name, iban, routing_code, submitted_by)
  values (v_emp, p_method, nullif(btrim(coalesce(p_bank_name, '')), ''), nullif(btrim(coalesce(p_account_name, '')), ''),
          v_iban, nullif(btrim(coalesce(p_routing_code, '')), ''), auth.uid())
  returning id into v_id;

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_payment_details', v_id, auth.uid(), 'payment_details_submitted',
    jsonb_build_object('method', p_method, 'iban_last4', right(v_iban, 4), 'source', 'employee_request'), v_entity, v_emp);

  select id into v_inst from public.onboarding_instances where employee_id = v_emp
     and status not in ('completed', 'cancelled', 'withdrawn') order by created_at desc limit 1;
  if v_inst is not null then
    begin perform public._onb_recompute(v_inst);
    exception when others then raise warning 'onboarding recompute failed: %', sqlerrm; end;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

revoke all on function public.create_employee_request(uuid, text, public.document_type, text[], text, date) from public, anon;
revoke all on function public.cancel_employee_request(uuid) from public, anon;
revoke all on function public.get_employee_requests(uuid, boolean) from public, anon;
revoke all on function public.get_my_employee_requests() from public, anon;
revoke all on function public.fill_my_requested_profile_info(jsonb) from public, anon;
revoke all on function public.submit_requested_payment_details(text, text, text, text, text) from public, anon;
grant execute on function public.create_employee_request(uuid, text, public.document_type, text[], text, date) to authenticated;
grant execute on function public.cancel_employee_request(uuid) to authenticated;
grant execute on function public.get_employee_requests(uuid, boolean) to authenticated;
grant execute on function public.get_my_employee_requests() to authenticated;
grant execute on function public.fill_my_requested_profile_info(jsonb) to authenticated;
grant execute on function public.submit_requested_payment_details(text, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Daily reminder: nudge the employee once per day while a request is overdue.
-- ---------------------------------------------------------------------------------------------
create or replace function public._emp_req_reminders(p_today date)
returns int
language plpgsql security definer
set search_path to ''
as $function$
declare
  r record;
  v_n int := 0;
begin
  for r in
    select q.* from public.employee_requests q
    join public.employees e on e.id = q.employee_id
    where q.status = 'open' and q.due_date is not null and q.due_date < p_today
      and (q.last_reminded_on is null or q.last_reminded_on < p_today)
      and e.employment_status in ('active', 'pre_boarding')
    for update of q
  loop
    perform public.create_notification(r.entity_id, null, r.employee_id, 'employee_request_overdue',
      'Reminder: your manager is still waiting',
      format('%s — this was due on %s. Open Home and tap the button to do it now.',
             public._emp_req_label(r.kind, r.doc_type, r.fields), to_char(r.due_date, 'Dy DD Mon')),
      'employee_requests', r.id, 'high', 'emp_req:' || r.id || ':overdue:' || p_today);
    update public.employee_requests set last_reminded_on = p_today where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;
revoke all on function public._emp_req_reminders(date) from public, anon, authenticated;

-- Add it as a step of the daily HR reminders job (before the final status update).
do $patch$
declare
  v_def text := pg_get_functiondef('public.run_daily_hr_reminders(boolean)'::regprocedure);
  v_anchor text := $a$
  update public.system_job_runs
     set finished_at = now(),$a$;
  v_step text := $a$
  begin
    v_n := public._emp_req_reminders(v_today);
    v_result := v_result || jsonb_build_object('employee_requests', jsonb_build_object('notifications', v_n));
  exception when others then
    v_failed := v_failed + 1;
    v_result := v_result || jsonb_build_object('employee_requests', jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate));
    raise warning 'daily_hr_reminders: employee request step failed: %', sqlerrm;
  end;
$a$;
  v_m text[];
  v_new text;
begin
  if position('_emp_req_reminders' in v_def) > 0 then
    raise exception 'run_daily_hr_reminders already has the employee request step';
  end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'run_daily_hr_reminders patch point (final update) not found';
  end if;
  v_m := regexp_match(v_def, 'when v_failed = ([0-9]+) then ''failed''');
  if v_m is null then
    raise exception 'run_daily_hr_reminders patch point (failed count) not found';
  end if;
  v_new := replace(v_def, v_anchor, v_step || v_anchor);
  v_new := replace(v_new, format('when v_failed = %s then ''failed''', v_m[1]),
                          format('when v_failed = %s then ''failed''', v_m[1]::int + 1));
  execute v_new;
end
$patch$;
