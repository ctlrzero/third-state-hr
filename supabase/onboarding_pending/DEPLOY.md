# Deploying onboarding (Builds A–E)

Target: Supabase project `yclhzwghzrohusqxfasq` (production). Take a backup first
(Dashboard → Database → Backups, or a `pg_dump`).

**Prerequisite:** payroll v2 must already be live, and it is: `payroll_can`,
`payroll_set_compensation` and `compensation_versions` exist on production. Migrations 005 and 006
call them.

## 0. Validate first (nothing is kept)

Open `tests/validate_all_rolled_back.sql`, paste the whole file into **SQL Editor**, and run it.
It applies 001–010, runs the 58 checks as each persona, and then rolls everything back.

- **Expected result:** an error that starts `ONBOARDING_TESTS 58 passed / 58 total || FAILED: none`.
- **Any other error means a bug.** Send me the full message. Nothing was kept.

Confirm nothing was kept:

```sql
select to_regclass('public.onboarding_instances');   -- expect null
```

## 1. Apply 001–009

Run each file in order, one at a time, in SQL Editor (or `supabase db push` after copying them
into `supabase/migrations/` with timestamps). Each file is one transaction.

| Order | File | Notes |
|---|---|---|
| 1 | `001_onboarding_tables.sql` | Tables and additive columns only |
| 2 | `002_onboarding_core.sql` | Internal helpers, not callable from the app |
| 3 | `003_onboarding_build_a_lifecycle.sql` | |
| 4 | `004_onboarding_build_b_preboarding.sql` | |
| 5 | `005_onboarding_build_c_reviews.sql` | |
| 6 | `006_onboarding_build_d_activation.sql` | |
| 7 | `007_onboarding_build_e_dayone_probation.sql` | |
| 8 | `008_onboarding_workflow_reminders.sql` | Replaces `workflow_trigger_catalog()` (existing events unchanged) and widens `workflow_rules_module_check` |
| 9 | `009_onboarding_rls_storage.sql` | Adds policies, including 2 on `storage.objects` |

After 001–009 the live app works exactly as before. The profile's Activate button still works,
and nothing calls the new RPCs until onboarding screens exist.

**Do not run 010 yet.**

## 2. Apply 010 only together with the onboarding UI

`010_activation_guard.sql` makes `approve_and_activate_employee` the only way to activate a
pre-boarding employee. Once it is applied, the existing Activate button fails for pre-boarding
employees with: "Pre-boarding employees are activated from their onboarding".

Deploy 010 in the same release as the onboarding screens. That release should also remove or
redirect that button.

## 3. Checks after deploying

```sql
-- 18 new tables, all with RLS on
select count(*) from pg_tables where schemaname = 'public' and rowsecurity
   and tablename in ('onboarding_settings','employee_numbering','onboarding_templates','onboarding_template_tasks',
   'onboarding_policies','onboarding_instances','onboarding_tasks','onboarding_task_dependencies',
   'onboarding_pending_compensation','employee_payment_details','onboarding_invitations','onboarding_section_submissions',
   'onboarding_reviews','onboarding_exceptions','employee_acknowledgements','employee_contract_acceptances',
   'employee_probation_periods','employee_probation_reviews');                       -- expect 18

-- internal helpers are not callable by the app
select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like '\_onb\_%'
   and has_function_privilege('authenticated', oid, 'execute');                      -- expect 0

-- the app can write to none of the new tables directly
select count(*) from information_schema.role_table_grants where grantee in ('anon','authenticated')
   and table_name like any (array['onboarding%','employee_payment_details','employee_acknowledgements',
   'employee_contract_acceptances','employee_probation%','employee_numbering'])
   and privilege_type <> 'SELECT';                                                   -- expect 0

select public.workflow_trigger_catalog() -> 'onboarding';                            -- 7 events
```

Then run the Supabase security advisor and confirm there are no new warnings.

## 4. First-time setup (per company, as owner or entity admin, from the app or SQL)

1. `select public.seed_default_onboarding_template('<entity_id>');` creates the UAE café
   template (19 tasks) and 3 placeholder policies.
2. Replace the placeholder policy text with the real text:
   `select public.upsert_onboarding_policy('<entity_id>', 'employee_handbook', '1', 'Employee handbook', '<text>');`
   Do the same for `privacy_notice` and `food_safety_sop`.
3. Optional:
   - `set_onboarding_settings('<entity_id>', '{"probation_months":6,"invitation_valid_days":7}')`
   - `set_employee_numbering('<entity_id>', 'TSC-', 1, 4)`
4. Add job descriptions to `positions.description`. Employees see them in the portal.

Entity ids: Third State Cafe `667d957f-77a3-4419-bb79-8ca332d20f01`,
Ateej Tea Brew `06d3d9c9-b673-40dd-a257-75c9d1b11d32`.

**The existing pre-boarding employee** (created before onboarding existed): run
`select public.start_onboarding_for_employee('<employee_id>', '<manager_employee_id>', 'Started before onboarding existed');`.
This attaches them to the same lifecycle without creating a second record.

## 5. Daily reminders (optional, needs pg_cron, which is installed)

Sends one reminder per person per day, escalates overdue items to HR after 2 days, expires old
invitations, and raises probation-review-due events.

```sql
select cron.schedule('onboarding-reminders', '0 5 * * *', $$select public.onboarding_send_reminders()$$);  -- 09:00 Dubai
-- remove later with: select cron.unschedule('onboarding-reminders');
```

## 6. Sending the invitation email

`issue_onboarding_invitation` creates the pending staff access grant and records the invitation.
It returns `send_email: true` when the person has no login yet. The app then sends the email with
the existing invite-user Edge Function, the same way Access management does today. When the person
signs up, the existing `handle_new_user` trigger links the login to the employee.

## Rollback

010 only:

```sql
-- re-run the previous definition of set_employee_status (the body in 010 without the
-- "ONBOARDING GUARD" block), or restore from the backup.
```

Everything else is additive. To remove it completely, drop the new tables and functions:

```sql
begin;
drop table if exists public.employee_probation_reviews, public.employee_probation_periods,
  public.employee_contract_acceptances, public.employee_acknowledgements, public.onboarding_exceptions,
  public.onboarding_reviews, public.onboarding_section_submissions, public.onboarding_invitations,
  public.employee_payment_details, public.onboarding_pending_compensation, public.onboarding_task_dependencies,
  public.onboarding_tasks, public.onboarding_instances, public.onboarding_policies, public.onboarding_template_tasks,
  public.onboarding_templates, public.employee_numbering, public.onboarding_settings cascade;
drop policy if exists documents_select_preboarding_self on public.employee_documents;
drop policy if exists doc_bucket_write_preboarding_self on storage.objects;
drop policy if exists doc_bucket_read_preboarding_self on storage.objects;
-- then restore workflow_trigger_catalog() and workflow_rules_module_check from the backup (or the
-- definitions quoted in 008 minus 'onboarding'), and drop the onboarding functions:
-- select 'drop function '||oid::regprocedure||';' from pg_proc where pronamespace='public'::regnamespace
--   and (proname like '%onboarding%' or proname like '\_onb\_%' or proname like '%probation%'
--        or proname in ('verify_payment_details','save_my_payment_details','approve_and_activate_employee',
--                       'accept_employment_contract','get_my_contract','get_my_job_description','set_employee_numbering'));
commit;
```

The added columns (`positions.description`, `employees.employee_number`, `residential_address`,
`reporting_manager_employee_id`) are harmless to leave in place.
