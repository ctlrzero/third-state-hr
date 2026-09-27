# Smart Employee Onboarding — full build (Builds A–E)

**Status: files only. Nothing here has been applied to production (`yclhzwghzrohusqxfasq`).**
All database access while writing this was read-only (catalog queries, function definitions).
One rolled-back validation run was attempted and stopped by a safety check before it reached the
database. A read-only check afterwards confirmed production is unchanged: no onboarding tables,
columns or functions exist. **The migrations and tests have therefore not been run.** Run
`tests/validate_all_rolled_back.sql` first (see `DEPLOY.md` step 0).

This folder replaces the Build A drafts in `~/Downloads` (`001_onboarding_tables.sql` …
`004_rls_policies.sql`). **Do not run those drafts.** Their policy names clash with these, and they
contain the problems listed below.

## What is in it

| File | Build | Contents |
|---|---|---|
| `migrations/001_onboarding_tables.sql` | A | 18 tables + 4 additive columns (`positions.description`, `employees.employee_number / residential_address / reporting_manager_employee_id`) |
| `migrations/002_onboarding_core.sql` | A | Internal engine: scope checks, audit with operation id, state machine, task generation, derived task status, **readiness engine** |
| `migrations/003_onboarding_build_a_lifecycle.sql` | A | Settings, employee numbering, versioned templates (+ UAE café default), policies, the three entry paths (offer / direct hire / existing pre-boarding employee), setup changes, cancel / withdraw, dashboard list, workspace |
| `migrations/004_onboarding_build_b_preboarding.sql` | B | Invitations (issue / reissue / expiry), employee portal, save-and-resume profile, **self document upload**, bank details, acknowledgements, contract acceptance, section submission, task completion |
| `migrations/005_onboarding_build_c_reviews.sql` | C | Section and task reviews (maker-checker), waivers, pending pay + payroll review, bank verification, exceptions, dashboard summary |
| `migrations/006_onboarding_build_d_activation.sql` | D | `approve_and_activate_employee`: one atomic, idempotent transaction |
| `migrations/007_onboarding_build_e_dayone_probation.sql` | E | Day-one outcome, closure, probation reviews and decisions (≤ 6 months), reports |
| `migrations/008_onboarding_workflow_reminders.sql` | — | `onboarding` workflow module + events, daily reminder / escalation job |
| `migrations/009_onboarding_rls_storage.sql` | — | Select-only RLS on every new table; additive storage policies for pre-boarding uploads |
| `migrations/010_activation_guard.sql` | — | **Deploy only with the UI.** Blocks raw `pre_boarding → active` outside onboarding |
| `migrations/011_onboarding_jobs_availability.sql` | — | Jobs with job descriptions (`upsert_position`); the new starter's weekly availability (`save_my_availability`) |
| `migrations/012_onboarding_immigration.sql` | — | Work permit and visa processing: a case per hire, steps by situation (from abroad, inside the UAE, transfer, own visa, UAE / GCC national); blocking steps feed readiness |
| `migrations/013_offboarding.sql` | — | Offboarding: separation type, UAE minimum notice, last working day to payroll, role checklist, final settlement due in 14 days, controlled finish |
| `tests/onboarding_tests.sql` | — | 84-check persona suite (owner, 2 admins, branch manager, payroll admin, new hire, other company); always rolls back |
| `tests/validate_all_rolled_back.sql` | — | 001–013 + the tests in one transaction that always rolls back. Run this before deploying |
| `DEPLOY.md` | | Order, checks, first-time setup, cron, rollback |
| `API_CONTRACT_ADDITIONS.md` | | Section 12 rows for `claude/API_CONTRACT.md` |
| `REUSE_MAP.md` | | Spec §15: what is reused, what is new, and why |
| `IMPLEMENTATION_REGISTER_UPDATE.md` | | PROC-01, CAP-14 and the rows they affect |

**Frontend:** the onboarding screens are on branch `feat/onboarding`, which is built on
`feat/payroll-v2`. They are:
- `/onboarding` dashboard: pipeline, probation, reports and setup tabs
- workspace drawer for each new starter
- the employee's own portal
- links from Recruiting, the employee profile and Staff Home

They have not been checked against a live database yet, because this backend is not deployed.

## Problems fixed compared with the drafts

1. **Pay leak.** The draft kept pending pay in `pending_*` columns on `onboarding_instances`. That
   table is readable by the branch manager and by the employee through RLS, so both could read the
   salary. Pay now lives only in `onboarding_pending_compensation`, which only the owner, entity
   admin and payroll approvers can read (not the employee themself).
2. **Raw activation still possible.** The draft left `set_employee_status` able to move
   `pre_boarding → active` directly. Branch managers could do this too. Migration 010 closes that
   path. Activation then only happens inside `approve_and_activate_employee`, and only for an
   instance that is `ready_for_activation`.
3. **Anyone could complete any task.** The draft's `complete_onboarding_task` had no owner-role
   check. Each task now has an `owner_role` (employee / location_manager / hr / payroll / approver)
   and a `reviewer_role`.
   - Only the owner role can complete a task.
   - Its dependencies must be done first.
   - Tasks that come from a record can't be ticked by hand: documents, acknowledgements, bank
     details, pay and contract acceptance follow their record.
4. **Pre-boarding employees could not upload or read their documents.** The live storage and
   `employee_documents` policies require `employment_status = 'active'`, and
   `stage_document_upload` is owner / admin / manager only. Two additions fix this without
   changing any existing policy:
   - `stage_my_onboarding_document`
   - additive policies that allow uploads only to paths the server staged for that employee, and
     only while their onboarding is open
5. **No maker-checker.** These now need a second person (the owner is the only exception, as in
   the rest of the system):
   - pay: the person who enters it cannot approve it
   - bank details: the person who submits them cannot verify them
   - sections: the submitter cannot review their own section
   - activation: by default the activator must be neither the pay maker nor its reviewer
     (setting `require_distinct_activation_approver`)
6. **Offer conversion had no duplicate check.** It now refuses when a current employee in the
   same company has the same email or phone. It never compares against other companies.

## Design in one paragraph

- **Two separate statuses.** `employees.employment_status` stays the employment truth.
  `onboarding_instances.status` is the process:
  initiated → awaiting_employee → under_review / changes_required / blocked →
  ready_for_activation → activated → day_one → in_progress → completed (or cancelled / withdrawn).
- **Status is always derived.** Pre-activation status is recalculated on the server after every
  change, from the records themselves. The client never sends "ready".
- **Readiness** lists each blocker with the role that owns it. It checks:
  - setup and duplicate identity
  - required tasks
  - the same key documents `set_employee_status` checks
  - pay approved by payroll
  - contract accepted
  - open blocking exceptions
  - expired invitation
- **Activation** re-checks readiness under a row lock and a version check. Then, in one
  transaction:
  - set the start date
  - activate through the existing `set_employee_status`, which re-checks the documents
  - create the first pay version through the existing `payroll_set_compensation`
  - open probation (settings default 6 months, never more)
  - generate day-one and first-month tasks
  - send deduplicated notifications and write one audit row with an operation id
- **Retries are safe.** Calling activation again returns the first result.

## Added in the second round

- **Template editor** (Setup → Templates: New / Edit / Copy). Editing saves a new version; people already onboarding keep theirs.
- **Jobs** (Setup → Jobs) with job descriptions that the new starter reads in the portal.
- **Availability**: a new task type. The standard template has an optional "Your weekly availability" step, and the employee sets their own days and hours in the portal.
- **Probation ratings**: five 1–5 ratings saved with each review.
- **Work permit and visa tracking** (012): in the workspace, on the employee profile and in Onboarding → Visas & permits.
  - Steps follow the person's situation.
  - The work permit and the MOHRE labour contract (or MOHRE registration for nationals) block activation by default. HR can change this with a reason.
  - Branch managers see only "Work permit paperwork is outstanding".
- **Offboarding** (013, new page `/offboarding`), started from the employee profile or from a no-show / probation-not-confirmed problem.
  - The minimum notice is enforced: 14 days or one month in probation (Art. 9), 30 days after (Art. 43). Shorter notice needs a recorded reason.
  - The last working day goes to payroll.
  - The checklist includes shifts, returned items, logins, final settlement, and work permit / visa cancellation or the pension notice.
  - The final settlement is due within 14 days (Art. 53), and a gratuity estimate comes from payroll.
  - Finishing inactivates the employee and closes their login through `set_employee_status`.

## UAE rules applied

- Probation: at most 6 months in total, including extensions (Decree-Law 33/2021 Art. 9).
  "Not confirmed" does not end employment by itself. It opens an HR exception so the required
  notice is handled in offboarding.
- IBAN format: `AE` + 21 digits.
- Visa: not required for UAE nationals. This is the same rule as `employee_missing_key_documents`.
- Timezone: every date uses Asia/Dubai.
