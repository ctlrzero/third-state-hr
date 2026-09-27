# Core HR implementation register — proposed updates

These rows update the existing register (PROC-01, CAP-14, and the rows they directly affect).
Paste them in once the migrations are applied and the validation run passes.

Under spec §14, the status cannot be `IMPLEMENTED — VERIFICATION DEFERRED` yet, because the
employee, manager, HR, payroll and approver screens do not exist. The honest status is
**BACKEND COMPLETE — UI PENDING**.

| ID | Requirement | Previous status | New status | Evidence | Remaining |
|---|---|---|---|---|---|
| PROC-01 | Hire-to-active onboarding process | Partial: offer conversion only; `pre_boarding → active` by hand | **Backend complete — UI pending** | Migrations 001–009 (lifecycle, portal RPCs, reviews, activation, day one, probation); `tests/onboarding_tests.sql` | Onboarding screens; deploy 010 with them; persona UAT |
| CAP-14 | Controlled employee activation | Manual status edit, gated on key documents only | **Backend complete — UI pending** | `approve_and_activate_employee` (006): server readiness, row lock and version check, idempotent, atomic downstream setup, maker-checker; guard in 010 | Deploy 010 with the UI; remove the profile Activate button for pre-boarding employees |
| (documents) | Employee self-upload of documents | Active staff only | **Extended**: pre-boarding employees too, while onboarding is open | `stage_my_onboarding_document` (004), additive policies (009) | UI upload step in the portal |
| (payroll) | Starting pay and bank details | Entered after activation | **Extended**: entered before activation, reviewed by payroll, applied at activation | 005, 006 | Payroll-review screen |
| (probation) | Probation tracking | `employees.probation_end_date` field only | **Added**: periods, reviews, decisions, 6-month cap | 007 | Probation screens |
| (workflow) | Workflow modules | leave, document, attendance, schedule, payroll, recruitment | **+ onboarding** (7 events) | 008 | Add rules in the Workflow settings UI |

## Definition of Implemented (§14) — current position

| Criterion | Where |
|---|---|
| Offer and direct-hire paths share one lifecycle | ✅ 003 |
| No duplicate employee master | ✅ 003 |
| Transitions only through controlled operations | ✅ 002 state machine; 010 for activation |
| Role, entity, branch and field scope | ✅ 009 RLS; field filtering in RPCs |
| Save and resume, submit, reject, resubmit | ✅ 004 / 005 |
| Review separation enforced on the server | ✅ 005 / 006 |
| Readiness calculated on the server; activation blocked | ✅ 002 / 006 |
| Atomic, idempotent activation | ✅ 006 |
| Day-one and follow-up tasks usable | ⚠️ Backend only |
| Probation scheduled and controlled | ✅ 006 / 007 |
| Notifications deduplicated and retry-safe | ✅ dedupe keys |
| Audit: actor, time, reason, before/after, operation id | ✅ `_onb_audit` |
| Interfaces reachable; no dead buttons | ❌ No UI yet |
