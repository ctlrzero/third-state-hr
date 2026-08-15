
-- The original unique constraint (entity_id, period_start, period_end) is correct for
-- preventing duplicate ORIGINAL payroll runs for the same period, but it also blocked
-- create_payroll_revision() from ever succeeding, since a revision intentionally shares
-- its source run's entity_id/period_start/period_end. Replace the table-wide unique
-- constraint with a partial unique index that only applies to original (non-revision) runs.
alter table public.payroll_runs drop constraint payroll_runs_entity_id_period_start_period_end_key;

create unique index payroll_runs_original_period_unique_idx
  on public.payroll_runs (entity_id, period_start, period_end)
  where revises_payroll_run_id is null;

