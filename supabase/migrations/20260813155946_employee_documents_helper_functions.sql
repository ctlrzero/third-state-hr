
-- Document types treated as compensation-adjacent and withheld from
-- location_manager (mirrors the existing employee_compensation /
-- employee_identity_documents walled-garden pattern, which already blocks
-- location_manager entirely). Owner and entity_admin are unrestricted here,
-- consistent with entity_admin already having full employee_compensation
-- access elsewhere in this schema.
create or replace function public.is_restricted_doc_type(p_doc_type public.document_type)
returns boolean
language sql
stable
as $$
  select p_doc_type in ('contract', 'offer_letter');
$$;

create or replace function public.is_active_employee(p_employee_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.employees e
    where e.id = p_employee_id and e.employment_status = 'active'
  );
$$;

comment on function public.is_restricted_doc_type is
  'Doc types a location_manager cannot read or write on employee_documents: contract, offer_letter. Owner/entity_admin unaffected.';
comment on function public.is_active_employee is
  'True if the given employee row is currently active. Used to cut off document access the moment an employee is deactivated, per CLAUDE.md.';

