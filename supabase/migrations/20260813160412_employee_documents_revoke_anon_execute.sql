
revoke execute on function public.submit_document_renewal(uuid, text, date, text) from anon;
revoke execute on function public.approve_document(uuid) from anon;
revoke execute on function public.reject_document(uuid, text) from anon;
revoke execute on function public.archive_document(uuid) from anon;
revoke execute on function public.delete_pending_document(uuid) from anon;
revoke execute on function public.log_document_access(uuid, text) from anon;

