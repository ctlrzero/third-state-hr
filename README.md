# TS-HR — Third State Café HR frontend

React + TypeScript + Vite + Tailwind v4, wired directly to the live **TS-HR**
Supabase project (`yclhzwghzrohusqxfasq`). Built against:

- `Third_State_Cafe_HR_Design_and_UI_UX_Specification_v1.0.md`
- `Third_State_Cafe_HR_Development_Requirements_v2.0.md`
- The live schema, RLS policies and RPCs on the `TS-HR` Supabase project.

## What's built in this pass

- **UX-01** Sign-in (`/sign-in`) — email/password via Supabase Auth, loading/invalid/no-assignment states.
- **UX-02** Operations dashboard + Action Centre (`/`) — KPI cards, exception queue (leave, expiring documents), branch coverage, role-scoped (payroll tile hidden for Café Manager).
- **UX-04** Employee directory (`/employees`) — searchable/filterable roster, desktop table + mobile record cards, no salary/compensation fields requested by this screen.
- **My Profile** (`/me`) — employee self-service: view your own record (role, branch, employment type, dates), a document-expiry glance for passport/visa/labor/health cards, a compact schedule history of your last 10 past shifts plus a link into Schedules, and a request-change flow for phone/email/emergency contacts that requires owner/admin/manager approval before it takes effect. See the My Profile section below and the Employee schedule history section for a real scoping bug this uncovered.
- **Schedules** (`/schedules`) — owner/entity_admin/location_manager get a shift roster (create/cancel shifts, assign or leave open, resolve swap requests); staff get "My Schedule" (own upcoming shifts, an open-shift board and swap board scoped to their own branch, and their own swap request history). See the Schedules section below — this one needed real RLS fixes, not just new screens.
- **Leave** (`/leave`) — owner/entity_admin/location_manager get a decision queue for pending leave requests plus recent history; staff get "My Leave" (per-type balances, a request form, and their own request history). See the Leave section below — two read-access gaps and one RPC idempotency bug were found and fixed.
- **Reports & audit** (`/reports`) — owner/entity_admin/location_manager get cross-module summary metrics (headcount, open requisitions, pending documents/leave, open shifts, swaps awaiting approval, and payroll runs in progress where applicable) for the active entity, plus an audit log viewer with date range/module/table/action/actor/employee filters, entity/branch narrowing and CSV export for owner/entity_admin, and now a curated view for location_manager too (previously hard-blocked client-side despite the backend already supporting it). Not shown to staff. See the Reports & audit section and Audit filtering and export section below — this one uncovered a real cross-tenant data leak in the existing `audit_log` RLS, not just a missing screen.
- **Employee profile** (`/employees/:id`) — the drill-in from People: full record, document expiry glance, current documents on file, recent leave requests, and a pending change-requests decision queue (using `decide_employee_change_request()` — this closes the "no admin-facing approvals list" known limitation from My Profile). Compensation and identity documents sit behind an explicit Reveal click, and only render for owner/entity_admin at all. See the section below.
- **UX-05** Documents (`/documents`) — full review/approval workflow: manager register with separate approval status and computed expiry status, version history, review drawer (approve/reject with required reason), archive (soft-retire, no hard delete of approved docs); employee self-service renewal upload with pending/rejected states and resubmit. See the workflow section below for how this is enforced.
- **Recruiting** (`/recruiting`) — requisitions with configurable interview stages, a candidate pipeline per requisition (add candidate, move through applied → screening → interviewing → offer → hired/rejected/withdrawn, required reason on rejection), interview scheduling and pass/fail outcomes, cancellation with a required reason, offer creation/send/decision, and one-click conversion of an accepted offer into a new (pre-boarding) employee record via `convert_offer_to_employee`. Interviewer feedback stays private to its author and Recruiting Admin/Owner until the round is complete or explicitly closed — see the Interview feedback reveal gating section below. See the Recruiting section below for scope notes.
- **My Interviews** (`/my-interviews`) — a small employee-facing module so staff assigned as interviewers can see and act on their own interviews without any access to the Recruiting area. See the My Interviews section below for the full access model and policy decisions.
- **Payroll** (`/payroll`) — Owner/Entity Admin get a full payroll-run screen: create a run for a pay period, enter timesheet hours and pooled tips, add ad-hoc deductions, confirm overtime/holiday pay and tip distribution, run the calculation (`run_payroll_calculation`), and progress the run draft → in review → approved → paid. Staff get a read-only "My Pay" history of their own payslips with a deduction breakdown. Location Manager has no Payroll nav entry — see the Payroll section below for why.
- App shell with role-aware navigation (Owner/Admin, Café Manager, Employee), entity switcher for multi-entity owners, and a mobile bottom nav.
- Visual design matches the reference build at `third-state-hr.aishalzaabi.chatgpt.site` (palette, card/shadow/radius tokens, typography extracted from its live CSS).

Every route in the app now has a real screen — there's no `ComingSoon` left
anywhere in the router.

### Documents module — workflow, storage, and enforcement

`employee_documents` now carries a full review/version lifecycle, kept deliberately
separate from expiry status:

- `review_status`: `pending_review` → `approved` (or `rejected`), and later `superseded`
  (when a newer version is approved) or `archived` (manager/owner retires a doc without
  deleting it). This is **never** conflated with expiry — expiry is always computed
  client-side in `src/lib/documents.ts` from `expiry_date` vs. today (`expired` /
  `expiring` within 30 days / `current` / `non_expiring`), never stored.
- `version_number`, `supersedes_document_id`, `is_current` track version lineage; a
  partial unique index (`... where is_current = true`) guarantees at most one current row
  per employee/doc type.
- `submitted_by/at`, `reviewed_by/at`, `rejection_reason`, `archived_by/at`, `storage_path`
  round out the audit trail on the row itself.

**Employee renewal flow**: an employee can upload a replacement for their own current
document only. It's inserted as a new row (`pending_review`, `is_current = false`,
`version_number + 1`, linked via `supersedes_document_id`) — the existing approved
document stays current and visible until a manager/owner reviews it. Approval is atomic:
the old row flips to `superseded` and the new row flips to `approved` + `is_current` in
the same RPC call (`approve_document`), so there's never a moment with zero or two
current rows. Rejection requires a reason, leaves the previous version current, and lets
the employee resubmit.

**Approval matrix**: manager/owner-initiated uploads (`create_document_upload`) now land
as `pending_review` by default — none of them are auto-approved just because an admin
uploaded them. Who may approve what is encoded once, in `public.can_review_document()`,
and enforced at both the trigger layer (any INSERT/UPDATE) and inside `approve_document`/
`reject_document`:

- **Employee upload** — Owner, any Entity Admin, or a Location Manager (only for
  non-sensitive types) may approve; never the employee themselves.
- **Location Manager upload** — only the Owner or an Entity Admin may approve. No
  Location Manager can approve it, including the one who uploaded it — this is a stronger
  guarantee than "not the same manager": no location_manager reviewer is ever accepted for
  a location_manager submission.
- **Entity Admin upload** — sensitive document types always require Owner approval. For
  ordinary operational types, the same Entity Admin may self-approve only once the owner
  has turned on **Entity Admin self-approval** (a toggle on the Documents page, backed by
  `public.entity_admin_self_approval_enabled()` / `set_entity_admin_self_approval()`,
  owner-only, off by default).
- **Owner upload** — immediately approved, since the owner is the authoritative HR
  controller. Even so, the upload and the approval are always two distinct `audit_log`
  rows (`document_uploaded` then `document_approved`), never a single merged event.

The **sensitive** document set — passport, Emirates ID, visa, contract, offer letter,
bank/payment document, and salary/compensation evidence — is defined once in
`public.is_restricted_doc_type()` (reused from the earlier location_manager-visibility
restriction, now broadened) and mirrored in the frontend's `RESTRICTED_DOC_TYPES`. A
Location Manager cannot see, upload, or approve any of these regardless of the settings
above.

Self-approval is blocked everywhere it isn't explicitly carved out above — enforced by
`enforce_document_insert_invariants()` / `enforce_document_update_invariants()` calling
`can_review_document()`, not just by a UI condition. A direct client-side table insert
(bypassing the RPCs) can only ever land as `pending_review`; the only way to get an
approved-at-insert row is through `create_document_upload`, which itself defers to
`approve_document()` for the actual approval step — so the authority check only lives in
one place.

**Storage**: the `employee-documents` bucket is private. Its read/write/delete policies on
`storage.objects` mirror the table RLS exactly (owner sees everything; entity_admin scoped
to their entity; location_manager scoped to their location's employees, excluded from
`contract`/`offer_letter`; staff limited to their own employee_id) using the path
convention `entity_id/employee_id/document_id/version_number/filename` via
`storage.foldername()`. Client code never trusts a client-supplied `entity_id`/
`employee_id` for the path — both come from the authenticated session server-side. Files
are only ever accessed via short-lived signed URLs (`createSignedUrl`), never public URLs.

**Deletion**: there is no hard delete for approved documents anywhere in the UI. Owner/
admin/manager use **Archive** (`archive_document` RPC) instead, which sets
`archived_by/at`, flips `is_current` false, and keeps the storage object and full audit
trail — an archived document never shows as current. The one exception is
`delete_pending_document`, which only removes a `pending_review`, not-current row (e.g. a
failed upload before review) and logs the deletion. Permanent purge past a retention
period is intentionally **not** part of this UI — it would need a separate,
owner/admin-only retention process.

**Audit**: every upload, renewal submission, view/download, approval, rejection, archive,
and unauthorized-access attempt is logged to the existing generic `audit_log` table via
the RPCs (or `log_document_access` for reads), capturing actor, action, and document/
version — never file contents or full document numbers.

All of the above is enforced by Postgres RLS and RPCs, not UI conditions — see
`supabase/migrations` (or the project's migration history) for the exact policies. A SQL
negative-access test suite (run manually against the live project in a rolled-back
transaction) exercises cross-employee reads, cross-entity reads, self-approval attempts,
inactive-employee access, and storage path tampering; `src/lib/documents.test.ts` covers
the pure expiry/doc-type logic with `vitest`.

**Known limitations / assumptions**:

- There's no in-app notification when a renewal or a manager-initiated pending upload is
  submitted — reviewers see it via the existing "Pending review" filter in the register,
  since this schema has no notifications table.
- Where the requirement said "Owner/Admin approval for sensitive document types" on an
  Entity Admin's own upload, this is implemented as **Owner only** — an Entity Admin
  approving their own sensitive upload would just be self-approval again, so "Admin" here
  can't mean the same entity_admin. Worth confirming that reading matches intent.
- The sensitive document set (passport, Emirates ID, visa, contract, offer letter,
  bank/payment, compensation) is broader than the previous restricted set (which was just
  contract/offer_letter). That means Location Managers can no longer see, upload, or
  approve employee passports/visas/Emirates IDs at all, where they previously could. This
  is a deliberate reading of "at minimum" in the requirement, not an incidental side
  effect, but it's a real behavior change worth confirming with whoever owns this policy.
- Storage write policies still can't check document type (the storage path doesn't encode
  it, only `entity_id/employee_id/document_id/version_number/filename` does) — so a
  Location Manager could technically write a storage object into a path that a sensitive
  document would use, even though the corresponding table insert for that doc_type would
  be rejected. An orphaned object with no approvable table row is inert, but tightening
  this properly would mean encoding doc_type in the storage path. Pre-existing limitation,
  not introduced by this change, but now more relevant given the larger sensitive set.
- Permanently purging archived documents after a retention period has no UI or RPC yet —
  by design, per the spec — and would need its own owner/admin-gated process before it's
  built.

### Payroll

A run moves `draft` → `in_review` → `approved` → `paid`; the DB trigger
`prevent_payroll_run_status_regression` blocks ever moving an approved/paid run back, so
the UI only ever offers the next forward transition and never a way to undo one.

**Immutability model (tightened).** Timesheet entries, tips pools and payslip deductions
are only editable while the parent run is **Draft** — not Draft-or-in-review as the
previous revision of this doc described. This is a deliberate behavior change: in-review
runs are now read-only, matching a literal reading of "allow changes only while Draft."
Enforcement is layered:

1. **Grants removed.** `authenticated` no longer has INSERT/UPDATE/DELETE on
   `timesheet_entries`, `tips_pools` or `payslip_deductions` at all. Every application
   mutation goes through a SECURITY DEFINER RPC (below); direct REST/SQL table writes are
   rejected outright by Postgres before RLS is even evaluated.
2. **RPC-level gate.** Each RPC (`record_timesheet_entry` / `delete_timesheet_entry`,
   `record_tips_pool` / `delete_tips_pool`, `record_payslip_deduction` /
   `delete_payslip_deduction`) resolves the caller from `auth.uid()`, derives role/entity
   server-side (`my_role()`, `my_entity()`, `my_location()` — never a client-supplied
   value), takes `SELECT ... FOR UPDATE` on the parent `payroll_runs` row (so a concurrent
   status-advance and a concurrent edit serialize against each other correctly), and checks
   `status = 'draft'`.
3. **Trigger backstop.** `enforce_payroll_child_immutability()` (a `BEFORE INSERT OR
   UPDATE OR DELETE` trigger on all three tables) independently re-checks the parent run's
   status and raises a hard exception if it isn't `draft`. This exists purely as a
   defense-in-depth backstop in case a grant or RLS policy were ever misconfigured back
   open — it is enforcement-only and does not write to `audit_log` (see below for why).
4. **Corrections to an approved/paid run** go through `create_payroll_revision(p_source_run_id)`,
   which opens a brand-new `draft` run linked back via `payroll_runs.revises_payroll_run_id`,
   seeded with copies of the source run's timesheet/tips/deduction rows. The source run's
   own rows are never touched — verified live: editing the revision leaves the original
   run's rows byte-for-byte unchanged. Multiple revisions of the same source run are
   allowed (each independent, each linked back to the same source) — corrections to an
   already-corrected run are a legitimate real-world case, not something to block.

**Rejected vs. successful actions (RPC contract).** Every mutation RPC returns a JSON
object rather than throwing on a locked-run write:
`{ "ok": false, "code": "PAYROLL_RUN_LOCKED", "message": "...", "request_id": "<uuid>" }`
on rejection (also `NOT_AUTHORIZED` for a cross-entity/cross-location attempt, `NOT_FOUND`
for a bad id), or `{ "ok": true, "request_id": "<uuid>", "id": "<new row id>" }` on
success. The client (`Payroll.tsx`) checks `result.ok` explicitly — a rejected action is
not a thrown/network-level error, it's a normal RPC response the UI must interpret.

**Why rejections return normally instead of raising:** the first design attempt had the
RPC raise an exception on a locked run and log the rejection to `audit_log` just before
raising. That doesn't work in Postgres — raising an exception rolls back everything done
in the same transaction, including the log insert, so the rejection was enforced but never
durably logged. The standard fix is an autonomous transaction (e.g. via the `dblink`
extension, logging on a separate connection that commits independently of the aborting
one). That path was deliberately abandoned: enabling `dblink` and, worse, provisioning a
dedicated login role/password for the loopback connection are exactly the kind of
system/security-credential changes this project treats as off-limits for an agent to set
up unilaterally. **No `dblink` extension, `audit_logger` role, password, or Vault secret
exists anywhere in this schema.** Instead, the RPC *returns normally* on rejection (so its
audit_log insert is part of a transaction that actually commits) and lets the client treat
`ok: false` as the rejection signal.

**Audit boundary (documented, not a bug):**

- `audit_log` (`payroll_change_succeeded` / `payroll_change_rejected`) records every
  successful change and every rejected attempt made **through the supported RPCs** —
  this is the business-facing audit trail, visible to owner (all) and entity_admin (own
  entity, via `get_audit_log()`).
- A **direct** SQL/PostgREST write that reaches the trigger backstop (e.g. because a grant
  was mistakenly restored) is blocked but does **not** produce an `audit_log` row, for the
  same transactional reason described above — logging a blocked write and rejecting it in
  the same transaction is not possible without an autonomous transaction, which this
  project does not use. Direct-database and bypass attempts are expected to be visible in
  Postgres/pgAudit platform logs, not in the application's business audit trail. This is an
  approved, intentional gap, not an oversight — RLS and the trigger still fully enforce the
  immutability invariant regardless of whether a business audit row exists for that
  specific attempt.

**Access model** (unchanged from the original build): **Owner / Entity Admin** create runs,
enter timesheets/tips/deductions via the RPCs above, confirm the two required checkboxes,
then call `run_payroll_calculation` to generate payslips (itself already blocked on a
non-draft run, independent of today's change). **Location Manager** has no Payroll nav
entry at all — their RPC-level location-scoped access to timesheet entries and tips pools
exists (mirroring the pre-existing RLS scope) but is designed to be exercised from the
**Schedules** module, not this screen. **Staff** get "My Pay": their own payslip history,
read-only, via the pre-existing `payslips_select_self` / `deductions_select_self` policies.

**Verified live** (direct SQL, not just through the UI — `begin ... rollback` transactions
against the real schema, impersonating each role via `request.jwt.claim.sub`):

- Draft: insert/update/delete on all three child tables succeeds.
- In-review, approved, paid: every insert/update/delete via the RPCs returns
  `ok:false, code:PAYROLL_RUN_LOCKED` and changes no data; a `payroll_change_rejected` row
  is logged and visible to the owning entity_admin via `get_audit_log()`.
- Direct table INSERT (bypassing the RPCs entirely) is denied outright — no grant exists.
- Restoring the grant temporarily and attempting a direct write against a locked run is
  still blocked by the trigger backstop (proves defense-in-depth actually holds).
- Cross-entity: a different entity's admin gets `NOT_AUTHORIZED` from every mutating RPC
  and from `create_payroll_revision()` — no client-supplied id can read or reach another
  entity's rows.
- Repeated/idempotent rejected calls each log independently and never mutate data.
- A run approved and then immediately edited-against reads the true committed status
  (not a stale value), confirming the `SELECT ... FOR UPDATE` lock serializes an edit
  attempt correctly against a concurrent status advance.
- `create_payroll_revision()` on an approved and a paid run both succeed, seed correctly,
  stay independently editable, and never mutate the source run; a second revision of the
  same source is independently created.
- `tsc -b`, `vite build`, `oxlint` and `vitest run` all pass with these changes (0 type
  errors, 0 lint errors, 17/17 unit tests).

### Recruiting

Built against the existing `job_requisitions` / `candidates` / `job_applications` /
`interview_stages` / `interviews` / `offers` tables and the `convert_offer_to_employee`
RPC — no schema changes.

- **Owner / Entity Admin** have full access everywhere. **Location Manager** can create
  and manage requisitions, candidates, applications and interviews for their own
  location (matches the existing `candidates_access` / `requisitions_modify` /
  `applications_access` RLS, which already scoped these tables to
  `location_id = my_location()`), but the **Offers** panel only renders for
  owner/entity_admin — `offers_access` RLS never granted location_manager any access to
  compensation figures, consistent with how Payroll and the sensitive Documents types are
  treated.
- An assigned interviewer's access is now handled by the separate **My Interviews**
  module (below), not by this screen. The interviewer's own read access to `interviews`
  is SELECT-only — the previous `interviews_access` policy actually granted the assigned
  interviewer unrestricted read/write on their row (assignment, outcome, everything);
  that was a real gap relative to "interviewers can't change assignments or status" and
  has been replaced with `interviews_interviewer_select` (SELECT only) plus
  `interviews_admin_all` (the owner/entity_admin/location_manager write path used by this
  screen).
- The interviewer picker only lists employees who have a linked login
  (`auth_user_id is not null`), since `interviews.interviewer_id` references
  `auth.users`, not `employees` — an interviewer must be someone with an account in the
  system.
- `convert_offer_to_employee` requires the offer to be `accepted` and creates the new
  employee as `pre_boarding` with no payroll/compensation fields populated — those still
  need to be entered separately in `employee_compensation`, which is intentional (payroll
  stays a walled garden, per the RPC's own comment).

### My Interviews

A small employee-facing module (`/my-interviews`) so a staff member assigned as an
interviewer can see and act on their own interviews without exposing the administrative
Recruiting area at all — no candidate register, no requisition pipeline, no recruitment
reports or pipeline totals ever reach this role.

**Navigation**: the "My Interviews" nav item only renders when `has_interview_assignments()`
(resolved from `auth.uid()`) returns true. This is a discoverability convenience only, not
a security control — the route itself, `get_my_interviews()`, and `get_interview_detail()`
all independently re-check assignment/entity/status/window every time, so guessing the URL
or calling the RPC directly with no assignment just returns an empty list / a "not found or
not accessible" error, never another interviewer's data.

**What an interviewer can see, and how it's enforced**: every read goes through
`get_my_interviews()` / `get_interview_detail()` / `list_candidate_files_for_interview()` —
curated `SECURITY DEFINER` RPCs that return a hand-picked column set (candidate display
name, position title, date/time/format, meeting location or link, interview guide, the
interviewer's own feedback status, and — if explicitly marked
`visible_to_interviewers = true` — an approved résumé or interview pack). The interviewer
role has **zero** direct `SELECT` grant on `candidates`, `job_applications`, or `offers` at
all, so even a raw REST call to those tables returns nothing for this role; salary
expectations, compensation, passport/Emirates ID/visa/bank documents, private HR notes,
background checks, and other interviewers' pre-reveal feedback are never reachable, not
just hidden by the UI. `interviews` itself is `SELECT`-only for the assigned interviewer
(`interviews_interviewer_select`) — no `UPDATE`/`INSERT`/`DELETE` policy exists for that
role, so assignment, candidate stage, requisition status, and hiring decisions can only be
changed through the owner/entity_admin/location_manager admin path in Recruiting.

**Identity**: every RPC resolves the caller from `auth.uid()` / `my_employee_id()` /
`my_entity()` server-side. None of them accept an `employee_id` parameter, so there is no
channel for the client to supply — or for a compromised client to spoof — a different
employee's identity.

**Interview workflow and feedback**: states are `Upcoming` → `Completed` → (interviewer
submits) `Feedback Submitted`, or `Cancelled` at any point (shown with the reason, nothing
else redacted-worthy). Feedback (`interview_feedback`) has no direct interviewer
`INSERT`/`UPDATE` policy either — all writes go through `save_interview_feedback_draft()`
(repeatable, upserts a `draft` row) and `submit_interview_feedback()` (requires a
recommendation, stamps `submitted_at`, and the RPC itself refuses to touch a row once its
status is `submitted`, so a client retrying the draft call after submission gets a clear
error instead of silently corrupting the record). Only `owner` / `entity_admin` may call
`reopen_interview_feedback()`, which requires a non-empty reason and stores it on the row
for audit (`location_manager` is deliberately excluded here, even though they can cancel
interviews). Cancelling an interview (`cancel_interview()`, requires a reason) also blocks
any further `save_interview_feedback_draft()` call for that interview.

**Files**: candidate files live in a private `candidate-files` storage bucket. The
interviewer's storage read policy resolves to the exact object path via a join against
`candidate_files.storage_path` — never a folder-level or prefix grant — and only for rows
explicitly opted in via `visible_to_interviewers = true`. The client calls
`log_candidate_file_access()` (which re-validates the same assignment/entity/window/active
chain and audit-logs the attempt, successful or not) immediately before requesting a
60-second signed URL from `createSignedUrl` — so an unauthorized attempt is both blocked by
RLS and recorded, and even an authorized signed URL is short-lived and scoped to that one
file, never a document folder.

**Audit**: interview views (`interview_viewed`), draft saves (`feedback_draft_saved`),
submissions (`feedback_submitted`), reopens (`feedback_reopened`), cancellations
(`interview_cancelled`), and file access — both successful (`candidate_file_accessed`) and
denied (`unauthorized_access_attempt`) — are all written to the existing `audit_log` table
by the RPCs themselves, not the client.

**Policy decisions** (per the request to document these explicitly, since they weren't
defined elsewhere):

- **Visibility window** — `interview_visibility_window_days()` currently returns **30**. An
  interviewer can see an interview from the moment they're assigned until 30 days after its
  `scheduled_at`, *unless* their feedback is still unfinished (no feedback row yet, or its
  status is `draft`/`reopened`), in which case it stays visible with no expiry until they
  submit — so an interviewer can never be locked out of an interview they still owe
  feedback on, but old, fully-closed interviews eventually drop out of their list. This is
  a single tunable SQL constant, not hardcoded in multiple places.
- **Feedback reveal point** — by construction, never, for peer interviewers. Each
  interviewer's RPCs only ever surface their own row (`submitted_by = auth.uid()` /
  `interviewer_id = auth.uid()`); there is no "reveal after N submissions" or "reveal after
  the loop closes" mechanism, because nothing currently aggregates feedback across
  interviewers for a shared reveal moment. Recruiting admins (owner/entity_admin, plus
  location_manager for their own location) can always see all feedback on an interview,
  including drafts, via `interview_feedback_admin_all` — that's an intentional admin
  visibility exception, not a reveal-point rule for peers.

**Update (later pass): reschedule support.** The above limitation — no reschedule RPC, a
cancelled interview just stays cancelled — is now closed. Added a nullable
`rescheduled_from_interview_id` column on `interviews` (mirrors
`employee_documents.supersedes_document_id`) and `reschedule_interview(p_interview_id,
p_new_scheduled_at, p_new_interviewer_id, p_format, p_meeting_location, p_reason)`, a
`SECURITY DEFINER` RPC that atomically cancels the source interview (if not already
cancelled, with `cancellation_reason` defaulting to `'Rescheduled'`) and inserts a new
`interviews` row in the same stage, carrying over the interviewer/format/meeting_location
unless explicitly overridden, linked back via `rescheduled_from_interview_id`. It
re-checks the same authorization `cancel_interview()` already enforces (owner any;
entity_admin own entity; location_manager own location) rather than trusting the RLS
grant on a raw insert, and blocks a second reschedule from the same source interview
(`exists (select 1 from interviews where rescheduled_from_interview_id = p_interview_id)`)
so a duplicate click can't spawn two follow-ups. Logs `interview_rescheduled` to
`audit_log`, which `get_audit_log()` resolves through the existing `interviews` join chain
with no changes needed there. Recruiting's admin UI (`Recruiting.tsx`) got a matching
"Reschedule" button next to Cancel — hidden once an interview already has a follow-up —
plus a note on the follow-up row pointing back to the original time and vice versa.

Verified against the live database in a rolled-back transaction: rescheduling returns a
new interview id and links it back to the source; the source interview is cancelled with
the given reason; the new interview carries over the original interviewer and starts
`pending`; a second reschedule attempt on the same source is blocked; the reschedule is
recorded in `audit_log` (visible via `get_audit_log()`, not a direct table select — this
is the same owner-only-table / RPC-scoped-for-entity_admin split from the Reports & audit
section above, still working correctly here); and an entity_admin from a different entity
can't reschedule an interview outside their scope — 6/6 checks passed (a 7th assertion
that queried `audit_log` directly instead of through `get_audit_log()` was a test-authoring
mistake on my part, not a product bug — entity_admin correctly has no direct table access
there since the Reports & audit fix).

### My Profile

Built entirely against existing tables/RLS/RPCs — `employees` and `employee_change_requests`
already had exactly the right shape; no schema changes.

- **View**: the page selects the caller's own `employees` row via
  `auth_user_id = auth.uid()` (already granted by the existing `employees_select` policy)
  and deliberately only asks for a curated column list — never `notes`, never anything from
  `employee_compensation` or `employee_identity_documents` (pay rate, bank details, and
  identity document numbers stay owner/entity_admin-only, same as everywhere else in this
  app).
- **Editing**: an employee has no `UPDATE` grant on `employees` at all — `employees_update`
  is owner/entity_admin/location_manager only. So contact-field edits go through
  `employee_change_requests` instead: the employee inserts a `pending` row for their own
  `employee_id` (allowed by `change_requests_insert`'s self-service clause, which also
  requires `decided_by`/`decided_at` to be null — an employee cannot insert a
  pre-approved row for themselves), and only an owner/entity_admin (their entity) or
  location_manager (their location) can call `decide_employee_change_request()` to approve
  or reject it. Requestable fields are exactly the four the RPC knows how to apply on
  approval — phone, email, emergency contact name, emergency contact phone — matched 1:1 in
  the frontend's `REQUESTABLE_FIELDS` list so the UI never offers a field the backend can't
  action. Approval and rejection both require going through the RPC; there's no direct
  `UPDATE` path on `employee_change_requests` available to the employee themselves once
  submitted (`change_requests_update` is admin-role only).
- The page shows the employee's own request history (status, decision reason, timestamp) so
  they can see what's pending or was rejected and why, without needing a separate approvals
  inbox.
- Document expiry (passport/visa/labor card/health card) is shown read-only, reusing the
  same `expiryStatus()` logic as the Documents module, with a link over to Documents for the
  actual upload/renewal flow — this screen never duplicates that workflow.

**Known limitation**: there's currently no admin-facing approvals list for
`employee_change_requests` anywhere in this build (Employee Directory doesn't surface
pending requests yet) — an owner/admin/manager would need to call
`decide_employee_change_request()` directly (e.g. via the Supabase dashboard or a future
small addition to Employee Directory) until that UI exists. The RLS and RPC are fully
built and tested; only the admin-side list view is outstanding.

### Schedules

`shifts` and `shift_swap_requests` already existed with the right shape, but the RLS
around them had real gaps once you looked at what a `staff` login could actually do — not
just what the UI would show them.

**What was already there**: `shifts_access` (ALL, owner/entity_admin/location_manager
only) and `approve_shift_swap()` (same three roles, reassigns the shift on approval). No
schema changes were needed for either.

**Gaps found and fixed in this pass**:

- **Staff had zero read access to `shifts` at all** — not even their own assignments.
  Added `shifts_select_self` (`employee_id = my_employee_id()`) and
  `shifts_select_open_home_location` (`status = 'open' and location_id = my_home_location()`,
  via a new `my_home_location()` helper mirroring `my_employee_id()`) so staff can see their
  own schedule and unfilled shifts at their own branch, and nothing else.
- **The `claimed_by = my_employee_id()` branch on `shift_swap_requests`' `UPDATE` policy had
  no other constraint** — a claimant could, in the same statement, also rewrite `status` to
  `approved` and `resolved_by` to themselves, self-approving a swap. And the `requested_by`
  branch had no check that the shift being swapped actually belonged to the requester.
  Fixed by removing every staff-facing branch from `swaps_insert`/`swaps_update`/
  `swaps_delete` entirely (they're now admin-role-only, matching `shifts_admin`-style
  scoping) and routing every staff write through a `SECURITY DEFINER` RPC instead:
  `request_shift_swap()` (validates the shift is actually the caller's, not cancelled, not
  in the past, and doesn't already have an open/claimed request), `claim_shift_swap()`
  (blocks claiming your own request, requires the shift's location to match
  `my_home_location()`, blocks claiming an already-cancelled shift), `claim_open_shift()`
  (same location/active-employee checks, for picking up an unfilled shift directly), and
  `cancel_shift_swap_request()` (requester-only, and only while still `open`/`claimed` — a
  status change, never a hard delete, so it stays in the audit trail).
- **`swaps_select` only ever showed a staff member rows they'd already created or
  claimed** — there was no way to browse what else was open to claim. Added a clause so
  staff can also see `status = 'open'` requests for shifts at their own home location (the
  "open swap board"), still fully separate from admin's entity/location-wide visibility.

All four staff RPCs were tested against the live database in a rolled-back transaction:
own-shift vs. other-location visibility, self-claim rejection, cross-location claim
rejection, same-location claim success, manager approval actually reassigning the shift,
claimant-can't-cancel-requester's-request, and can't-cancel-an-already-resolved request all
passed.

**Known limitations**: there's no shift template/recurrence (each shift is created one at a
time), no clock-in/clock-out or hours-worked capture here (that's `timesheet_entries` in
Payroll, a separate table), and cancelling a shift from the admin roster doesn't
auto-resolve any swap request still open against it — the swap would need to be rejected or
would simply become moot once the shift shows as cancelled.

### Leave

`leave_requests`, `leave_types`, and `leave_balances` already existed with mostly the
right shape, but staff had no read access to two of the three tables, and the approval
RPC had an idempotency bug.

**What was already there and already correct**: `leave_requests_select`/`_insert` mirror
the `employee_change_requests` pattern exactly — self-select and self-insert scoped to
`employee_id = my_employee_id()`, with the insert's `with check` also requiring
`status = 'pending' and decided_by is null and decided_at is null`, so an employee can
propose a leave request but never submit or see one already decided. No changes needed
here.

**Gaps found and fixed in this pass**:

- **Staff had zero read access to `leave_types` and `leave_balances`** — both tables only
  had owner/entity_admin/location_manager SELECT policies. A staff member requesting leave
  couldn't see what leave types exist for their entity or their own remaining balance
  before submitting a request. Added `leave_types_select_self` (`entity_id = my_entity()`)
  and `leave_balances_select_self` (`employee_id = my_employee_id()`).
- **`approve_leave_request()` had no idempotency check** — it decided a request and (on
  approve) decremented the balance regardless of the request's current `status`. A
  duplicate RPC call (double-click, retry, or a second admin racing the first) on an
  already-approved request would decrement the balance again for the same days. Fixed by
  adding a `status <> 'pending'` guard that raises before touching either table, so a
  request can only ever be decided once.

Both fixes were verified against the live database in rolled-back transactions: staff can
see their own entity's leave types and their own balance but not a peer's balance or
another entity's leave type or leave request (8 checks), the pre-existing self-insert/
predecided-insert-blocked/peer-visibility/admin-decide flow still works end-to-end and
correctly decrements the balance on approval (4 checks), and the idempotency fix blocks a
second `approve` call on an already-decided request while leaving the balance unchanged
(3 checks) — 15/15 passed.

**Update (later pass): balance sufficiency check.** `approve_leave_request()` originally
decremented `leave_balances.balance_days` on approval with no check that the balance was
actually sufficient, so an approval could drive it negative with no warning — flagged as
a known limitation above, now fixed. The RPC looks up the employee's current balance for
that leave type (treating a missing `leave_balances` row as 0, same as the frontend
already does) and raises a clear error — `Insufficient balance: employee has X day(s) but
the request is for Y day(s)` — instead of decrementing past zero. Rejecting a request is
unaffected by balance either way. The Leave admin queue (`Leave.tsx`) now also fetches
`leave_balances` alongside the pending requests and shows each request's remaining
balance inline, flagging insufficient ones in red before the admin clicks Approve, so the
RPC's error is a backstop rather than the first time anyone finds out. Verified live in a
rolled-back transaction: an over-balance approval is rejected and leaves both the request
status and the balance untouched; a within-balance approval still succeeds and
decrements correctly; a request that becomes over-balance after a partial draw-down is
still correctly blocked; reject is unaffected — 7/7 checks passed.

**Update (Phase 1.3): leave audit integration.** Every `leave_requests` write now produces
an `audit_log` row, populated the same way as Phase 1.2's other writers — `entity_id` /
`location_id` / `employee_id` derived directly from the affected record (via the
employee's own `entity_id`/`home_location_id`), never trusted from the client:

- `leave_request_submitted` / `leave_request_updated` / `leave_request_deleted` — an
  `AFTER INSERT OR UPDATE OR DELETE` trigger (`log_leave_request_changes()`) on
  `leave_requests` covers every write path, including
  the employee's own direct self-insert (no RPC exists for submission — it's a plain
  RLS-scoped insert) and the existing owner/entity_admin/location_manager hard-delete
  path. Auditing the delete wasn't explicitly requested but was an obvious gap otherwise:
  without it, deleting a leave request would erase all history of it ever existing.
- `leave_approved` / `leave_rejected` / `leave_balance_used` — `approve_leave_request()`
  now logs its own richer, purpose-built events instead of relying on the generic trigger
  (the trigger explicitly skips a pending→approved/rejected transition made through this
  RPC, so the decision isn't logged twice under two different names).
- `leave_balance_override_approved` — a **new capability**: `approve_leave_request()`
  gained two optional parameters, `p_override boolean` and `p_override_reason text`. When
  an approval would otherwise be blocked by insufficient balance, an owner or entity_admin
  (not location_manager) can approve anyway by supplying a non-empty reason; the override
  is independently authorization-checked inside the RPC (not just hidden in the UI) and
  produces its own audit event alongside the normal `leave_approved`/`leave_balance_used`
  pair. The Leave admin queue (`Leave.tsx`) surfaces this as an "Override & approve…"
  control, visible only to owner/entity_admin, only on an insufficient-balance request.
- **Safe by design**: the audit payload for every leave event includes only structural
  fields (`status`, `leave_type_id`, dates, `days_requested`, balance numbers, and the
  acting role) — the free-text `reason` (employee's stated reason for the request) and
  `manager_notes` fields are deliberately never copied into `audit_log`, since they can
  contain personal/health context and the spec explicitly calls for keeping confidential
  supporting content out of audit details.
- The location_manager and employee curated whitelists in `get_audit_log()` (see Reports
  & audit above) were extended with the new leave actions: location_manager sees
  submitted/updated/approved/rejected/balance-used events for their own location (they
  already have decision authority there); employees see their own
  submitted/approved/rejected/balance-used history, but not override events, matching the
  "approved own-history" tier the spec calls for.

Verified live (13 checks): submission is audited with all three scope columns populated
correctly; the free-text `reason` never appears in the audit payload; approval logs both
`leave_approved` and a correctly-valued `leave_balance_used` (before/after balance) with no
duplicate generic update row; rejection logs `leave_rejected`; an insufficient-balance
approval is blocked without override, blocked again if an override is attempted without a
reason, and succeeds with both events logged when a reason is supplied; a location_manager
cannot use the override (entity_admin/owner-only, enforced in the RPC); the requesting
employee sees their own approved/rejected/balance-used events but not the override event;
and deleting a request is audited.

**Deferred to Phase 2.9** (not yet built, and explicitly scoped there): `leave_cancelled`,
`leave_balance_reserved`, `leave_balance_released`, and `leave_accrual_applied`. These
describe actions/mechanics — self-cancel, a true balance-reservation model, an accrual
engine — that don't exist in the schema today. Building the audit event ahead of the
feature would mean inventing placeholder semantics Phase 2.9 would likely have to
redesign anyway; those events will be added as part of building the actual features, the
same way every other module's audit events were added alongside their RPCs.

**Known limitations**:

- No self-service cancel for a still-pending leave request yet — that's Phase 2.9.
- No accrual job yet — `leave_types.accrual_days_per_year` is stored but nothing applies
  it to `leave_balances` on a schedule — that's also Phase 2.9, explicitly gated behind an
  approved accrual policy (start date, frequency, rounding, caps, carry-forward,
  probation rules) before it's ever activated.

### Reports & audit

Built as two independent pieces: cross-module summary metrics (no schema changes,
reuses each table's existing RLS scope) and an audit log viewer, which needed a real
fix once actually built against what a signed-in `entity_admin` could do.

**Summary metrics**: active employee count, open requisitions, documents pending
review, leave requests pending, open shifts, swaps awaiting approval, and (owner/
entity_admin only) payroll runs still in draft/in_review — each is a `count`-only query
scoped to the active entity, filtered exactly the way the corresponding admin screen
already filters it (`entity_id = activeEntityId`, or a join to the owning `employees`/
`shifts` row for tables that don't carry `entity_id` directly). This page grants no new
read access; it just counts what the signed-in role could already see one table at a
time.

**The audit log gap**: `audit_log` has no `entity_id` column at all — every row just has
`table_name` + `record_id`, and the only RLS policy on it (`audit_select`) checked
`my_role() = ANY (ARRAY['owner', 'entity_admin'])` with **no entity match at all**. That
meant any `entity_admin`, from any entity, could read every other entity's audit trail —
document approvals, offer decisions, payroll calculations, everything — through a plain
`select * from audit_log`. This is a real cross-tenant leak, not a hypothetical one, and
it predates this pass; it just had no UI reading the table yet to surface it.

**Fix (initial pass)**: tightened the direct-table policy to owner-only, and added
`get_audit_log()` — a `SECURITY DEFINER` RPC — that resolved each row's owning entity via
a hand-maintained join chain mirroring the joins the writing RPCs used to produce that row
in the first place. This closed the immediate leak but left a maintenance trap: every new
audited table needed a matching `left join` added to the resolver, or its rows would
silently never appear for entity_admin.

**Fix (Phase 1.2 — direct scope columns, join list removed):** `audit_log` now carries
three columns populated directly by the writing function at insert time, derived from the
affected database record — never trusted from a client-supplied value:

- `entity_id` — mandatory for every entity-owned record. Enforced by
  `audit_log_entity_id_required_check`, a CHECK constraint (`entity_id is not null or
  table_name = 'app_settings'`) — `app_settings` is the one genuinely global,
  non-entity-scoped table in the schema, and is the only permitted exception.
- `location_id` — populated wherever the writing function already knows the relevant
  location (shifts, swaps, interviews via the requisition's location, documents/timesheets
  via the employee's home location, tips pools directly).
- `employee_id` — populated wherever the row is about a specific employee (document
  events, shift/swap events, timesheet/deduction events, the `employees` change trigger
  itself). Left `null` for candidate/interview/offer events, which concern a candidate,
  not yet an employee.

Every function that writes to `audit_log` (~28 of them, spanning documents, shifts/swaps,
interviews/feedback/offers, payroll) was updated to populate these columns from data it
already had on hand for its own authorization checks — no new joins were introduced at
write time, since each function already knew the entity/location/employee of the record
it was acting on. All ~1,400 historical rows were backfilled in one pass using the same
resolution paths the old join-based resolver used, applied once directly to the table
instead of on every read; zero rows were left unresolvable.

`get_audit_log()` was rewritten to a genuine **four-tier visibility model**, filtering
directly on these columns (no joins at all now):

- **Owner** — every row.
- **Entity Admin** — `entity_id = my_entity()`.
- **Location Manager** — `location_id = my_location()` **and** the action is on a curated
  "operational events" whitelist (shift claimed, swap requested/claimed/cancelled,
  interview cancelled/rescheduled, document uploaded/approved/rejected/archived, payroll
  timesheet/tips changes). This is a **new capability** — previously this role got an
  empty result unconditionally. Security-exception rows (`unauthorized_access_attempt`)
  and payroll deduction rows are deliberately excluded from this whitelist.
- **Employee (staff)** — `employee_id = my_employee_id()` **and** the action is on a
  curated "approved own-history" whitelist (their own document uploads/reviews and
  document previews/downloads, their own shift/swap activity). Also a **new capability**.
  Deliberately excludes security-exception rows and anything payroll/compensation-related,
  per "never expose salary/bank" from the original access-control requirements.

Both curated whitelists live as literal arrays inside `get_audit_log()` — intentionally
conservative starting points, expected to grow as later phases (notably Phase 1.3's leave
audit events) add new action types that belong in one or both lists.

Verified against the live database in rolled-back transactions: a swap-request write
correctly populates all three scope columns; an entity_admin sees it, a different entity's
admin doesn't; a location_manager in the *same* location sees it (new), a location_manager
in a *different* location within the *same* entity does not; the requesting employee sees
their own event (new), a different employee at the same location does not; the owner sees
it regardless. A direct INSERT into `audit_log` missing `entity_id` for an entity-owned
table is rejected by the CHECK constraint at write time — fail-closed is now enforced by
the schema itself, not just by read-time filtering. The `app_settings` exception (global,
non-entity-scoped settings changes) still works. Security-exception rows
(`unauthorized_access_attempt`) are confirmed invisible to both location_manager and
employee tiers while remaining visible to owner/entity_admin.

**Newly-discovered, pre-existing limitation (not introduced by this change):**
`log_document_access()` and `log_candidate_file_access()` both log an
`unauthorized_access_attempt` row and then `raise exception` in the same statement, on the
same unauthorized-attempt code path. Per the same transactional reasoning documented under
Payroll above, a raised exception rolls back everything done in that transaction —
including the audit row logged immediately before it — so **that specific log-then-raise
row can never actually persist** in current production usage (confirmed live: an
unauthorized `log_document_access` call correctly raises and blocks the read, but leaves
no `audit_log` row behind). This predates Phase 1.2 and is unrelated to the entity_id
work; it was found while writing this phase's negative-path tests. The payroll module's
fix for the equivalent problem (return `{ok:false, code, message}` instead of raising) is
the established pattern for a fix, but applying it here changes the calling contract for
`Documents.tsx` and `MyInterviews.tsx` and was intentionally left out of this pass's scope
— flagged here as a known gap for a future, explicitly-scoped fix.

**Known limitations:**

- Pagination is a simple `changed_at` cursor ("Load more"), not a full date-range/actor/
  module/branch filter with export — that's Phase 3.13, explicitly scoped to start only
  after this direct-`entity_id` migration (this one).
- The location_manager/employee curated whitelists are a deliberate starting point, not
  meant to be exhaustive — expect them to grow as more modules formalize what "their own
  operational history" should include.

### Employee profile

The last remaining `ComingSoon` route (`/employees/:id`, linked from every row in the
People directory). Built entirely against existing tables/RLS/RPCs — no schema changes;
this audit confirmed the existing policies were already correctly scoped rather than
finding a gap.

- **View**: full employee record (contact, employment, emergency contact, nationality),
  document expiry glance, the employee's current (`is_current = true`) documents with
  review status, and their 10 most recent leave requests — all filtered by
  `employee_id = :id`, with `employees_select` RLS deciding whether that id resolves to
  anything at all for the caller (owner: any; entity_admin: own entity; location_manager:
  own location; a mismatched id returns the same "not found" empty state as a
  nonexistent one, so the screen never confirms whether an out-of-scope id exists).
- **Change request decisions**: pending `employee_change_requests` for this employee
  render inline with Approve/Reject buttons calling `decide_employee_change_request()` —
  this closes the "no admin-facing approvals list" known limitation called out in the My
  Profile section above. The RPC already had its own idempotency guard
  (`status <> 'pending'` raises) from when it was originally built, verified again here.
- **Compensation & identity documents**: fetched only after an explicit "Reveal" click,
  and the panel itself is only rendered for `owner`/`entity_admin` — `location_manager`
  never sees the button, matching `comp_access`/`identity_documents_access` RLS, which
  has never granted that role anything on either table.

Verified against the live database in a rolled-back transaction: an entity_admin can see
the employee, reveal compensation/identity, and decide (and can't re-decide) a change
request; a location_manager for the *same* location sees the employee but not
compensation/identity; a location_manager for a *different* location can't see the
employee at all; and staff can't see a peer's employee record or compensation — 11/11
checks passed, all confirming existing behavior rather than requiring a fix.

**Known limitation**: shift/schedule history for the employee isn't shown on this page —
only leave and documents. Adding it would mean querying `shifts` filtered by
`employee_id`, which is straightforward to add later but was left out of this pass to
keep the page from ballooning into a fourth "history" section.

### SECURITY DEFINER hardening review (Phase 1.4)

A systematic pass over every `SECURITY DEFINER` function in the schema (60 total —
document/renewal RPCs, shift/swap RPCs, leave decisions, payroll RPCs,
recruiting/interview RPCs, audit access, plus small internal helpers like
`my_role()`/`my_entity()`), checked against 8 criteria: `search_path` pinning,
schema-qualified references, `auth.uid()`-only identity resolution, no trusted client
`employee_id`/`entity_id`/role, explicit role/entity/branch verification, `EXECUTE`
revoked from `PUBLIC`, `EXECUTE` granted only to the roles that actually need it, and
minimal return values — plus negative cross-user/cross-entity tests.

**`search_path` — deliberate project-wide convention, not the literal spec wording.**
Every function in this schema uses `SET search_path TO 'public', 'pg_temp'`, not the
empty string. Rewriting all 60 functions to require full `public.`-qualification
everywhere for an empty search_path would be a large, mechanical, high-risk-of-typo
change across the entire schema. Instead, confirmed directly: `authenticated`, `anon`,
and the `public` pseudo-role all have **no `CREATE` privilege on the `public` schema**
(`has_schema_privilege` checked live) — meaning no signed-in user can plant a same-named
decoy table/function/view in `public` to shadow a real object, and since `public` is
searched *before* `pg_temp` in this exact ordering, a same-named object in a session's own
temp schema can never shadow an existing `public` one either. The specific attack the
empty-string recommendation defends against (a caller placing a malicious same-named
object earlier in the resolution path) is not reachable here. Treated as a reviewed,
equivalent-safety alternative to the literal checklist wording, not an oversight.

**Baseline was already strong.** Every trigger function (`enforce_*`, `log_*`, `seed_*`,
`prevent_payroll_run_status_regression`, `handle_new_user`) already had `EXECUTE` revoked
from both `anon` and `authenticated` — correct, since a trigger fires regardless of
whether the invoking role holds `EXECUTE` on the trigger function itself, so leaving it
un-revoked only adds unnecessary direct-RPC attack surface with zero functional benefit.
Every RPC meant to be called from the client had `EXECUTE` granted to `authenticated` only,
never `anon`, confirmed by a fresh `has_function_privilege('anon', ..., 'EXECUTE')` sweep
across all 60 functions returning zero rows.

**Four functions tightened this pass** — all were internal helpers, never called directly
from the frontend (verified by enumerating every `supabase.rpc()` call site in `src/` and
cross-checking), but were still directly callable by any signed-in user via PostgREST
since every `public` function is auto-exposed as `/rest/v1/rpc/<name>` regardless of
intent:

- **`interview_feedback_status_for(p_interview_id)`** returned a feedback status for *any*
  interview id, entity or not — no ownership check at all. Now only returns a value when
  the calling session is that interview's own interviewer; anyone else gets `null`,
  matching the "no access" shape used everywhere else in this schema.
- **`requisition_entity_for_interview(p_interview_id)`** had the identical gap for the
  interview's owning `entity_id`. Fixed the same way.
- **`renewal_supersedes_owned_by(p_supersedes_document_id, p_employee_id)`** trusted a
  client-supplied `p_employee_id` as the identity to check ownership against, instead of
  deriving it from `auth.uid()` — its one real caller (`employee_documents`'s insert RLS
  policy) always passed `my_employee_id()` anyway, so the parameter existed purely as
  attack surface. The parameter is gone; it derives `my_employee_id()` internally now.
- **`can_review_document(p_submitted_by, p_reviewed_by, p_doc_type)`** trusted a
  client-supplied `p_reviewed_by` — a direct call could simulate "would user X's review
  authority apply here" for an arbitrary `p_reviewed_by`/`p_submitted_by` pair. Now returns
  `false` outright unless `p_reviewed_by` matches `auth.uid()` (its two real callers,
  `approve_document`/`reject_document`, already always passed `auth.uid()`, so this is a
  no-op for legitimate use and closes the direct-call path).

Verified live: a non-interviewer gets `null` from both interview helpers where the real
interviewer gets the correct value; a non-owning employee gets `false` from the renewal
ownership check where the real owner gets `true` (and the renewal flow still works
end-to-end for the real owner); a spoofed-reviewer call to `can_review_document` returns
`false`. Spot-checked two previously-unreviewed RPCs while at it: a cross-entity
`entity_admin` cannot approve a shift swap or decide an employee change request outside
their own entity (both already correctly scoped, no change needed).

**Return values**: reviewed every RPC's return shape — payroll RPCs return
`{ok, code, message, request_id, id}` (no compensation data), document/leave/shift RPCs
return `void` or a bare new id, `get_interview_detail`/`get_my_interviews` return
already-curated projections (not raw table rows), `get_audit_log` returns exactly the
columns needed for the viewer. No function was found returning more than its caller
needs.

### Notifications (Phase 2.5)

A single shared model — `public.notifications` — now backs every "you should know
about this" moment in the app, replacing what would otherwise be five separate,
module-specific ad-hoc mechanisms.

**Schema.** Each row is entity-scoped and addressed to a recipient by *either*
`recipient_user_id` (an `auth.users` id — used for role-based fan-out, e.g. "every
location_manager at this branch") *or* `employee_id` (used when the recipient is a
specific employee regardless of whether/how they sign in) — a check constraint
requires at least one. `notification_type`, `title`, `message`, an optional
`target_type`/`target_id` pointer back to the source row, `priority`
(`low`/`normal`/`high`), `read_at`, and `resolved_at` round out the row.
`dedupe_key` plus a partial unique index (`(entity_id, dedupe_key) where dedupe_key
is not null`) makes re-running the same business event (e.g. re-approving something
already approved) a no-op rather than a duplicate notification.

**Writer.** There is exactly one insertion path: the internal
`create_notification()` function (`EXECUTE` revoked from `anon`, `authenticated`,
and `PUBLIC` — it is never called directly from the client, only from other
`SECURITY DEFINER` functions and triggers). `public.notifications` itself has no
`INSERT`/`DELETE` policy for `authenticated` at all — the only way a row can exist
is through this one function, which every business-event RPC/trigger below calls
after it has already done its authorization check and its own `audit_log` insert.
This mirrors the payroll rejection pattern from Phase 1.1: the notification is a
side effect of an already-authorized, already-audited write, never a standalone
privileged action.

**Read/ack surface — four RPCs, no direct table writes from the client:**
`get_my_notifications(p_limit, p_before, p_unread_only)` (a curated projection, cursor-paginated on `created_at`),
`unread_notification_count()`, `mark_notification_read(p_notification_id)` (returns
`{ok:false, code:'NOT_FOUND_OR_ALREADY_READ'}` rather than raising if the id doesn't
belong to the caller or is already read — same non-raising rejection idiom used
throughout this schema), and `mark_all_notifications_read()`. RLS on the table
itself (`notifications_select` / `notifications_update_self`) independently
restricts every one of these to rows where `recipient_user_id = auth.uid()` or
`employee_id = my_employee_id()`, or to `owner`/`entity_admin`-in-own-entity — so
even if an RPC had a bug, the underlying row-level policy is the real backstop.

**What's wired up this pass** (each notifies the affected party, not the actor):

- **Documents** — `approve_document` / `reject_document` notify the document's
  employee.
- **Leave** — submitting a request (via the `log_leave_request_changes` trigger)
  fans out to every `location_manager` at the employee's home location;
  `approve_leave_request` notifies the employee on both the approve and reject
  branch.
- **Shift swaps** — `request_shift_swap` fans out to the shift's location managers;
  `claim_shift_swap` notifies the original requester; `cancel_shift_swap_request`
  notifies the claimant (if any); `approve_shift_swap` notifies both requester and
  claimant on approval, and the requester on rejection.
- **Payroll** — `run_payroll_calculation` notifies every employee who received a
  payslip in that run. The message deliberately contains **only the pay period
  dates** ("Your payslip for 2026-08-01 to 2026-08-14 is ready to view.") — never
  an amount, a currency figure, or anything else that would leak compensation data
  through a notification, which is a lower-security-tier surface than the Payroll
  screen itself. Verified live: the notification row for an uninvolved employee
  (no payslip in that run) does not exist at all.
- **Interviews** — a new `notify_new_interview()` `AFTER INSERT` trigger notifies
  the assigned interviewer when an interview is scheduled directly (skipped when
  `rescheduled_from_interview_id is not null`, so a reschedule doesn't double-fire
  both this trigger's generic message and `reschedule_interview`'s own richer one);
  `cancel_interview` notifies the interviewer (unless the interviewer is the one
  cancelling); `reschedule_interview` notifies the (possibly new) interviewer of
  the replacement interview.

**Deliberately not wired up yet**: schedule-template publish events and
attendance/clock-in exceptions are named in the original notifications spec but
depend on Phase 2.6 (Recurring schedule templates) and Phase 2.7
(Clock-in/attendance), neither of which exists yet as of this pass. Wiring those
in now would mean notifying on tables/events that don't exist. Revisit once those
phases land.

**Frontend**: a bell icon in the app header (`NotificationBell.tsx`, all roles)
polls `unread_notification_count()` every 30s, opens a dropdown that loads the
most recent 20 via `get_my_notifications()`, marks an item read on click (routing
to a best-effort destination screen based on `target_type` — purely a navigation
convenience, not an access-control decision, since the destination screen
re-derives what it's allowed to show via its own RLS-scoped query regardless), and
has a "Mark all read" action.

**Verified live** (rolled-back transaction, synthetic `_Notif*`-prefixed fixtures):
document approval notifies only the submitting employee, not an uninvolved one;
leave submission reaches the location_manager and the decision reaches the
employee; the full swap fan-out (request → location_manager, claim → requester,
approval → both parties) fires correctly; payroll notifies exactly the paid
employee with a message containing only dates, never a figure, and does not
notify an employee outside that run; a newly scheduled interview and its
cancellation both reach the interviewer; `mark_all_notifications_read()` zeroes
the caller's unread count; and a fresh `anon`-`EXECUTE` sweep across every
`SECURITY DEFINER` function still returns zero rows.

### Recurring schedule templates (Phase 2.6)

Managers can now define a recurring weekly assignment once and generate real shifts
from it for any period, instead of creating every shift by hand.

**Schema — `public.schedule_templates`**: one row per employee/day-of-week/branch
combination — `day_of_week` (Postgres `EXTRACT(dow)` convention: 0=Sunday..6=Saturday),
`start_time`/`end_time`, `break_minutes`, and an `effective_start_date`/
`effective_end_date` window (open-ended if the end date is null). Versioned exactly
like `employee_documents`: there is no in-place edit. `replace_schedule_template()`
deactivates the current row and inserts a new one with `version_number + 1` and
`supersedes_template_id` pointing back, atomically. The table itself has a
`SELECT`-only RLS policy (scoped the same way as `shifts_access`); every write goes
through one of three RPCs so the validation below can never be bypassed by a raw
insert.

**Validation, enforced server-side in `create_schedule_template()` /
`replace_schedule_template()`** — every one of these was verified live to actually
reject the bad case, not just documented as intended: end time must be after start
time; break minutes must be less than the shift's total duration; the employee must
be active and based at the target branch (`home_location_id` match — stricter than
the ad-hoc "New shift" flow elsewhere on this page, which only filters the picker
client-side); and no two active templates for the same employee/day-of-week may
have overlapping effective-date ranges *and* overlapping time windows (checked as a
combined date-range ∩ time-range intersection, not just one or the other).

**Generation and publishing — the Draft → Published lifecycle:**

- `generate_shifts_from_templates(location, period_start, period_end)` walks every
  active template at that branch across the period (day-of-week and effective-date
  matched), skips a template-employee-date combination if that employee already has
  any non-cancelled shift that day (avoids double-booking), and inserts the rest as
  **unpublished** shifts linked back via `generated_from_template_id`. Capped at 62
  days per call. A unique index on `(generated_from_template_id, shift_date)` makes
  re-running the same period **idempotent** — verified live: a second call with the
  same arguments generates zero additional shifts.
- `publish_schedule_period(location, period_start, period_end)` flips
  `is_published` to `true` for every draft shift in that branch/period in one
  statement.
- **Drafts are invisible to employees at the database level, not just hidden in the
  UI** — this needed a real schema change, not a new screen. Shift visibility for
  staff (`shifts_select_self`, `shifts_select_open_home_location`) now additionally
  requires `is_published = true`. Verified live: an employee with a newly generated,
  not-yet-published shift assigned to them sees zero rows for it; after
  `publish_schedule_period()` runs, the same query returns it. `is_published` is
  deliberately a separate column from the existing `status` (`open`/`assigned`/
  `cancelled`) — visibility and staffing are orthogonal, and overloading `status`
  would have collided with the existing `sync_shift_status` trigger that already
  normalizes it on every write. Owner/entity_admin/location_manager keep full
  visibility of drafts via the pre-existing `shifts_access` policy, unchanged —
  they need to see and review a draft before publishing it.

**Frontend**: Schedules → Recurring templates panel (owner/entity_admin/
location_manager only) lists active templates with a "New template" form and a
"Deactivate" action, plus a Generate/Publish control (branch + period, "Generate
drafts" then "Publish period"). The roster table now shows a **Draft** badge next
to a shift's status whenever `is_published` is false, so a manager can tell at a
glance which rows on their own screen aren't visible to staff yet.

**Deliberately out of scope this pass**: editing an unpublished shift generated
from a template (e.g. adjusting one occurrence's time without touching the
template) — for now, cancel the individual draft shift and regenerate, or adjust
after publishing via the same path used for any manually-created shift. Bulk
partial-period publish (publish only some employees/days within a date range,
rather than the whole branch/period) is also not built. Neither was in the Phase
2.6 scope handed down for this pass.

### Clock-in / attendance (Phase 2.7)

A new, deliberately standalone `public.attendance_records` table records actual
time worked, matched to (never merged into) the planned shift — it is read-only
input for a manager to review, not a payroll feed. **Nothing in this phase writes
to `timesheet_entries` or `payslips`** — verified live by snapshotting both
tables' row counts before and after a full clock-in → clock-out → correction
flow and confirming they're unchanged. Payroll entry stays exactly as built in
Phase 1.1 (`record_timesheet_entry`, keyed in by a manager); this phase only adds
the source data a manager would look at while deciding what to key in.

**`clock_in()`** resolves the caller's own employee record, rejects if they
already have an open (not-yet-clocked-out) record — backed by a database unique
index (`employee_id) where clock_out_at is null`, not just an application-level
check — and best-effort matches today's own published, non-cancelled shift
(`shift_id`, nullable). No match is not an error: it's simply surfaced later as a
`no_shift_match` exception. **`clock_out()`** closes the caller's own open record.
Both use `clock_timestamp()`, not `now()`, for the actual instant recorded — `now()`
is frozen to the start of the enclosing transaction, which would be wrong here
specifically (this was caught during live verification: two calls issued together
inside one test transaction got an identical timestamp under `now()` and tripped
the clock-out-after-clock-in check constraint; unrelated to real usage, where each
RPC call is its own transaction, but `clock_timestamp()` is the more correct
choice regardless and has a defensive one-second bump built in as a backstop).

**Manager correction — `correct_attendance_record(record_id, new_clock_in, new_clock_out, reason)`**:
requires a non-empty reason, requires `new_clock_out > new_clock_in` when
provided, and is scoped to owner/entity_admin-own-entity/location_manager-own-
location (verified live: a staff member cannot correct their own record — the
call is rejected, not silently scoped away). The very first original
`clock_in_at`/`clock_out_at` are preserved in `original_clock_in_at`/
`original_clock_out_at` on the *first* correction only (a second correction
updates the current values but never overwrites the true original), and every
correction is audited with old/new values plus the reason and actor role.

**Exceptions feed — `get_attendance_exceptions(location, period_start, period_end)`**,
a curated read-only projection (no side effects) covering three cases, verified
live against synthetic fixtures for each: `missing_clock_out` (a past clock-in
never closed out), `unmatched_shift` (a published, non-cancelled past shift
nobody ever clocked in against), and `no_shift_match` (a clock-in with no
corresponding published shift that day). A manager reviews this list and decides
what to do about each row — correct the record, or leave it and handle payroll
input manually as before.

**Frontend**: an Attendance card at the top of My Schedule (staff) shows current
status and a single Clock in/Clock out button. An Attendance exceptions panel on
the admin Schedules screen (owner/entity_admin/location_manager) lets a manager
pick a branch and period, load the exception list, and correct an individual
record inline with a required reason.

### Shift cancellation auto-closes swaps (Phase 2.8)

Cancelling a shift used to leave any swap request against it dangling — the swap
would still show as `open` or `claimed` even though the shift it referred to no
longer existed. A new `AFTER UPDATE` trigger on `shifts`,
`close_swaps_on_shift_cancellation()`, now fires whenever a shift's `status`
transitions *into* `cancelled` (and only on that transition, not on every
update) and, for every swap request on that shift still `open` or `claimed`:
marks it `cancelled`, writes a `swap_auto_closed_shift_cancelled` audit row, and
notifies the requester (always) and the claimant (if the swap had been claimed).
History is retained — the row isn't deleted, it moves to the same terminal
`cancelled` status a requester's own self-cancellation already uses.

This is a trigger rather than something added to a "cancel shift" RPC because
**there is no dedicated cancel-shift RPC** — a manager cancels a shift today via
a plain `shifts_access`-scoped `.update({status:'cancelled'})` from the
Schedules screen. A trigger is the only mechanism that catches this regardless
of call path, the same reasoning already applied to
`enforce_payroll_child_immutability` and `sync_shift_status`. Future
claim/request attempts against the now-cancelled shift were already rejected by
existing checks in `request_shift_swap`/`claim_shift_swap` (both already refuse
a `cancelled` shift) — re-verified live rather than assumed, since this phase
depended on that pre-existing behavior still holding.

**Verified live**: a claimed swap auto-closes the moment its shift is cancelled;
the closure is audited; both the requester and claimant are notified; a further
claim attempt on the now-closed swap is rejected; and the anon-`EXECUTE` sweep
across every `SECURITY DEFINER` function still returns zero rows. No frontend
change was needed — the existing "Cancel" button on the admin Schedules screen
already goes through the code path this trigger backstops.

### Leave self-cancel + accrual engine (Phase 2.9)

This phase implements the `leave_cancelled` / `leave_balance_reserved` /
`leave_balance_released` / `leave_accrual_applied` audit event types that
Phase 1.3 named but deliberately deferred — doing so properly required
introducing a real reserve-at-submission model that didn't exist before.

**Reservation model.** Previously a leave balance was only ever touched at
approval time, meaning a still-Pending request held no actual claim on the
balance — two simultaneous pending requests could together exceed an
employee's remaining days with nothing flagged until whichever was decided
second. Submission now attempts to reserve the balance immediately
(`log_leave_request_changes()`'s `INSERT` branch): if there's enough balance,
it's deducted right away, the request is flagged `balance_reserved`, and a
`leave_balance_reserved` audit row is written. If there isn't enough, the
request still submits (unchanged UX — the existing insufficient-balance/
override check at approval still applies), it's just left unreserved.
Approval of a reserved request does **not** deduct again — it only flips the
status, since the days were already held (verified live: no duplicate
`leave_balance_used` event fires for a reserved-and-approved request).
Rejecting or self-cancelling a reserved request releases it back
(`leave_balance_released`) exactly once.

**Self-cancel — `cancel_leave_request(request_id, reason)`**: an employee can
cancel their own still-`pending` request (not an approved or rejected one —
those are terminal). It's **idempotent**: calling it again on an
already-cancelled request returns `{ok:true, already_cancelled:true}` instead
of re-processing, so a duplicate/retried client call can never release the
same balance twice — verified live by calling it twice in a row and
confirming the balance moves exactly once. Every location_manager at the
employee's location is notified, mirroring the submission fan-out.

**Accrual engine — configure, approve, then run; never automatic.**
`leave_accrual_policies` holds one row per leave type: frequency
(monthly/annual), days per period, rounding (none / nearest half day /
nearest day), an optional balance cap, an optional carry-forward cap (applied
only at an annual accrual, to the pre-accrual balance, before that period's
days are added), and a probation window (an employee isn't credited until
`join_date + probation_days` has passed). **Configuring a policy never
activates it** — `configure_leave_accrual_policy()` always resets
`is_approved` to `false`, including on every edit to an already-approved
policy (verified live: editing an approved policy immediately re-blocks it).
A separate, **Owner-only** `approve_leave_accrual_policy()` — a deliberately
higher bar than the entity_admin who can configure — is required before
anything can run; `run_leave_accrual()` hard-raises if the policy isn't
approved, regardless of who calls it. There is no scheduler or cron anywhere
in this stack — running accrual for a period is always a deliberate,
explicit action (owner/entity_admin), exactly like `run_payroll_calculation`.
Idempotency is a database-level unique constraint
(`leave_accrual_runs(employee_id, leave_type_id, period_key)`), not an
application check — verified live by running the same period key twice and
confirming zero additional employees are credited the second time.

**Frontend**: My Leave now has a Cancel action on each of the employee's own
pending requests. The admin Leave screen (owner/entity_admin only — this
matches `leave_accrual_policies`' RLS scope, which deliberately excludes
location_manager) gets a "Leave accrual policies" panel: configure a policy,
approve it (Owner only), and run it for a period key, with a running/awaiting-
approval status badge per policy.

### Document upload staging/retention (Phase 2.10)

**The bug this fixes.** Previously the client uploaded bytes to a path it
chose itself (embedding the original file name) and only afterwards called
an RPC to create the database row. If the browser crashed or the network
dropped between those two steps, the result was a file sitting in storage
with **no database row pointing to it at all** — invisible, unlisted, and
much harder to find than a stray row would have been. This phase reverses
the order.

**Stage, upload, confirm.** `stage_document_upload()` (manager/owner
uploading on an employee's behalf) and `stage_document_renewal()` (an
employee renewing their own current document) now run first: they do the
exact same authorization checks as before, but instead of accepting a
client-supplied path, they mint the document's id server-side and derive the
storage path from it —
`{entity_id}/{employee_id}/{document_id}/{version}/{document_id}.{ext}` — so
**the original file name never appears in the storage key at all**, and the
row is inserted immediately with `upload_confirmed = false`. Only then does
the client upload bytes to that exact returned path. `confirm_document_upload()`
independently checks `storage.objects` for that exact path — it does not
trust the client's claim that the upload succeeded — and only then flips
`upload_confirmed` to `true` (and, for an owner upload or a self-approving
entity_admin's non-sensitive upload, immediately approves it, exactly
preserving the pre-existing auto-approval behaviour, just moved to after the
file is confirmed to exist rather than before). Verified live: confirming
before the object exists returns `{ok:false, code:'UPLOAD_NOT_FOUND'}` rather
than silently succeeding; confirming again after it's already confirmed is a
no-op; `approve_document`/`reject_document` both hard-raise if
`upload_confirmed` is still `false`, a backstop against a direct RPC call
bypassing the normal review-queue flow (which only ever lists confirmed
documents).

**File type is validated server-side too** — only `pdf`, `jpg`, `jpeg`, `png`
are accepted; anything else is rejected before a row is even created.

**Cleanup — `cleanup_incomplete_document_uploads(older_than_hours)`**
(owner/entity_admin), removes `employee_documents` rows that were staged but
never confirmed past the given age. **Known limitation, discovered live, not
assumed:** `storage.objects` has its own `protect_delete()` trigger that
rejects direct SQL `DELETE`s outright ("Use the Storage API instead") — so
cleanup can only remove the orphaned database row. In the rare case where the
file actually was uploaded but `confirm_document_upload` was never called
(e.g. the tab closed in between), the physical bytes remain in storage and
need a separate Storage-API-driven sweep using the service role, which is
outside what a Postgres migration can do. This is a real, documented gap, not
a silently-assumed non-issue.

**Location Manager visibility for sensitive documents.** Previously a
location_manager saw **nothing at all** for a restricted doc type (passport,
Emirates ID, visa, contract, offer letter, bank/compensation documents) — not
even the expiry date, because `documents_select` excluded the whole row.
That's stricter than the spec calls for: a manager should be able to track
expiry without ever seeing the file. Row-level security can only include or
exclude an entire row, not redact individual columns, so this is a new
curated projection, `get_documents_for_review(entity_id)` — the same pattern
as `get_audit_log`/`get_my_notifications` — that a location_manager's
Documents screen now calls instead of a raw table select. For a sensitive
doc_type it returns `storage_path` and `notes` as `null` but leaves doc type,
expiry date, review status, version, and submission/review timestamps
intact; for a non-sensitive type it's unredacted. This is defense in depth,
not the only layer: even if a client somehow obtained the real path, the
pre-existing `doc_bucket_read` storage policy independently refuses to let a
location_manager read a restricted-type file regardless. Owner/entity_admin
continue to use the original raw table select — unredacted, unchanged.
Verified live: a location_manager's projection of a passport document comes
back with `storage_path`/`notes` null but the correct `expiry_date`; the same
call against a non-sensitive document type returns the real path.

**Archived document retention** is unchanged from before this phase —
`archive_document()` already soft-retires a document (stops it showing as
current) without deleting it, and there is still no purge process; archived
documents are retained until an Owner-approved purge process exists, which
remains out of scope.

### Interview feedback reveal gating (Phase 3.12)

Before this phase, `interview_feedback_admin_all` gave owner, entity_admin,
*and* location_manager the exact same unconditional, ungated read (and write)
access to every interview's feedback the instant it was saved as a draft —
confirmed live in the Recruiting screen, which did a raw
`interviews.select('*, interview_feedback(*)')` with no filtering at all.
Any location_manager viewing a candidate's pipeline saw every interviewer's
in-progress recommendation, ratings, strengths/concerns/notes immediately,
regardless of whether anyone else had submitted yet. That's fixed now.

**The model.** A "round" is every non-cancelled interview sharing the same
`(application_id, stage_id)` — i.e. everyone scheduled for a given candidate
at a given stage. Feedback content stays private to its author and to
Recruiting Admin/Owner (`owner`/`entity_admin` — the same roles
`reopen_interview_feedback()` already treated as "Recruiting Admin or Owner")
until either:

- every required interviewer in the round has **submitted** their feedback
  (computed live — no storage needed), or
- a Recruiting Admin/Owner explicitly **closes the round** via the new
  `close_interview_round(application_id, stage_id, reason)` RPC, for the case
  where a panelist never will submit (left the company, forgot, etc.). This
  is recorded in a new `interview_round_closures` table with the closer,
  timestamp, and required reason — audited, and **idempotent** (closing an
  already-closed round just returns `already_closed: true`, no error).

Once a round is revealed, only rows that are themselves `status = 'submitted'`
are shown — a reopened row (via the existing `reopen_interview_feedback()`)
drops back out of view immediately, matching "after reveal show only
submitted feedback." Naturally-revealed rounds (the all-submitted path, no
explicit closure) are **not sticky**: reopening any one submission pulls the
whole round back to hidden for location_manager until it's resubmitted or a
Recruiting Admin closes the round. An explicit `close_interview_round()` call
*is* sticky by design — it's a deliberate admin decision, not a side effect of
submission counts, so it doesn't silently reverse itself.

**Enforcement is two layers, not just the RPC.** `interview_feedback_admin_all`
was split: owner/entity_admin keep unconditional `ALL` access (they're exempt
from gating by design); location_manager lost that blanket policy entirely
and got a new SELECT-only, reveal-gated one
(`interview_feedback_location_manager_revealed_select`) that only matches rows
where `status = 'submitted'` *and* `is_interview_round_revealed(application_id,
stage_id)` is true. This means the gating holds even against a raw
`supabase.from('interview_feedback').select()` from the browser console, not
just through the curated read path. The author's own row
(`interview_feedback_interviewer_select`) is unaffected — an interviewer can
always see their own feedback regardless of reveal state.

**The curated read path.** The Recruiting screen no longer embeds
`interview_feedback` on its interviews query at all. It calls the new
`get_application_interview_feedback(application_id)` RPC instead, which
returns one row per interview with a `feedback_visible` boolean and every
content field (`recommendation`, `competency_ratings`, `strengths`,
`concerns`, `notes`, `status`, `submitted_at`, `reopened_at`, `reopen_reason`)
null'd out server-side whenever `feedback_visible` is false — the client is
never sent the hidden content to redact client-side. The same call also
returns round metadata (`round_required_count`, `round_submitted_count`,
`round_revealed`, `round_closed`, `round_closed_by_name`) so the UI can show
"2 of 3 interviewers submitted" and a "Close round" button (owner/entity_admin
only, and only while the round isn't yet revealed) without a second query.
Interviews in the Recruiting screen are now grouped by stage/round instead of
shown as one flat list, so this status sits once per round rather than being
repeated or lost.

Verified live (20 checks, rolled back): a location_manager sees zero visible
rows and null content pre-submission and mid-submission (even for a specific
interview whose own feedback is already submitted, if its round isn't fully
revealed yet); content appears the moment the last required interviewer
submits; a direct raw-table select is blocked identically to the curated RPC
at every stage; `close_interview_round` is owner/entity_admin-only, rejects an
empty reason, rejects a stage that doesn't belong to the application's
requisition, and is idempotent on a second call; a forced-closed round reveals
the submitted interviewer's feedback while still hiding a co-panelist's
never-submitted one; reopening a naturally-revealed (non-sticky) round pulls
it back to hidden for location_manager while the author can still see their
own row; and `anon` has zero EXECUTE on `is_interview_round_revealed`,
`close_interview_round`, and `get_application_interview_feedback`.

### Audit filtering and export (Phase 3.13)

`get_audit_log()` already had role-based scoping (owner/entity_admin/
location_manager/staff, each from Phase 1.2/1.4) and a `changed_at` cursor for
infinite-scroll pagination. This phase adds the rest of the filter set the
spec called for — date range, actor, module, entity, branch, employee — as
new trailing optional parameters, fully backward compatible with the existing
call. None of the four role branches changed their base scoping; the new
filters are additive `and` conditions layered on top of whatever that role
could already see, so passing a foreign entity/location/employee id narrows
to zero rows rather than leaking anything (verified live).

**Module filter.** "Module" groups the `table_name` values actually written
by existing RPCs today (checked live via `pg_get_functiondef`, not guessed)
into the same categories the app already uses elsewhere: Employees,
Documents, Recruiting, Scheduling & attendance, Leave, Payroll, Settings. An
unrecognized module name raises rather than silently matching nothing or
everything. The Reports screen's existing fine-grained table dropdown is
kept alongside it — selecting a module resets the table filter if it no
longer belongs to that module, so the two can't silently combine into an
always-empty result.

**location_manager now sees this screen at all.** Previously Reports.tsx
hard-blocked location_manager with a static "owners and entity admins only"
message, even though `get_audit_log()`'s location_manager branch (curated
operational actions, own location) was already fully built and tested back
in Phase 1.2/1.4 — it just had no UI. That's fixed: location_manager now gets
the same viewer, scoped exactly as the RPC already scoped it, without the
entity/branch pickers or export button (see below).

**CSV export is a separate, more restricted capability from viewing.**
`export_audit_log()` takes the same filters as `get_audit_log()` but no
pagination — capped at 5000 rows — and is owner/entity_admin only; it raises
for location_manager/staff even though they can view a curated slice
on-screen. Bulk extraction of the change history is a heavier action than
paging through it, so it doesn't automatically follow from view access. The
export is itself audited: every call writes its own `audit_log_exported` row
recording who exported, the row count, and the exact filters used — bulk
extraction of the audit trail is part of the audit trail. The frontend builds
the CSV client-side from the returned rows (a plain `Blob` + anchor download,
no library) and shows a "narrow the date range" notice if the row count comes
back at exactly the 5000 cap.

Verified live (20 checks, rolled back): module filtering and the unknown-
module rejection; a date-range `p_after` correctly excluding an
out-of-range row; actor and employee filters matching only their own rows;
a branch filter narrowing to one location; an entity_admin passing a foreign
`entity_id` getting zero rows back with no error; an owner narrowing to
either of two entities via `p_entity_id` returning exactly that entity's
rows; location_manager's curated view still only showing their own
location's allowed-action rows; `export_audit_log` rejecting location_manager
and staff by name; a successful entity_admin export returning exactly their
entity's matching rows and writing exactly one `audit_log_exported` event
with the correct `row_count`; a second export call correctly picking up the
first export's own self-log row in its count (confirming the self-audit
behavior is real, not decorative); an entity_admin's export ignoring a
foreign `p_entity_id` rather than honoring or erroring on it; and `anon`
having zero EXECUTE on both `get_audit_log` and `export_audit_log`.

**Out of scope, noted rather than silently expanded:** some tables are
mutated via direct client-side `.insert()`/`.update()` calls rather than an
audited RPC (e.g. `job_requisitions`, `candidates`, `job_applications`,
`interview_stages`, and requisition/application status changes in
Recruiting.tsx) and so never appear in `audit_log` at all yet — this is a
pre-existing instrumentation gap, not something this phase's filtering/export
work was scoped to fix.

### Employee schedule history on profile (Phase 3.14)

My Profile now has a compact "Schedule history" card showing the employee's
last 10 past shifts (date, time, branch, position, status), plus an "Open
Schedules →" link out to the full Schedules module — done as a real history
section rather than only a link, since My Schedule (the staff personal view
in Schedules.tsx) only ever shows *upcoming* shifts and has no past-shift
view at all today. The query is the same `shifts` table, just the past-dated
complement of what My Schedule's upcoming list already reads.

**A real scoping bug was caught and fixed while building this, not just
guarded against speculatively.** My Profile is reachable by every role, not
only staff — an owner/entity_admin/location_manager also has an employee
record if they're an assigned employee somewhere. `shifts` has two permissive
RLS policies that Postgres combines with OR: `shifts_access` (their whole
entity/location, for owner/entity_admin/location_manager) and
`shifts_select_self` (`employee_id = my_employee_id()`, for anyone). My
Schedule can skip an explicit `employee_id` filter and lean on RLS alone
because it's staff-only, so `shifts_select_self` is the *only* policy ever in
play there. My Profile can't make that assumption — verified live (rolled
back): querying this employee's "own" past shifts without an explicit
`.eq('employee_id', ...)` filter, as a location_manager, actually returned
their whole team's shift history (2 rows, both employees), not just their
own (1 row). The fix was adding that explicit filter, which is genuinely load-
bearing here rather than cosmetic — a distinction called out directly in the
code comment so a future edit doesn't quietly drop it thinking it's
redundant with RLS.

## How access control works here

There is **no client-side role branching for data** beyond which screens/columns render.
Every query runs as the signed-in user against Postgres RLS:

- `owner`: `entity_id` is `null` on their profile → sees every entity (hence the entity switcher).
- `entity_admin` / `location_manager`: scoped to one `entity_id` / `home_location_id` — enforced at the database, not just hidden in the UI.
- `staff`: resolved via `auth_user_id` on `employees`, never a client-supplied employee id.

Salary, bank details and identity numbers live in `employee_compensation` and
`employee_identity_documents`, which have their own owner/entity_admin-only RLS. The
directory and dashboard screens simply never `select` those columns.

## Local setup

```bash
npm install
cp .env.example .env   # already has the TS-HR project URL + anon/publishable key
npm run dev
```

Sign in with an existing TS-HR account (e.g. the owner account, aisha@thirdstate.ae). There's
no self-service sign-up — accounts are provisioned via `profiles` by an owner/admin.

## Build

```bash
npm run build   # tsc -b && vite build -> dist/
npm run preview # serve the production build locally
```

## Deploying to Vercel

1. Push this project to a GitHub repo.
2. In Vercel: **New Project → Import** the repo. Framework preset should auto-detect **Vite**.
3. Build command: `npm run build`. Output directory: `dist`.
4. Add environment variables in the Vercel project settings (same values as `.env.example`):
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
5. Deploy. Because this is a client-side SPA with `react-router-dom`, add a rewrite so deep
   links (e.g. `/employees`) don't 404 on refresh — create `vercel.json` at the project root:

   ```json
   {
     "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }]
   }
   ```

6. In Supabase Auth settings, add the Vercel deployment URL (and any custom domain) to the
   allowed **Site URL** / **Redirect URLs** once you're past plain email/password sign-in.

## Notes / open items carried from the requirements doc

- Every route now has a real screen; see each module's "Known limitations" section above
  for what's intentionally left out rather than missing by omission.
- `employee_compensation` / `employee_identity_documents` should stay behind an explicit
  "reveal" action — never fetched in a list view.

## Final verification pass

A cross-phase sweep after all 14 phases (database integrity/security, core HR MVP, and
controlled enhancements), checking things a single phase's own testing wouldn't catch —
drift *between* phases, not bugs *within* one.

**Project-wide checks (all passed):**

- Every table in `public` has row-level security enabled — no exceptions.
- Every `SECURITY DEFINER` function has `search_path` pinned to `'public', 'pg_temp'` — no
  exceptions, so none of them can be tricked by a caller-controlled search path.
- `dblink`, `postgres_fdw`, and `pg_net` are not installed, and no role name resembling a
  dedicated audit/logging credential exists — the standing "no dblink, no autonomous-
  transaction logging, no dedicated audit-logging role" directive was never violated across
  any phase.
- A full `anon`-EXECUTE sweep across every function in `public` returned only two: a static
  document-type classifier with zero data access (`is_restricted_doc_type`, pure literal
  lookup) and a boolean employee-status check (`is_active_employee`) whose own internal
  query is still independently RLS-gated for `anon` (which has no policy granting it
  visibility into `employees`), so it can't actually be used to probe real data. Both are
  genuinely harmless to leave public rather than something missed.
- The Supabase security advisor (`get_advisors`, type `security`) reports **zero ERROR-level
  findings** project-wide. All 74 `WARN`-level findings are either the same by-design
  "SECURITY DEFINER function is executable by `authenticated`" noise on every client-facing
  RPC (expected — that's the entire point of these RPCs), or the one genuinely actionable
  item below.

**Two real cross-phase regressions were found and fixed, not just guarded against
speculatively:**

1. **Stale action names in `get_audit_log()`'s curated allow-lists** (location_manager/staff
   branches). These lists were written in Phase 1.2/1.4, before Phase 2.9 (leave self-cancel)
   and Phase 2.10 (document upload staging) existed. Phase 2.10 renamed the upload lifecycle's
   action literals (`document_upload_staged` / `document_upload_confirmed` replaced an older
   `document_uploaded`, and `renewal_staged` replaced `renewal_submitted`), and Phase 2.9 added
   a brand-new `leave_cancelled` action — but nobody went back and updated these two arrays.
   The failure mode was **under-visibility, not a leak**: location_manager and staff had been
   seeing zero audit events for uploads/renewals/self-cancellations since those phases shipped,
   silently, because the action-name equality check just never matched anything real. Fixed by
   updating both arrays to the current, verified-live action literals; re-verified live that
   both roles now see the previously-invisible events, and that `anon` still has zero EXECUTE.
2. **`shifts_access` (broad, entity/location-wide) and `shifts_select_self` (own shifts only)
   are two separate permissive RLS policies that Postgres combines with `OR`.** Phase 3.14's
   new "Schedule history" card on My Profile is reachable by every role, not just staff, and
   the first draft of its query relied on RLS alone (matching the existing My Schedule
   pattern) without an explicit `employee_id` filter. Because My Schedule is staff-only,
   `shifts_select_self` is the *only* policy ever in play there — but an owner/entity_admin/
   location_manager viewing their own profile also matches `shifts_access`, so without the
   explicit filter their "own" schedule history silently became their *entire team's* shift
   history. Caught and fixed during Phase 3.14 itself (verified live before it ever shipped,
   not left for this pass) by adding an explicit `.eq('employee_id', ...)` filter — a case
   where the client-side filter is doing real security work, not just presentation, and is
   commented as such so a future edit doesn't assume RLS alone covers it.

**Two specific cross-phase interactions were checked for a side-channel leak and confirmed
safe (no fix needed):**

- Does exporting/viewing the audit log leak private interview feedback content, bypassing
  Phase 3.12's reveal gating? Checked `save_interview_feedback_draft`, `submit_interview_feedback`,
  and `reopen_interview_feedback` directly — none of them write `recommendation`/`competency_ratings`/
  `strengths`/`concerns`/`notes` into `audit_log`'s `old_value`/`new_value`, only `{interview_id}`
  or `{interview_id, reason}`. No leak.
- Does a location_manager learning a restricted document's `storage_path` via the (now-visible)
  `document_upload_confirmed` audit event let them actually read the file, bypassing Phase
  2.10's redaction? Checked the `doc_bucket_read` storage RLS policy directly: it re-derives
  `doc_type` from `employee_documents` on every read attempt and independently rejects
  location_manager for any restricted type, regardless of whether they know the exact path.
  Knowing the path is not a capability — the real check is re-evaluated fresh every time. No
  leak; defense-in-depth holds as designed.

**One piece of hygiene cleanup:** `get_audit_log()` had picked up a second, stale 4-parameter
overload from before Phase 3.13 expanded it to 10 parameters (`CREATE OR REPLACE` creates a
new overload rather than truly replacing one when the parameter *type list* changes length).
Confirmed `anon` EXECUTE was already correctly revoked on it (no security hole), but it was
dead, confusing code since the frontend only ever calls the 10-parameter version by name.
Dropped.

**One item is a genuine remaining risk, not something a database migration can fix:** the
Supabase Auth project setting **"Leaked Password Protection"** (checks new passwords against
HaveIBeenPwned) is currently **disabled** at the project level. This is an Auth configuration
toggle in the Supabase dashboard (Authentication → Policies), not a schema/RLS concern, so it's
outside what this frontend/migration work can change directly — recommended as a pre-launch
action item for whoever owns the Supabase project settings.

**Consolidated known limitations (gathered from each phase's own notes, not new findings):**

- Some tables are still mutated via direct client-side `.insert()`/`.update()` rather than an
  audited RPC (`job_requisitions`, `candidates`, `job_applications`, `interview_stages`, and
  requisition/application stage changes in Recruiting.tsx) and so never appear in `audit_log`
  at all — a pre-existing instrumentation gap, not a security hole (RLS still governs who can
  perform those writes), out of scope for the audit-filtering/export work specifically.
- Archived document retention has no purge process yet; archived documents are kept
  indefinitely pending an Owner-approved purge design.
- `cleanup_incomplete_document_uploads()` can only delete the `employee_documents` row for an
  uploaded-but-never-confirmed file, not the underlying storage object — `storage.protect_delete()`
  rejects direct SQL deletes on `storage.objects` by design. A rare, low-volume Storage-API/
  service-role sweep would be needed to actually reclaim that file, separate from this app.
- Full build/lint/test verification was re-run one final time against the exact code being
  delivered: `tsc -b` (0 errors), `vite build` (clean), `oxlint` (2 pre-existing warnings in
  `AuthContext.tsx`, 0 errors — unchanged from every prior phase), `vitest run`
  (`src/lib/documents.test.ts`, 17/17 passing).
