
-- storage_path (backfilled from file_url in the previous migration) is now
-- the single source of truth for the private object path.
alter table public.employee_documents drop column if exists file_url;
