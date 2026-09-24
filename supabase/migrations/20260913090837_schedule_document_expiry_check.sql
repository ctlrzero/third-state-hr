
create extension if not exists pg_cron;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'document-expiry-t30-check') then
    perform cron.unschedule('document-expiry-t30-check');
  end if;
end $$;

-- Daily at 02:00 UTC (06:00 Asia/Dubai) per NFR-LOC-001 business-time convention
select cron.schedule(
  'document-expiry-t30-check',
  '0 2 * * *',
  $$select public.run_document_expiry_workflow_check();$$
);
