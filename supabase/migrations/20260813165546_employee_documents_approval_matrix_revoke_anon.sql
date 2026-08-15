
revoke execute on function public.create_document_upload(uuid, document_type, text, date, text) from anon;
revoke execute on function public.can_review_document(uuid, uuid, document_type) from anon;
revoke execute on function public.entity_admin_self_approval_enabled() from anon;
revoke execute on function public.set_entity_admin_self_approval(boolean) from anon;
