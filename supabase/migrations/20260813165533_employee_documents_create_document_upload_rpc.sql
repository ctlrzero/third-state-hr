
create or replace function public.create_document_upload(
  p_employee_id uuid,
  p_doc_type document_type,
  p_storage_path text,
  p_expiry_date date default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_emp record;
  v_role user_role := my_role();
  v_current_id uuid;
  v_new_id uuid := gen_random_uuid();
  v_sensitive boolean := public.is_restricted_doc_type(p_doc_type);
  v_immediate_approve boolean := false;
  v_final_status text;
begin
  select e.id, e.entity_id, e.home_location_id, e.employment_status
    into v_emp
    from employees e
    where e.id = p_employee_id;

  if v_emp.id is null then
    raise exception 'Employee % not found', p_employee_id;
  end if;

  if v_emp.employment_status <> 'active' then
    raise exception 'Cannot upload documents for an inactive employee';
  end if;

  if not (
    v_role = 'owner'
    or (v_role = 'entity_admin' and v_emp.entity_id = my_entity())
    or (v_role = 'location_manager' and v_emp.home_location_id = my_location() and not v_sensitive)
  ) then
    raise exception 'Not authorized to upload documents for this employee';
  end if;

  select id into v_current_id
    from employee_documents
    where employee_id = p_employee_id and doc_type = p_doc_type and is_current = true;

  if v_role = 'owner' then
    v_immediate_approve := true;
  elsif v_role = 'entity_admin' and not v_sensitive and public.entity_admin_self_approval_enabled() then
    v_immediate_approve := true;
  end if;

  insert into employee_documents (
    id, employee_id, doc_type, storage_path, expiry_date, notes,
    review_status, version_number, supersedes_document_id, is_current,
    submitted_by, submitted_at
  ) values (
    v_new_id, p_employee_id, p_doc_type, p_storage_path, p_expiry_date, p_notes,
    'pending_review', 1, v_current_id, false,
    auth.uid(), now()
  );

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('employee_documents', v_new_id, auth.uid(), 'document_uploaded',
    jsonb_build_object('employee_id', p_employee_id, 'doc_type', p_doc_type, 'supersedes', v_current_id, 'submitted_role', v_role));

  if v_immediate_approve then
    perform public.approve_document(v_new_id);
    v_final_status := 'approved';
  else
    v_final_status := 'pending_review';
  end if;

  return jsonb_build_object('id', v_new_id, 'review_status', v_final_status);
end;
$$;

revoke all on function public.create_document_upload(uuid, document_type, text, date, text) from public, anon;
grant execute on function public.create_document_upload(uuid, document_type, text, date, text) to authenticated;

revoke all on function public.can_review_document(uuid, uuid, document_type) from public, anon;
grant execute on function public.can_review_document(uuid, uuid, document_type) to authenticated;

revoke all on function public.entity_admin_self_approval_enabled() from public, anon;
grant execute on function public.entity_admin_self_approval_enabled() to authenticated;

revoke all on function public.set_entity_admin_self_approval(boolean) from public, anon;
grant execute on function public.set_entity_admin_self_approval(boolean) to authenticated;

drop policy if exists documents_insert on public.employee_documents;

create policy documents_insert on public.employee_documents
for insert
with check (
  (
    employee_id = my_employee_id()
    and public.is_active_employee(employee_id)
    and submitted_by = auth.uid()
    and review_status = 'pending_review'
    and is_current = false
    and reviewed_by is null and reviewed_at is null
    and archived_by is null and archived_at is null
    and rejection_reason is null
    and (
      supersedes_document_id is null
      or public.renewal_supersedes_owned_by(supersedes_document_id, my_employee_id())
    )
  )
  or (
    submitted_by = auth.uid()
    and review_status = 'pending_review'
    and is_current = false
    and reviewed_by is null and reviewed_at is null
    and archived_by is null and archived_at is null
    and rejection_reason is null
    and exists (
      select 1 from public.employees e
      where e.id = employee_documents.employee_id
        and (
          my_role() = 'owner'
          or (my_role() = 'entity_admin' and e.entity_id = my_entity())
          or (
            my_role() = 'location_manager'
            and e.home_location_id = my_location()
            and not public.is_restricted_doc_type(employee_documents.doc_type)
          )
        )
    )
  )
);
