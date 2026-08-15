
-- Pin search_path on the two predicate helpers used inside RLS policies
-- (the advisor's function_search_path_mutable warning).
create or replace function public.is_restricted_doc_type(p_doc_type public.document_type)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select p_doc_type in ('contract', 'offer_letter');
$$;

create or replace function public.is_active_employee(p_employee_id uuid)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select exists (
    select 1 from public.employees e
    where e.id = p_employee_id and e.employment_status = 'active'
  );
$$;

-- Postgres grants EXECUTE to PUBLIC by default on function creation; the
-- earlier migration's explicit grant to `authenticated` did not remove that.
-- Anonymous (unauthenticated) requests have no business calling any of the
-- document workflow actions.
revoke execute on function public.submit_document_renewal(uuid, text, date, text) from public;
revoke execute on function public.approve_document(uuid) from public;
revoke execute on function public.reject_document(uuid, text) from public;
revoke execute on function public.archive_document(uuid) from public;
revoke execute on function public.delete_pending_document(uuid) from public;
revoke execute on function public.log_document_access(uuid, text) from public;

grant execute on function public.submit_document_renewal(uuid, text, date, text) to authenticated;
grant execute on function public.approve_document(uuid) to authenticated;
grant execute on function public.reject_document(uuid, text) to authenticated;
grant execute on function public.archive_document(uuid) to authenticated;
grant execute on function public.delete_pending_document(uuid) to authenticated;
grant execute on function public.log_document_access(uuid, text) to authenticated;

-- Trigger functions should only ever run as part of the trigger mechanism,
-- never called directly as an RPC by any role.
revoke execute on function public.enforce_document_insert_invariants() from public, authenticated, anon;
revoke execute on function public.enforce_document_update_invariants() from public, authenticated, anon;

