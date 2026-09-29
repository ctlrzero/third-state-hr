
revoke all on function public.get_document_requirements_for_employee(uuid) from public;
grant execute on function public.get_document_requirements_for_employee(uuid) to authenticated;

revoke all on function public.seed_document_requirements_for_employee(uuid, public.document_type[]) from public;
grant execute on function public.seed_document_requirements_for_employee(uuid, public.document_type[]) to authenticated;

revoke all on function public.waive_document_requirement(uuid, text) from public;
grant execute on function public.waive_document_requirement(uuid, text) to authenticated;
;
