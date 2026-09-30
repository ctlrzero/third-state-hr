-- P0-3 (docs/HR_IMPLEMENTATION_PLAN.md): schedule the HR reminder jobs.
--
-- Before: only document-expiry-t30-check ran. onboarding_send_reminders(),
-- _imm_reminders(date) and _off_reminders(date) existed but nothing called them
-- (run_document_expiry_workflow_check does not).
--
-- - onboarding_send_reminders() no longer calls _onb_extension_reminders() at
--   the end, so each reminder set is its own step.
-- - run_daily_hr_reminders(p_force) runs the three steps independently (a
--   failing step is rolled back on its own and recorded; the others still run),
--   at most once per Dubai day. evaluate_workflow_rules has no duplicate
--   protection, so a second run the same day is skipped unless forced;
--   notifications are also de-duplicated by their per-day dedupe keys.
-- - system_job_runs keeps one row per job per day with each step's result or
--   error (owner-readable).
-- - pg_cron job daily-hr-reminders at 02:00 UTC = 06:00 Dubai.

create table if not exists public.system_job_runs (
  job text not null,
  run_date date not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'ok', 'partial', 'failed')),
  result jsonb not null default '{}'::jsonb,
  primary key (job, run_date)
);
alter table public.system_job_runs enable row level security;
create policy system_job_runs_select on public.system_job_runs for select to authenticated
  using (public.my_role() = 'owner');
revoke all on public.system_job_runs from anon, authenticated;
grant select on public.system_job_runs to authenticated;

-- onboarding_send_reminders without the trailing extension call
do $body$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.onboarding_send_reminders()'::regprocedure);
  v_new := replace(v_def, E'  v_sent := v_sent + public._onb_extension_reminders(v_today);\n', '');
  if v_new = v_def then
    if position('_onb_extension_reminders' in v_def) > 0 then
      raise exception 'Could not remove the extension call from onboarding_send_reminders';
    end if;
  else
    execute v_new;
  end if;
end
$body$;

create or replace function public.run_daily_hr_reminders(p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  v_result jsonb := '{}'::jsonb;
  v_failed int := 0;
  v_out jsonb;
  v_n int;
begin
  if auth.uid() is not null or coalesce(current_setting('request.jwt.claims', true), '') not in ('', 'null') then
    raise exception 'System job only' using errcode = '42501';
  end if;

  if exists (select 1 from public.system_job_runs where job = 'daily_hr_reminders' and run_date = v_today) then
    if not coalesce(p_force, false) then
      return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'Already ran today', 'run_date', v_today);
    end if;
    update public.system_job_runs set started_at = now(), finished_at = null, status = 'running', result = '{}'::jsonb
     where job = 'daily_hr_reminders' and run_date = v_today;
  else
    insert into public.system_job_runs (job, run_date) values ('daily_hr_reminders', v_today);
  end if;

  begin
    v_out := public.onboarding_send_reminders();
    v_result := v_result || jsonb_build_object('onboarding', v_out);
  exception when others then
    v_failed := v_failed + 1;
    v_result := v_result || jsonb_build_object('onboarding', jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate));
    raise warning 'daily_hr_reminders: onboarding step failed: %', sqlerrm;
  end;

  begin
    v_n := public._imm_reminders(v_today);
    v_result := v_result || jsonb_build_object('immigration', jsonb_build_object('notifications', v_n));
  exception when others then
    v_failed := v_failed + 1;
    v_result := v_result || jsonb_build_object('immigration', jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate));
    raise warning 'daily_hr_reminders: immigration step failed: %', sqlerrm;
  end;

  begin
    v_n := public._off_reminders(v_today);
    v_result := v_result || jsonb_build_object('offboarding', jsonb_build_object('notifications', v_n));
  exception when others then
    v_failed := v_failed + 1;
    v_result := v_result || jsonb_build_object('offboarding', jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate));
    raise warning 'daily_hr_reminders: offboarding step failed: %', sqlerrm;
  end;

  update public.system_job_runs
     set finished_at = now(),
         status = case when v_failed = 0 then 'ok' when v_failed = 3 then 'failed' else 'partial' end,
         result = v_result
   where job = 'daily_hr_reminders' and run_date = v_today;

  return jsonb_build_object('ok', v_failed = 0, 'run_date', v_today, 'failed_steps', v_failed, 'steps', v_result);
end;
$$;
revoke all on function public.run_daily_hr_reminders(boolean) from public, anon, authenticated;
grant execute on function public.run_daily_hr_reminders(boolean) to service_role;

select cron.unschedule(jobid) from cron.job where jobname = 'daily-hr-reminders';
select cron.schedule('daily-hr-reminders', '0 2 * * *', 'select public.run_daily_hr_reminders();');
