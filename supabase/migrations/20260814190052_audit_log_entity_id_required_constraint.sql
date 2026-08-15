
alter table public.audit_log add constraint audit_log_entity_id_required_check
  check (entity_id is not null or table_name = 'app_settings');
