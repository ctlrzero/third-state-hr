-- ============================================================
-- P0-3 daily HR reminders — run as postgres (SQL editor / MCP). Everything is
-- rolled back, so no reminder is actually sent. Every row must have pass = true.
-- Uses whatever real data exists; checks the job runs, is skipped on a second
-- run the same day, does not duplicate notifications when forced, and isolates
-- a failing step.
-- ============================================================
begin;
set local statement_timeout = '90s';
create temp table t_results(test text, pass boolean, detail text);
do $t$
declare r1 jsonb; r2 jsonb; r4 jsonb; n0 int; n1 int; n3 int; v_row record;
begin
  perform set_config('request.jwt.claims', '', true);
  delete from public.system_job_runs where job = 'daily_hr_reminders' and run_date = (now() at time zone 'Asia/Dubai')::date;
  select count(*) into n0 from public.notifications;
  r1 := public.run_daily_hr_reminders();
  select count(*) into n1 from public.notifications;
  insert into t_results values ('first run completes ok', (r1 ->> 'ok')::boolean, left(r1::text, 220));
  insert into t_results values ('first run notifications', true, (n1 - n0) || ' new');
  r2 := public.run_daily_hr_reminders();
  insert into t_results values ('second run same day is skipped', coalesce((r2 ->> 'skipped')::boolean, false), r2 ->> 'reason');
  perform public.run_daily_hr_reminders(true);
  select count(*) into n3 from public.notifications;
  insert into t_results values ('forced re-run creates no duplicate notifications', n3 = n1, (n3 - n1) || ' extra');
  select * into v_row from public.system_job_runs where job = 'daily_hr_reminders' and run_date = (now() at time zone 'Asia/Dubai')::date;
  insert into t_results values ('run logged in system_job_runs', v_row.status = 'ok' and v_row.finished_at is not null, v_row.status);
  alter function public._imm_reminders(date) rename to _imm_reminders_broken_for_test;
  r4 := public.run_daily_hr_reminders(true);
  alter function public._imm_reminders_broken_for_test(date) rename to _imm_reminders;
  insert into t_results values ('failing step isolated (status partial)',
    (r4 ->> 'failed_steps')::int = 1 and r4 -> 'steps' -> 'immigration' ? 'error'
      and not (r4 -> 'steps' -> 'onboarding' ? 'error') and not (r4 -> 'steps' -> 'offboarding' ? 'error'), left((r4 -> 'steps')::text, 160));
  insert into t_results select 'cron job daily-hr-reminders scheduled', count(*) = 1, string_agg(schedule, ',')
    from cron.job where jobname = 'daily-hr-reminders' and active and schedule = '0 2 * * *';
exception when others then
  insert into t_results values ('UNEXPECTED ERROR', false, sqlstate || ' ' || sqlerrm);
end $t$;
select test, pass, detail from t_results;
rollback;
