# TS-HR — Implementation Plan for Claude Code

Place this file in the repo at `docs/HR_IMPLEMENTATION_PLAN.md`. Work one task at a time, e.g.:

> Read `docs/HR_IMPLEMENTATION_PLAN.md` and `CLAUDE.md`. Implement task **P0-1** only. Follow the task's
> steps, run its tests, and stop. Don't start the next task.

Source: the hospitality HR review of 30 Sep 2026 (read-only audit of the live Supabase project
`yclhzwghzrohusqxfasq`). Status labels: **[C]** confirmed in the live DB, **[V]** needs checking in the app code.

---

## Rules for every task

1. `CLAUDE.md` rules always win. In particular: entity boundaries, managers never see pay, published
   payslips never change, corrections keep originals and a reason, no automatic overtime or deductions,
   in-app notifications only, and **no geofencing, biometrics, WPS or external messaging without approved requirements**.
2. All new database functions: `SECURITY DEFINER`, `set search_path = ''`, fully qualified names,
   `revoke all ... from public, anon`, `grant execute ... to authenticated`. Identity from `auth.uid()` only.
3. Server-side checks first; the UI only mirrors them. Never trust a client-supplied role, employee id
   (except assisted upload), readiness, or approval result.
4. Every approval, rejection, adjustment, publication, deletion and deactivation writes `audit_log`.
5. Error codes: `42501` not authorised, `22023` invalid input, `P0002` not found. Messages in plain language.
6. Each task ships with: a migration in `supabase/migrations/`, access tests in `supabase/tests/access_tests.sql`
   (rolled back), an e2e case in `supabase/tests/e2e_journeys.sql` where relevant, UI changes, and an update to
   `docs` / `API_CONTRACT.md` for any new or changed function.
7. Test against a branch or local stack, never straight against production. Before applying to production,
   run the Supabase security advisor and confirm no new findings.
8. Stop and ask before any change that touches pay amounts, payslip publishing, or deletes data.

---

## Task 0 — Sync the repo with the live database (do this first)

Several migrations were applied **directly to production** this week and are not in git **[C]**:

```
scheduling_shift_validation_and_breaks
scheduling_published_shift_adjustment_history
payroll_v2_published_payslip_immutability_and_double_run_guard
documents_accept_client_upload_method_param
scheduling_delete_cancelled_shifts_with_log
scheduling_auto_scheduler (+ _staggered_shifts, _fix_alias, _cover_day_first)
adjust_leave_balance_override
```

Steps:
1. `supabase link --project-ref yclhzwghzrohusqxfasq`
2. `supabase migration list` — confirm the ones above show as remote-only.
3. `supabase migration fetch` (or `supabase db pull`) to bring them into `supabase/migrations/`.
4. Regenerate types: `supabase gen types typescript --linked > src/types/database.ts` (adjust path to repo).
5. Commit: "chore: sync live-only migrations into repo".

Done when: `supabase migration list` shows local and remote identical.

Reference docs already in the project describing these: `Scheduling_Fixes_2026-09-29.md`,
`Payroll_Audit_2026-09-29.md`, `Scheduling_Delete_and_Auto_Scheduler_2026-09-29.md`.

---

## Phase 0 — Fix disconnected workflows

### P0-1 Approved leave must affect the schedule **[C]**
Problem: `approve_leave_request` never reads `shifts`; `validate_shift` never checks leave. A person can hold a
published shift on an approved leave day.

Build:
- In `public.validate_shift()` (trigger `trg_shift_validate`): when a non-cancelled shift has an `employee_id`,
  raise `22023` "This person is on approved leave that day" if an approved `leave_requests` row covers `shift_date`.
- In `approve_leave_request` (approve branch): find the employee's non-cancelled shifts in the leave range.
  **Decision pending (owner):** either (a) cancel them with reason "Approved leave" through the existing history
  mechanism, or (b) return them in the result as `affected_shifts` and flag them for the manager. Implement (b)
  by default; make (a) a setting only if the owner chooses it.
- `publish_schedule_period`: refuse or report shifts that conflict with approved leave (report list in result).
UI: leave approval dialog lists affected shifts with a "Reassign" link; schedule grid marks conflicts.
Tests: shift insert on a leave day fails; approving leave that overlaps a shift returns it in `affected_shifts`.

### P0-2 Swap and open-shift claims must respect eligibility **[C]**
Problem: `claim_shift_swap` only checks the claimer's home location; `claim_open_shift` / `approve_shift_swap`
check no role, leave, availability or weekly hours. Cross-outlet cover is impossible.

Build:
- Extract the eligibility checks from `public._auto_schedule` into a reusable function
  `public._shift_eligibility(p_employee_id uuid, p_shift_id uuid) returns text` (null = eligible, else the reason):
  same company, active, role matches `shifts.position_id`, not on approved leave, available
  (`employee_availability`), no overlap (use `_shift_planned_bounds`), ≤ 48 working hours and ≤ 6 working days in
  the ISO week.
- Use it in `claim_shift_swap`, `claim_open_shift`, `approve_shift_swap` (raise `22023` with the reason).
- Replace the home-location-only rule: allow claims at any active branch of the same company **if** the owner
  enables cross-outlet claims (new `app_settings` key per entity, default off). Approval still by the shift's
  branch manager or admin.
- New read function `suggest_shift_cover(p_shift_id uuid) returns jsonb` — ranked eligible employees
  (home branch first, then fewest hours this week), for managers/admins in scope.
UI: "Find cover" button on a shift → ranked list → pick → existing reassign flow.
Tests: wrong-role, on-leave, over-48h claims refused with the right reason; cross-branch claim refused when the
setting is off and allowed when on.

### P0-3 Schedule the reminder jobs **[C]**
Problem: only `document-expiry-t30-check` runs in `cron.job`. These exist but never run:
`onboarding_send_reminders()`, `_onb_extension_reminders(date)`, `_imm_reminders(date)`, `_off_reminders(date)`.
First read `run_document_expiry_workflow_check()` to confirm it doesn't already call them.

Build: one wrapper `public.run_daily_hr_reminders()` that calls each with the Dubai date, and a pg_cron job
`daily-hr-reminders` at `0 2 * * *` (06:00 Dubai). Make each call independent (one failing doesn't stop the rest;
log failures).
Tests: run the wrapper in a rolled-back transaction with fixtures; notifications created and deduplicated
(second run creates none).

### P0-4 Allow assisted document renewal **[C]**
Problem: `stage_document_renewal` raises "You can only renew your own documents" — contradicts
`Documents_Module_Requirements_Addendum_v2.1.md` BR-DOC-004.

Build: apply the same authorisation as `stage_document_upload` (owner; entity admin own entity; location manager
own location and non-restricted types; or self). Derive `upload_method` server-side. Keep the rule that the
uploader can never approve/reject/archive the document.
Tests: HR renews for an employee → pending review, method `assisted`; the same HR user approving it gets `42501`.

### P0-5 Retire the old payroll engine **[C]**
Problem: `payroll_runs` / `payslips` / `timesheet_entries` engine is still writable; it has no proration and silently
skips employees without pay.

Build: block new inserts into `payroll_runs` (trigger, except maintenance bypass); keep reads so the September
2026 payslip stays visible. Remove old-engine screens from navigation; keep a read-only "Earlier payslips" view.
Confirm the employee payslip list merges `get_my_payslips` (old) and `payroll_my_payslips` (v2).
Tests: new run insert refused; employee still sees the September payslip.

### P0-6 Make the reason compulsory for published-shift changes **[C]**
Current: `adjust_published_shift(...)` and `cancel_published_shift(p_shift_id, p_reason)` exist; direct edits are
recorded in `shift_adjustments` but without a reason.

Build: switch the app's edit and cancel actions to these functions **[V: find the current direct `update` calls on
`shifts`]**. Then add a guard trigger: updates to planning fields of a published shift are refused unless made
through those functions (they set `app.shift_adjust_reason`). Also add a "Delete" action for cancelled shifts using
`delete_cancelled_shifts(p_shift_ids, p_reason)` (owner / entity admin only).
Tests: direct update of a published shift refused; the function with a reason succeeds and history keeps originals.

---

## Phase 1 — Make it fast between services

### P1-1 Schedule screen rework **[C from screenshot]**
Current screen mixes templates, generation, attendance link and list; three date formats
("Wed 30 Sept", "2026-10-01", "29/09/2026"); status doesn't show draft vs published; "3 shifts" counts cancelled.
Build: week grid (rows = people, columns = days) per branch; one date format everywhere (e.g. "Wed 30 Sep");
status pills Draft / Published / Adjusted / Cancelled; count excludes cancelled; row actions Edit, Reassign,
Find cover, Cancel (with reason), Delete (cancelled only); templates and auto-schedule setup moved to a
"Setup" tab; a single branch picker.
Done when: no mixed date formats; draft vs published distinguishable without opening a shift; works at 400 px.

### P1-2 Auto-scheduler UI
Functions exist: `get_scheduling_setup`, `set_location_operating_hours`, `set_location_staffing_needs`,
`propose_auto_schedule`, `apply_auto_schedule` (see `Scheduling_Delete_and_Auto_Scheduler_2026-09-29.md`).
Build: Setup tab (opening hours per weekday, staffing needs); "Plan next week" → preview (shifts, moved staff,
gaps, warnings) → "Create drafts" → normal Publish.

### P1-3 Manager "Today" board
New read function `get_branch_today(p_location_id uuid) returns jsonb`: who's scheduled, clocked in, late,
missing clock-out, open gaps, pending leave/swap/document approvals — scoped by role, no pay data.
UI: phone-first cards, each with one action button.

### P1-4 "Can't come in" (employee)
New function `report_absence(p_shift_id uuid, p_leave_type_id uuid, p_note text)`: creates a pending leave request
for the shift date, flags the shift (`shift_adjustments` change type `absence_reported` — add to the check
constraint), notifies the branch manager, and returns cover suggestions for the manager (P0-2).

### P1-5 Nightly payable time + missing clock-out suggestions
Cron job calling `seed_payable_shift_records` for yesterday per active branch; for open attendance records from a
previous Dubai day, create a *suggested* correction (planned end time, reason pre-filled) that a manager confirms
through `correct_attendance_record`. Never auto-apply.

### P1-6 Transfer workflow
New `transfer_employee(p_employee_id, p_new_home_location_id, p_effective_date, p_reason)`: same company only
(cross-company = offboard + onboard); returns affected future shifts at the old branch, templates to replace,
availability to review; updates `home_location_id` on the effective date. Audit before/after.

### P1-7 Supervisor role
Add `shift_supervisor` to `user_role`. Scope: own branch — today board, attendance view and corrections, swap and
cover actions; **no** pay, bank, documents of restricted types, or employee edits. Update every role-gated function
and RLS policy that lists roles, plus `access_tests.sql` for the new role.

### P1-8 Split-shift templates
`generate_shifts_from_templates` skips a second shift on the same day (`not exists ... same shift_date`). Change to
skip only overlapping shifts (use `_shift_planned_bounds`). Allow two templates per person per weekday.

### P1-9 Employee screens in more languages
**Decision pending: which languages.** Add i18n to the employee screens (home, clock, schedule, leave, documents,
payslips) and a `preferred_language` on `profiles`.

---

## Phase 2 — Assistants that prepare work (after Phases 0–1)

Architecture for all: a Supabase Edge Function that runs **with the caller's JWT** (never the service role for
user-initiated requests), calls existing RPCs only, and calls the Anthropic API for text. Every suggestion stores
its inputs and reason. Nothing writes without an explicit user confirmation. Keep pay amounts out of prompts unless
the owner approves.

| Task | Trigger | What it produces | Who confirms |
|---|---|---|---|
| P2-1 Absence cover | `report_absence`, or no clock-in 15 min after start | Ranked cover list (rules from P0-2) + drafted offer | Manager sends offer; employee accepts |
| P2-2 Pre-payroll readiness | 3 days before pay day, daily until approved | One checklist of blocking items with links | Read-only |
| P2-3 Payroll explainer | After `payroll_prepare` | Plain-language line-by-line change vs last month | Read-only |
| P2-4 Roster summary | After `propose_auto_schedule` | "Why this roster": gaps, moved staff, hours per person | Manager publishes |
| P2-5 Renewal coordinator | 60/30/7 days before expiry; visa step due | Tasks and reminders in the employee's language | HR approves documents |

---

## Open decisions (ask the owner before the related task)

1. P0-1: cancel shifts automatically on approved leave, or flag for reassignment? (default: flag)
2. P0-2: allow cross-outlet claims by staff, or manager-offered only? (default: off)
3. P1-7: add the supervisor role now?
4. P1-9: which languages?
5. Service charge: separate from tips? split basis?
6. Payroll: owner single-step approval, or an accountant as second approver?
7. External messaging (WhatsApp/SMS) — approved or not?
8. Phase 2: OK to send staff names and schedules to the AI provider?
9. Required-document list (D02) approval.

## Verify in the app code first

Mobile clock flow; where the app edits/cancels shifts directly; contract acceptance flow; whether onboarding
activation creates the pay record; whether offboarding cancels shifts after the last working day; accessibility.
