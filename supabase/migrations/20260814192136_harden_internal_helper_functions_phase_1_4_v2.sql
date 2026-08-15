
create or replace function public.interview_feedback_status_for(p_interview_id uuid) returns text
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select f.status
  from public.interview_feedback f
  join public.interviews iv on iv.id = f.interview_id
  where f.interview_id = p_interview_id
    and iv.interviewer_id = auth.uid();
$$;

create or replace function public.requisition_entity_for_interview(p_interview_id uuid) returns uuid
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select jr.entity_id
  from public.interviews iv
  join public.job_applications ja on ja.id = iv.application_id
  join public.job_requisitions jr on jr.id = ja.requisition_id
  where iv.id = p_interview_id
    and iv.interviewer_id = auth.uid();
$$;

drop policy if exists documents_insert on public.employee_documents;
drop function if exists public.renewal_supersedes_owned_by(uuid, uuid);

create function public.renewal_supersedes_owned_by(p_supersedes_document_id uuid) returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select exists (
    select 1 from public.employee_documents pd
    where pd.id = p_supersedes_document_id and pd.employee_id = public.my_employee_id()
  );
$$;

create policy documents_insert on public.employee_documents for insert with check (
  (
    employee_id = my_employee_id() and is_active_employee(employee_id)
    and submitted_by = auth.uid() and review_status = 'pending_review' and is_current = false
    and reviewed_by is null and reviewed_at is null and archived_by is null and archived_at is null
    and rejection_reason is null
    and (supersedes_document_id is null or renewal_supersedes_owned_by(supersedes_document_id))
  ) or (
    submitted_by = auth.uid() and review_status = 'pending_review' and is_current = false
    and reviewed_by is null and reviewed_at is null and archived_by is null and archived_at is null
    and rejection_reason is null
    and exists (
      select 1 from employees e where e.id = employee_documents.employee_id and (
        my_role() = 'owner'
        or (my_role() = 'entity_admin' and e.entity_id = my_entity())
        or (my_role() = 'location_manager' and e.home_location_id = my_location() and not is_restricted_doc_type(employee_documents.doc_type))
      )
    )
  )
);

create or replace function public.can_review_document(p_submitted_by uuid, p_reviewed_by uuid, p_doc_type document_type) returns boolean
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_submitter_role user_role;
  v_reviewer_role user_role;
  v_sensitive boolean;
begin
  if p_reviewed_by is distinct from auth.uid() or p_reviewed_by is null or p_submitted_by is null then
    return false;
  end if;

  select role into v_submitter_role from public.profiles where id = p_submitted_by;
  select role into v_reviewer_role from public.profiles where id = p_reviewed_by;
  v_sensitive := public.is_restricted_doc_type(p_doc_type);

  if v_reviewer_role = 'owner' then
    return true;
  end if;

  if v_submitter_role = 'staff' then
    if p_reviewed_by = p_submitted_by then
      return false;
    end if;
    if v_reviewer_role = 'entity_admin' then
      return true;
    end if;
    if v_reviewer_role = 'location_manager' and not v_sensitive then
      return true;
    end if;
    return false;
  end if;

  if v_submitter_role = 'location_manager' then
    return v_reviewer_role = 'entity_admin';
  end if;

  if v_submitter_role = 'entity_admin' then
    if v_sensitive then
      return false;
    end if;
    if p_reviewed_by = p_submitted_by and v_reviewer_role = 'entity_admin' then
      return public.entity_admin_self_approval_enabled();
    end if;
    return false;
  end if;

  if v_submitter_role = 'owner' then
    return v_reviewer_role = 'owner' and p_reviewed_by = p_submitted_by;
  end if;

  return false;
end;
$$;

revoke all on function public.interview_feedback_status_for(uuid) from public, anon;
grant execute on function public.interview_feedback_status_for(uuid) to authenticated;

revoke all on function public.requisition_entity_for_interview(uuid) from public, anon;
grant execute on function public.requisition_entity_for_interview(uuid) to authenticated;

revoke all on function public.renewal_supersedes_owned_by(uuid) from public, anon;
grant execute on function public.renewal_supersedes_owned_by(uuid) to authenticated;

revoke all on function public.can_review_document(uuid, uuid, document_type) from public, anon;
grant execute on function public.can_review_document(uuid, uuid, document_type) to authenticated;

