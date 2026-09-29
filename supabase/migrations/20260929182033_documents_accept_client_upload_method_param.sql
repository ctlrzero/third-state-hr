-- The app sends p_upload_method; the functions didn't accept it, so PostgREST couldn't find them.
-- Accept it for compatibility, but never trust it: the method is still derived server-side.

drop function if exists public.stage_document_upload(uuid, public.document_type, text, date, text);

create function public.stage_document_upload(
  p_employee_id uuid,
  p_doc_type public.document_type,
  p_file_extension text,
  p_expiry_date date default null,
  p_notes text default null,
  p_upload_method text default null
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_emp record;
  v_role public.user_role := public.my_role();
  v_sensitive boolean := public.is_restricted_doc_type(p_doc_type);
  v_new_id uuid := gen_random_uuid();
  v_path text;
  v_current_id uuid;
  v_method text;
begin
  if p_upload_method is not null and p_upload_method not in ('self', 'assisted') then
    raise exception 'Upload method must be self or assisted' using errcode = '22023';
  end if;

  if p_file_extension is null or lower(p_file_extension) not in ('pdf', 'jpg', 'jpeg', 'png') then
    raise exception 'Unsupported file type — only PDF, JPG and PNG are accepted';
  end if;

  select e.id, e.entity_id, e.home_location_id, e.employment_status into v_emp from employees e where e.id = p_employee_id;
  if v_emp.id is null then raise exception 'Employee % not found', p_employee_id; end if;
  if v_emp.employment_status = 'inactive' then raise exception 'Cannot upload documents for an inactive employee'; end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = my_location() and not v_sensitive)
    or p_employee_id = public.my_employee_id()
  ) then raise exception 'Not authorized to upload documents for this employee'; end if;

  -- Always derived from who is signed in; p_upload_method is ignored.
  v_method := case when p_employee_id = public.my_employee_id() then 'self' else 'assisted' end;

  select id into v_current_id from employee_documents where employee_id = p_employee_id and doc_type = p_doc_type and is_current = true;

  v_path := format('%s/%s/%s/1/%s.%s', v_emp.entity_id, p_employee_id, v_new_id, v_new_id, lower(p_file_extension));

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, version_number, supersedes_document_id, is_current, submitted_by, submitted_at, upload_confirmed,
    uploaded_by, upload_method
  ) values (
    v_new_id, p_employee_id, p_doc_type, v_path, p_expiry_date, p_notes,
    'pending_review', 1, v_current_id, false, auth.uid(), now(), false,
    auth.uid(), v_method
  );

  insert into employee_document_requirements (employee_id, doc_type, status, document_id, created_by)
  values (p_employee_id, p_doc_type, 'pending_review', v_new_id, auth.uid())
  on conflict (employee_id, doc_type) do update
    set status = 'pending_review', document_id = v_new_id, updated_at = now();

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'document_upload_staged',
    jsonb_build_object('employee_id', p_employee_id, 'doc_type', p_doc_type, 'supersedes', v_current_id, 'submitted_role', v_role, 'upload_method', v_method),
    v_emp.entity_id, v_emp.home_location_id, p_employee_id);

  return jsonb_build_object('id', v_new_id, 'storage_path', v_path, 'upload_method', v_method);
end;
$function$;

revoke all on function public.stage_document_upload(uuid, public.document_type, text, date, text, text) from public, anon;
grant execute on function public.stage_document_upload(uuid, public.document_type, text, date, text, text) to authenticated, service_role;

-- Same compatibility for renewals, in case the app sends it there too.
drop function if exists public.stage_document_renewal(uuid, text, date, text);

create function public.stage_document_renewal(
  p_current_document_id uuid,
  p_file_extension text,
  p_expiry_date date default null,
  p_notes text default null,
  p_upload_method text default null
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_current record;
  v_new_id uuid := gen_random_uuid();
  v_path text;
  v_method text;
begin
  if p_upload_method is not null and p_upload_method not in ('self', 'assisted') then
    raise exception 'Upload method must be self or assisted' using errcode = '22023';
  end if;

  if p_file_extension is null or lower(p_file_extension) not in ('pdf', 'jpg', 'jpeg', 'png') then
    raise exception 'Unsupported file type — only PDF, JPG and PNG are accepted';
  end if;

  select d.id, d.employee_id, d.doc_type, d.is_current, d.review_status, e.entity_id as emp_entity_id, e.home_location_id as emp_home_location
    into v_current
    from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_current_document_id;

  if v_current.id is null then raise exception 'Document % not found', p_current_document_id; end if;
  if v_current.employee_id <> my_employee_id() then raise exception 'You can only renew your own documents'; end if;
  if not public.is_active_employee(v_current.employee_id) then raise exception 'Inactive employees cannot submit documents'; end if;
  if v_current.is_current is not true or v_current.review_status <> 'approved' then
    raise exception 'Only the current approved document can be renewed';
  end if;

  v_method := 'self';
  v_path := format('%s/%s/%s/1/%s.%s', v_current.emp_entity_id, v_current.employee_id, v_new_id, v_new_id, lower(p_file_extension));

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, is_current, version_number, supersedes_document_id, submitted_by, submitted_at, upload_confirmed,
    uploaded_by, upload_method
  ) values (
    v_new_id, v_current.employee_id, v_current.doc_type, v_path, p_expiry_date, p_notes,
    'pending_review', false, 1, p_current_document_id, auth.uid(), now(), false,
    auth.uid(), v_method
  );

  insert into employee_document_requirements (employee_id, doc_type, status, document_id, created_by)
  values (v_current.employee_id, v_current.doc_type, 'pending_review', v_new_id, auth.uid())
  on conflict (employee_id, doc_type) do update
    set status = 'pending_review', document_id = v_new_id, updated_at = now();

  insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('employee_documents', v_new_id, auth.uid(), 'renewal_staged',
    jsonb_build_object('employee_id', v_current.employee_id, 'doc_type', v_current.doc_type, 'supersedes', p_current_document_id),
    v_current.emp_entity_id, v_current.emp_home_location, v_current.employee_id);

  return jsonb_build_object('id', v_new_id, 'storage_path', v_path, 'upload_method', v_method);
end;
$function$;

revoke all on function public.stage_document_renewal(uuid, text, date, text, text) from public, anon;
grant execute on function public.stage_document_renewal(uuid, text, date, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';;
