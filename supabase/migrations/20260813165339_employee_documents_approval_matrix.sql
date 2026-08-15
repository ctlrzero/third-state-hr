
create or replace function public.can_review_document(
  p_submitted_by uuid,
  p_reviewed_by uuid,
  p_doc_type document_type
)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_submitter_role user_role;
  v_reviewer_role user_role;
  v_sensitive boolean;
begin
  if p_reviewed_by is null or p_submitted_by is null then
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
