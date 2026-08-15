
-- storage.objects has its own protect_delete() trigger that rejects direct
-- SQL DELETEs outright ("Use the Storage API instead") -- discovered live
-- during verification, not assumed. So cleanup can only ever remove the
-- employee_documents row; any bytes that were actually uploaded to a
-- never-confirmed path (the rare case -- upload succeeded, but the client
-- crashed before calling confirm_document_upload) are left as an orphaned
-- object in storage and need a separate Storage-API-driven sweep (using the
-- service role, not a Postgres migration) -- documented as a known
-- follow-up in the README, not silently pretended-away.
create or replace function public.cleanup_incomplete_document_uploads(p_older_than_hours int default 24) returns int
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
  v_deleted int := 0;
begin
  if not (my_role() = 'owner' or my_role() = 'entity_admin') then
    raise exception 'Not authorized to run document upload cleanup';
  end if;

  for v_row in
    select d.id, d.storage_path, d.employee_id, e.entity_id, e.home_location_id
    from employee_documents d
    join employees e on e.id = d.employee_id
    where d.upload_confirmed = false
      and d.created_at < now() - make_interval(hours => greatest(p_older_than_hours, 1))
      and (my_role() = 'owner' or e.entity_id = my_entity())
  loop
    delete from employee_documents where id = v_row.id;

    insert into audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
    values ('employee_documents', v_row.id, auth.uid(), 'document_upload_cleanup_removed',
      jsonb_build_object('storage_path', v_row.storage_path), v_row.entity_id, v_row.home_location_id, v_row.employee_id);

    v_deleted := v_deleted + 1;
  end loop;

  return v_deleted;
end;
$$;

revoke all on function public.cleanup_incomplete_document_uploads(int) from public, anon;
grant execute on function public.cleanup_incomplete_document_uploads(int) to authenticated;

