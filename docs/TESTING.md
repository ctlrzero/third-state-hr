# TS-HR testing guide (UAT)

This guide is for testers and the go-live owner. It covers where to test, who to sign in as,
step-by-step scripts for each role, the automated suites, and the checklist to run before go-live.

> **Test data only.** Use the `uat.*@example.com` logins and the **UAT Entity A** / **UAT Entity B**
> entities. Do not create, edit or delete anything in *Third State Cafe* or *Ateej Tea Brew*, and do
> not sign in with a real staff account for testing.

---

## 1. Environments

| What | Value |
|---|---|
| Supabase project | TS-HR `yclhzwghzrohusqxfasq` (`https://yclhzwghzrohusqxfasq.supabase.co`) |
| Production URL (planned) | `https://hr.thirdstate.ae` (see `DEPLOYMENT.md`) |
| UAT deployment | Vercel Git integration, built from the `uat` branch (an empty "trigger UAT deployment" commit forces a rebuild). Vercel shows the URL under **Project → Deployments**. |
| Branch previews | Vercel builds a preview for every pushed branch at `https://<vercel-project>-git-<branch-slug>-<vercel-team>.vercel.app`, e.g. branch `integration/phase1-completion` becomes `…-git-integration-phase1-completion-….vercel.app`. The exact project/team slugs are only shown in the Vercel dashboard. |
| UAT banner | Set `VITE_APP_ENV=uat` in the UAT/preview deployment's env vars. Leave it unset in production. |

All environments currently use the **same** Supabase project. The UAT data lives in UAT Entity A/B next
to the real entities, and RLS keeps them apart.

## 2. Run locally

```bash
cp .env.example .env    # TS-HR URL + publishable key; optional VITE_APP_ENV=uat for the banner
npm ci
npm run dev             # http://localhost:5173
```

`npm run build` (type-check + production build), `npm run lint`, and `npm test` should all pass before you push.

## 3. UAT personas

Password for every persona: **`TSHR-uat-2026!`**

| Email | Role | Entity | Branch | Linked employee | What to test with it |
|---|---|---|---|---|---|
| `uat.owner@example.com` | owner | all (group-wide) | – | – | Group dashboard across entities, entity switcher, admin (entities, branches, users & access, policies), payroll approval, audit export, workflows in any entity |
| `uat.entityadmin.a@example.com` | entity_admin | UAT Entity A | – | – | Everything admin inside Entity A: payroll, access grants, branches, lifecycle, workflows, schedules, documents review |
| `uat.entityadmin.b@example.com` | entity_admin | UAT Entity B | – | – | Cross-entity isolation: must never see Entity A data |
| `uat.locationmanager.a@example.com` | location_manager | UAT Entity A | UAT Branch A1 | UAT Location Manager A | Branch operations: schedules, attendance exceptions and corrections, leave approval, document review (non-restricted). **No payroll/pay data** |
| `uat.locationmanager.b@example.com` | location_manager | UAT Entity B | UAT Branch B1 | – | Isolation from Entity A |
| `uat.employee.a@example.com` | staff | UAT Entity A | UAT Branch A1 | UAT Employee A | Staff self-service: clock, attendance, leave, documents, payslips, profile change requests, notifications |
| `uat.employee.b@example.com` | staff | UAT Entity A | UAT Branch A2 | UAT Employee B | Second staff member (has an open clock-in from a previous day, which shows as a "missing clock-out" exception) |
| `uat.employee.c@example.com` | staff | UAT Entity B | UAT Branch B1 | UAT Employee C | Staff in Entity B |

Fixture extras: **UAT New Starter** (Entity A, Branch A1, `pre_boarding`, no login) for lifecycle and
access-grant tests; a draft payroll run for September 2026, an approved August run and a paid July run
(plus a draft July revision) in Entity A; a pending leave request for Employee A; one unpublished
shift for Employee A on 2026-10-04.

Refresh date-relative fixtures (shifts, attendance and exceptions move with today's date) from the
Supabase SQL editor, as postgres:

```sql
select public.uat_fixtures_refresh();
```

## 4. UAT scripts by journey

Mark each step pass/fail. "Expect" is what must happen. Business dates are Dubai time.

### 4.1 Sign-in (every persona)
1. Open the app, sign in with the persona. Expect: you land on Home and the nav shows only your role's areas.
2. Enter a wrong password. Expect: "invalid credentials" message, no crash.
3. Staff: open `/payroll` → you see **My payslips**, not the payroll run screen. LM: `/payroll` → an access message.
4. Sign out, then deep-link to `/admin`. Expect: you are sent to sign-in.
5. **Forgot password?** on the sign-in page with a UAT email and with an unknown email. Expect: the same
   message both times ("If an account exists for that email, a reset link is on its way"). The UAT
   inbox receives a link to `/set-password`; set a new password (8+ characters, confirm must match).
   Expect: "Password saved" then Home. Opening the same link again shows "link invalid or expired".

### 4.2 Clock in / out (employee.a)
1. **Clock**. Expect: today's shift (Branch A1, 09:00–17:00) and state "Not started".
2. Tap **Clock in**, then tap it again quickly. Expect: one record only; state "Clocked in"; a late clock-in shows the minutes late.
3. Tap **Clock out** (twice). Expect: one clock-out; state "Clocked out"; today appears in *My attendance* with worked minutes.

### 4.3 Attendance exceptions and correction (locationmanager.a)
1. **Attendance → Exceptions**, Branch A1, last 14 days. Expect: late clock-ins / missing clock-outs for Branch A1 staff only.
2. Open one of Employee A's records → **Correct**: change the clock-in, enter a reason → Save. Expect: record shows *corrected* with the reason; the original time is kept (visible in the record history).
3. Try to save a correction without a reason. Expect: blocked.
4. Try to correct your own record. Expect: refused.
5. **Payable time** view: propose an adjustment with a reason. Then as **entityadmin.a** apply or reject it.

### 4.4 Schedules: generate and publish (locationmanager.a or entityadmin.a)
1. **Schedules → Templates**: create a recurring template for Employee A (for example Mondays 09:00–17:00).
2. **Generate** shifts for next week at Branch A1. Expect: new shifts in *Draft* (not visible to staff).
3. Sign in as employee.a → Schedule. Expect: draft shifts are **not** shown.
4. Back as manager: **Publish** the period (include 2026-10-04). Expect: count published; employee.a now sees them and gets a "schedule published" notification.
5. Staff: request a swap on a published shift; another staff member claims; manager approves.

### 4.5 Leave request and approval
1. employee.a → **Leave → Request leave** (Annual, 2 days). Expect: status *Pending*; the balance shows the days held (reserved).
2. locationmanager.a → **Leave** queue. Approve the request. Expect: *Approved*, balance reduced once (not twice), employee notified.
3. Try the same as employee.a on their own request (should not be possible). Try a request above balance: approval needs an owner/entity admin override with a reason.
4. employee.a cancels a pending request. Expect: the held days are released.

### 4.6 Documents: upload, review, renewal
1. employee.a → **Documents → Upload document** (visa, any small PDF, expiry date). Expect: *Pending review*.
2. locationmanager.a (non-restricted types) or entityadmin.a → review queue → **Approve** (or **Reject** with a required reason). Expect: status updates; the employee is notified.
3. On an approved document close to expiry, employee.a uploads a **renewal**. Expect: new version pending; the old version stays current until the renewal is approved, then it is superseded.
4. Nobody can approve their own document.
5. Fixture visa/labour-card documents are metadata-only placeholders: preview/download shows "file not found". That is expected.

### 4.7 Payroll: draft → review → approve → publish → staff PDF (entityadmin.a, owner)
1. entityadmin.a → **Payroll** → open the September 2026 *Draft* run. Enter timesheet hours, a tips pool, a deduction.
2. **Run calculation**. Expect: payslips for Entity A staff with base/overtime/holiday/tips/deductions/net.
3. Confirm overtime/holiday pay and tip distribution, then **Send to review** → *In review*.
4. **Approve run** (owner, or entity admin when self-approval is enabled). Expect: the run is locked (no edits); payslips are now published.
5. On the run screen, click **PDF** for a payslip. Expect: a PDF with the real position, branch, version and pay basis.
6. employee.a → **Payslips**. Expect: the September payslip appears; open it and download the PDF (same content as the admin PDF). Draft runs never appear.
7. Corrections: on an approved run, **Create revision**. Expect: a new linked draft run; the original stays unchanged.
8. locationmanager.a: no Payroll menu; `/payroll` shows an access message.

### 4.8 Workflows (entityadmin.a or owner)
1. **Workflows → New workflow rule**: module Leave, trigger *leave submitted*, condition `days_requested ≥ 3`, action *notify role: entity admin*, message text.
2. **Test rule** with 5 days (expect *matched*) and with 1 day (expect *skipped*). Testing never creates a real run.
3. **Activate**. Then as employee.a submit a 3-day leave request. Expect: entity admin notified and a run in **Run history**.
4. Deactivate the rule. Owner: create a rule for Entity B (entity must be chosen).

### 4.9 Admin: entities, branches, users and access
1. owner → **Admin → Entities & branches**: edit UAT Entity B (code, emirate); add a branch to UAT Entity A; deactivate it. Expect: a dependency summary before deactivating.
2. entityadmin.a: can add or edit Entity A branches and cannot edit entities.
3. **Users & access → Grant access**: email `uat.tester+1@example.com` (use an inbox you can read), role staff, Entity A, Branch A1, employee UAT New Starter. Expect: "Access granted … Invitation email sent" and the row now shows the login with *Invite not yet accepted*.
4. Open the invite email → `/set-password` → set a password. Expect: you land on the staff Home for UAT New Starter (the grant was applied when the invite created the login). Re-open the link: "link invalid or expired".
5. **Resend invite** on a login that has not signed in yet: Expect "Invitation email sent". Repeat quickly several times: expect the friendly "Too many emails…" message (Supabase rate limit), no crash.
6. Grant access to an email that already has a confirmed login. Expect: "already has a login — access applied".
7. entityadmin.b cannot send an invite for an Entity A grant (403 message). Audit log shows `user_invited` with the grant's entity.
8. **Revoke** a pending grant: a reason is required. Expect: *Revoked*.
9. **Policies**: owner sees retention policies for every entity; entity admin sees only their own. Propose a policy (entity admin) and approve it (owner).
10. **Bulk import**: import 2 rows into Entity A. Expect: per-row success and errors.

### 4.10 Employee lifecycle (entityadmin.a)
1. **People → UAT New Starter** → set status *Active* (pre_boarding → active). Expect: status changes and an audit entry.
2. Edit details (phone, position). Expect: preview, confirm, before/after in history.
3. Completeness bar lists what is missing (contract, Emirates ID…).
4. Inactivate with a reason. Expect: login deactivated and future unpublished shifts cancelled. Reactivate afterwards.
5. employee.a → **Profile**: request a change (phone). The manager approves it in **People → Change requests**.

### 4.11 Notifications
1. The bell shows an unread count; **Notifications** lists them with paging.
2. Mark one read, then **Mark all read**. Expect: the count drops to 0.

### 4.12 Reports and audit export
1. owner → **Reports**: summary metrics; switch entity. Audit log filters (date range, module, action, actor, employee).
2. **Export** audit CSV (owner or entity admin only). Expect: file downloads; the export itself is audited.
3. owner **Home**: group overview (headcount, document expiry, review queue, leave, payroll, recruiting, workflow) across **all** entities, and per entity via the switcher.

### 4.13 Isolation checks
- entityadmin.b and locationmanager.b: no Entity A people, shifts, payroll, attendance, documents, rules or grants anywhere.
- employee.a: never sees another employee's payslip, leave, attendance, documents or draft shifts.

## 5. Automated tests

| Suite | How to run | What it covers |
|---|---|---|
| Unit tests | `npm test` (Vitest) | Pure logic: clock state, payslip PDF, workflow summaries, CSV import, lifecycle rules, formatting, password validation and invite-outcome messages (`src/lib/authFlows.test.ts`) |
| Negative-access (API) | `npm run test:access` from a machine that can reach `*.supabase.co` (uses `.env` + the UAT personas) | Real PostgREST calls as each persona: denied reads/RPCs, entity isolation, revoked user, anon |
| Negative-access (SQL) | Paste `supabase/tests/access_tests.sql` into the Supabase SQL editor (or MCP `execute_sql`) as postgres | Same checks as the API suite, run inside a rolled-back transaction. Expect `passed = total` |
| End-to-end journeys (SQL) | Paste `supabase/tests/e2e_journeys.sql` the same way | Staff clock/attendance/leave/payslips, LM exceptions/correction/leave approval, EA access/branch/lifecycle/workflow/publish/payroll, owner KPIs/retention/audit, cross-entity isolation. Expect every row `pass = true`. Rolled back |

Both SQL suites impersonate personas exactly like PostgREST (`set local role authenticated` +
`request.jwt.claims`) and end in `ROLLBACK`, so nothing persists.

## 6. Pre-go-live checklist

1. **Reassign the Ateej Tea Brew draft job requisition** whose `created_by` is `uat.owner@example.com` to a real owner/admin user (or clear it). Until then `uat_purge_seed()` refuses to run.
2. **Purge UAT data** (postgres, SQL editor): `select public.uat_purge_seed();`. This removes UAT Entity A/B, their data and the eight `uat.*` auth users. It aborts and deletes nothing if real rows still reference a UAT user.
3. **Auth → Leaked password protection**: enable it (Supabase Auth settings). This is the one outstanding security-advisor warning.
4. **Auth → URL configuration**: set Site URL to `https://hr.thirdstate.ae`. Redirect URLs must include `https://hr.thirdstate.ae/set-password` (plus `http://localhost:5173/set-password` and any preview/Vercel URL you test invites or resets on, e.g. `https://*-<vercel-team>.vercel.app/set-password`). A `redirectTo` not on this list silently falls back to the Site URL root and the user never reaches the set-password form.
4a. **Auth → SMTP settings**: configure a custom SMTP sender (e.g. `hr@thirdstate.ae` via your mail provider). The built-in Supabase mailer only delivers to project team members and is limited to a few emails per hour, so real staff invites and resets need custom SMTP. Afterwards raise **Auth → Rate limits → emails sent per hour** to suit onboarding volume.
4b. **Auth → Providers → Email**: keep *Allow new users to sign up* **off** (invites still work). **Auth → Email templates**: keep the default *Invite user* and *Reset password* templates (`{{ .ConfirmationURL }}`) or, if customised, link to `{{ .RedirectTo }}` with `token_hash={{ .TokenHash }}&type=invite|recovery` — `/set-password` handles both.
4c. **Edge Functions**: `invite-user` is ACTIVE with *Verify JWT* on. Optional secret `SITE_URL` only if the app moves off `https://hr.thirdstate.ae`.
5. **Storage placeholders**: the UAT fixture documents point at `uat-fixtures/placeholder-*.pdf` paths with no file. The purge removes their rows. Confirm no real document references `uat-fixtures/`.
6. **Vercel env**: production has `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` set and `VITE_APP_ENV` **unset** (no UAT banner).
7. Re-run the security and performance advisors and expect no ERROR. Run `access_tests.sql` once more after the purge (with the UAT users gone, persona checks return zero rows).
8. Confirm the real owner account signs in and sees both real entities; spot-check one real payroll run is untouched.
