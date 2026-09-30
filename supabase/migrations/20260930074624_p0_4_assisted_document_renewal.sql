-- P0-4 (docs/HR_IMPLEMENTATION_PLAN.md): allow assisted document renewal.
--
-- stage_document_renewal refused anyone but the employee ("You can only renew
-- your own documents"), contradicting BR-DOC-004. It now uses the same
-- authorisation as stage_document_upload: the employee themselves; owner;
-- entity admin in their company; location manager at their branch for
-- non-restricted types. upload_method is derived server-side ('self' when the
-- caller is the employee, otherwise 'assisted'); p_upload_method is only
-- validated and otherwise ignored, as in stage_document_upload.
--
-- Review rules are unchanged: reject_document and archive_document still
-- refuse the uploader outright; approve_document follows the approval matrix
-- (the owner may approve their own uploads, per the owner's decision of
-- 2026-09-30; an entity admin only with entity_admin_self_approval_enabled and
-- never for restricted types; managers and staff need a second person).

create or replace function public.stage_document_renewal(
  p_current_document_id uuid, p_file_extension text, p_expiry_date date default null, p_notes text default null,
  p_upload_method text default null)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_current record;
  v_new_id uuid := gen_random_uuid();
  v_path text;
  v_method text;
  v_role public.user_role := my_role();
  v_is_self boolean;
begin
  if auth.uid() is not null and v_role is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;

  if p_upload_method is not null and p_upload_method not in ('self', 'assisted') then
    raise exception 'Upload method must be self or assisted' using errcode = '22023';
  end if;

  if p_file_extension is null or lower(p_file_extension) not in ('pdf', 'jpg', 'jpeg', 'png') then
    raise exception 'Unsupported file type — only PDF, JPG and PNG are accepted' using errcode = '22023';
  end if;

  select d.id, d.employee_id, d.doc_type, d.is_current, d.review_status,
         e.entity_id as emp_entity_id, e.home_location_id as emp_home_location, e.employment_status
    into v_current
    from employee_documents d join employees e on e.id = d.employee_id
    where d.id = p_current_document_id;

  if v_current.id is null then raise exception using errcode = 'P0002', message = 'Document not found'; end if;

  v_is_self := v_current.employee_id = my_employee_id();

  if not (
    coalesce(v_is_self, false)
    or v_role = 'owner'
    or (v_role = 'entity_admin' and v_current.emp_entity_id = my_entity())
    or (v_role = 'location_manager' and v_current.emp_home_location = my_location()
        and not public.is_restricted_doc_type(v_current.doc_type))
  ) then
    raise exception using errcode = '42501', message = 'Not authorized to renew this employee''s documents';
  end if;

  if v_current.employment_status = 'inactive' then
    raise exception using errcode = '22023', message = 'Cannot renew documents for an inactive employee';
  end if;
  if v_current.is_current is not true or v_current.review_status <> 'approved' then
    raise exception using errcode = '22023', message = 'Only the current approved document can be renewed';
  end if;
  if exists (select 1 from employee_documents p
              where p.supersedes_document_id = p_current_document_id and p.review_status = 'pending_review'
                and p.upload_confirmed) then
    raise exception using errcode = '22023', message = 'A renewal for this document is already waiting for review';
  end if;

  -- Always derived from who is signed in; p_upload_method is ignored.
  v_method := case when coalesce(v_is_self, false) then 'self' else 'assisted' end;
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
    jsonb_build_object('employee_id', v_current.employee_id, 'doc_type', v_current.doc_type, 'supersedes', p_current_document_id,
                       'upload_method', v_method, 'submitted_role', v_role),
    v_current.emp_entity_id, v_current.emp_home_location, v_current.employee_id);

  return jsonb_build_object('id', v_new_id, 'storage_path', v_path, 'upload_method', v_method);
end;
$$;
