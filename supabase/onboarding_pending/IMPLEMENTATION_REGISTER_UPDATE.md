# Core HR implementation register — proposed updates

These rows update the existing register (PROC-01, CAP-14, and the rows they directly affect).
Paste them in once the migrations are applied and the validation run passes.

Under spec §14, the status cannot be `IMPLEMENTED — VERIFICATION DEFERRED` until the screens have
been used against the deployed backend. The honest status is
**BUILT — NOT YET DEPLOYED OR VERIFIED**: the screens exist on `feat/onboarding` but have not been run against a database with this backend.

| ID | Requirement | Previous status | New status | Evidence | Remaining |
|---|---|---|---|---|---|
| PROC-01 | Hire-to-active onboarding process | Partial: offer conversion only; `pre_boarding → active` by hand | **Built — not yet deployed or verified** | Migrations 001–013; `tests/onboarding_tests.sql`; UI on branch `feat/onboarding` | Deploy and run the validation file; deploy 010 with the UI; persona UAT |
| CAP-14 | Controlled employee activation | Manual status edit, gated on key documents only | **Built — not yet deployed or verified** | `approve_and_activate_employee` (006): server readiness, row lock and version check, idempotent, atomic downstream setup, maker-checker; guard in 010; "Approve and activate" in the workspace | Deploy 010 with the UI; start onboarding for any pre-boarding employee without one first |
| (documents) | Employee self-upload of documents | Active staff only | **Extended**: pre-boarding employees too, while onboarding is open | `stage_my_onboarding_document` (004), additive policies (009), portal upload step | — |
| (payroll) | Starting pay and bank details | Entered after activation | **Extended**: entered before activation, reviewed by payroll, applied at activation | 005, 006, workspace pay / bank cards | — |
| (probation) | Probation tracking | `employees.probation_end_date` field only | **Added**: periods, reviews, decisions, 6-month cap | 007, Onboarding → Probation | — |
| (templates) | Configurable onboarding checklists | API only | **Added**: template editor (new / edit as new version / copy) | Setup tab, `TemplateEditor.tsx` | — |
| (jobs) | Job descriptions | None | **Added** | 011 `upsert_position`, Setup → Jobs | — |
| (availability) | Availability capture at hire | Managers only | **Added**: self-service during onboarding | 011, portal step | — |
| (immigration) | Work permit and visa processing | Documents only | **Added**: case per hire, steps by situation, blocking steps, reminders | 012, workspace / profile / Visas tab | Check steps against current MOHRE / ICP rules |
| (offboarding) | End of employment | Manual inactivate | **Added**: notice rules, checklist, settlement deadline, controlled finish | 013, `/offboarding` | Final settlement itself is still paid through Payroll off-cycle |
| (workflow) | Workflow modules | leave, document, attendance, schedule, payroll, recruitment | **+ onboarding** (8 events), **+ offboarding** (2) | 008 | Add rules in the Workflow settings UI |

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
| Day-one and follow-up tasks usable | ✅ workspace + portal (unverified) |
| Probation scheduled and controlled | ✅ 006 / 007 |
| Notifications deduplicated and retry-safe | ✅ dedupe keys |
| Audit: actor, time, reason, before/after, operation id | ✅ `_onb_audit` |
| Interfaces reachable; no dead buttons | ⚠️ Built on `feat/onboarding`; not yet clicked through against a live backend |
