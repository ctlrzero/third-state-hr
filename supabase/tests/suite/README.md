# Database regression suite (self-contained, safe on production)

Each file is one `DO` block. It builds its own throwaway data (entities, branches, `auth.users`,
profiles via `admin_grant_access`, employees, shifts, and so on), acts as different users by setting
`request.jwt.claims` and switching `role` to `authenticated` (the PostgREST API role) or `anon`, and
records a PASS/FAIL line for every check.

Every file ends with `RAISE EXCEPTION 'RESULT ...'`. That error is expected. It means the whole block
was rolled back and **nothing was kept**. The error text is the test report:

```
ERROR: P0001: RESULT suite03 pass=52 fail=5 :: PASS shift: overlapping shift ...; FAIL swap: ...
```

If a file stops with any other error, the test itself broke (for example, a schema change). Nothing is
kept in that case either.

The files need an active owner profile. They use `045a3ad2-0cbe-4c5e-85bf-df27dd29e14f`
(`v_owner` at the top of each file). Profile inserts are protected by a trigger, so every file sets the
JWT to that owner before it creates people.

## How to run

- **Supabase SQL editor:** paste one file and run it. Read the `RESULT` line in the error panel.
- **MCP:** call `execute_sql` with project `yclhzwghzrohusqxfasq` and the file contents as the query.

Each file runs in a few seconds. Run them in any order.

Notes for writing new checks:
- `shifts.is_published` defaults to **true**. Pass `is_published = false` for a draft.
- `authenticated` has no direct UPDATE grant on `employees` or `attendance_records`. Changes go through RPCs.
- A check that is expected to be refused but might succeed can call `raise exception 'zz_allowed'`
  after the call. The sub-block then rolls back the change, and the check counts as FAIL.
- The session user can switch `role` back to `postgres` after `authenticated`/`anon`. The files use
  this to set up data and verify results between actions.

## Files

| File | Covers |
|---|---|
| `01_roles_access.sql` | RLS row visibility on employees, shifts, leave_requests, attendance_records, employee_documents, payroll_records and notifications for owner, entity_admin, location_manager, shift_supervisor, staff and a revoked user (`profiles.is_active = false`). Also: staff can't see their own draft shift or another branch's shifts; direct writes are blocked; staff can submit only their own pending leave; manager and entity-admin write scope; the revoked user has no role; anon can't read any core table or call the main RPCs. Also checks that every function called from an RLS policy is executable by the API role (a missing EXECUTE makes every read of the table fail). |
| `02_leave_flow.sql` | Leave submission reserves balance and notifies the branch manager. Staff, the supervisor, other-branch managers, revoked managers and managers acting on their own leave can't decide it. Entity admin approval returns the live shifts inside the leave window (drafts included; cancelled and out-of-window shifts excluded), sends the manager a "shift needs cover" alert, is audited, and blocks new shifts on leave days. Also covers insufficient balance, override rules (owner or entity admin only, reason required), and reject releasing a reservation. |
| `03_scheduling.sql` | `validate_shift`: overlap, overnight overlap, back-to-back allowed, zero-length and break rules, cancelled shifts don't block. `publish_schedule_period`: who may publish; drafts on approved leave are skipped; other branches untouched. `adjust_published_shift`: reason required, direct edits blocked, overlap re-checked, drafts refused, scope, supervisor limits, revoked or no-profile logins; `cancel_published_shift` for revoked or no-profile logins. Swaps: request, duplicate, claim, cross-branch, approve, notifications. `report_absence`: own, published, future shifts only; creates pending leave and notifies. Offers: who may send; drafts refused; holder skipped; decline, accept, answer once; shift reassigned; notifications. |
| `04_attendance_corrections.sql` | `correct_attendance_record`: reason required; out must be after in; no future times; no no-op; managers and supervisors fix their own branch only and never their own record; entity-admin and owner scope; the first original times are kept across repeat corrections; audited; revoked or no-profile logins. |
| `05_documents.sql` | Stage, confirm, then approve or reject. **Owner's own upload is approved immediately** (restricted types too). Uploads by an entity admin, manager or staff member stay `pending_review` and need a second person (entity-admin self-approval setting is off). Managers can't upload or approve restricted types; entity admin approves them. Covers unconfirmed uploads, reject reason, uploader can't reject, direct-insert shortcuts, and revoked or no-profile staging. |
| `06_transfer_employee.sql` | Only owner or entity admin; same company only; not the same branch; reason required; no past date; not inactive. A same-day transfer completes (home branch and the staff login's scope move; notifications; audit; RLS follows the move). A future transfer is scheduled; a second scheduled transfer is refused. |
| `07_payroll_read_access.sql` | Permission checks only for `get_payroll_readiness`, `get_payroll_changes` and `payroll_can`: owner, entity admin (own entity or other entity), location manager, staff, accountant preset, payroll_admin preset (own entity or other entity), revoked payroll_admin, no-profile login. Uses empty throwaway payroll periods; never creates or changes payroll records or money. |
| `08_payroll_workflow.sql` | Payroll v2 workflow in a throwaway entity with fixed far-future months (Jan-Jun 2098). (a) `payroll_open_off_cycle` with `for_month` spans that month and stores `pay_date`; without it, the period is the pay date only; label required; staff refused. (b) `payroll_set_schedule` refuses a pay date before the salary month (regular and off-cycle), warns on late pay dates, allows editing the pay date after the publish time has passed, refuses a new publish time in the past, staff refused. (c) `run_scheduled_payslip_publishing` (called as a system job with the JWT cleared; it refuses a signed-in user and is not callable by API roles) publishes approved + paid payslips only, leaves unpaid, failed-payment and unapproved ones with a blocked notice that lists what is waiting, publishes a correction to an already-paid payslip, notifies the employee, and does nothing (with a notice saying so) when the scheduling user lost payroll access. (d) `payroll_my_payslips`: titled by salary month (not the off-cycle label), keeps the original payslip while its correction is a draft, shows the correction once published. (e) `payroll_prepare` skips someone already approved in an off-cycle for the same month, still prepares everyone else, and adds the person when selected explicitly. (f) inserting into `payroll_runs` is refused, but a revision (`revises_payroll_run_id` set) is allowed. (g) `get_payroll_changes` compares with the previous salary month across regular, off-cycle and legacy sources, including a legacy-only previous month and the 'left since last month' list. Record states and payments are set up directly as fixtures; legacy run fixtures are created as revisions of an existing run (with a fallback to the maintenance switch if none exists). |

`access_tests.sql` and `e2e_journeys.sql` one level up are superseded. They depend on UAT personas
that no longer exist in production.

## Latest results (2026-09-30, project yclhzwghzrohusqxfasq, after migration restore_open_swap_scope_grant)

| File | PASS | FAIL |
|---|---|---|
| 01_roles_access.sql | 72 | 0 |
| 02_leave_flow.sql | 28 | 0 |
| 03_scheduling.sql | 58 | 0 |
| 04_attendance_corrections.sql | 22 | 0 |
| 05_documents.sql | 32 | 0 |
| 06_transfer_employee.sql | 21 | 0 |
| 07_payroll_read_access.sql | 37 | 0 |
| 08_payroll_workflow.sql | 37 | 0 |
| **Total** | **307** | **0** |

### Bugs this suite found (all fixed; the checks stay as regression guards)

1. **FIXED (migration `restore_open_swap_scope_grant`): `authenticated` could not execute `_open_swap_in_staff_scope(uuid)`,
   which the `shifts_select` RLS policy calls.** Every read of `public.shifts` through the API role failed with
   `permission denied for function _open_swap_in_staff_scope`. Guarded by: 01 `rls policies only call functions the API role can execute`
   (a catalog check that would flag any policy helper missing EXECUTE), the per-role `rls <role> sees N/N shifts` checks, and
   03 `shift: branch manager can read shifts through RLS`.
2. **FIXED (migration `no_role_guard_hotfix_3`): revoked or no-profile logins passed permission checks (NULL-role bug).**
   The functions computed `v_role := my_role()` and then ran `if not (v_role = 'owner' or ...) then raise`.
   `my_role()` is NULL for a revoked login (`is_active = false`) or a login with no profile, so the condition was NULL
   and `if not NULL` did not raise. The hotfix added the no-role guard to 44 functions.
   Guarded by: 03 `adjust: revoked manager ...` / `adjust: login without profile ...` (4), 04 `att: revoked manager refused` and
   `att: login without any profile refused`, 05 `doc: revoked user ...` / `doc: login without profile cannot stage ...`.
3. **FIXED (migration `swap_and_notice_fixes`): `request_shift_swap` accepted unpublished shifts.**
   Guarded by: 03 `swap: cannot request swap on an unpublished (draft) shift`.
4. **FIXED (migration `swap_and_notice_fixes`): revoked managers still got leave / swap notices.**
   Guarded by: 02 `leave: revoked (inactive) manager not notified of new request`.

History on 2026-09-30: first run 258 PASS / 10 FAIL (bugs 2 to 4); second run 268 / 0; after the payroll migrations and suite 08,
296 PASS / 10 FAIL (bug 1); after the grant fix, 307 / 0.
