
create or replace function public.is_restricted_doc_type(p_doc_type document_type)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select p_doc_type in (
    'passport', 'emirates_id', 'visa', 'contract', 'offer_letter',
    'bank_payment_document', 'compensation_document'
  );
$$;
