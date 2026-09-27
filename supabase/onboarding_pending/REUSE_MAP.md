# Reuse map (spec §15)

Each existing piece was inspected read-only on production on 27 Sep 2026 before anything was
written. This build adds only the missing transitions. No second employee master is created and
Recruiting is not rewritten.

| Existing piece | What it does today | How onboarding uses it | Changed? |
|---|---|---|---|
| `convert_offer_to_employee(offer)` | Owner or EA; creates a `pre_boarding` employee from an accepted offer; marks the application and candidate hired | Called unchanged by `start_onboarding_from_offer`, which first adds the missing checks: offer accepted, duplicate identity in the same company, template exists. It also makes retries safe | No |
| `employees` + triggers (leave balances, compensation seed, legacy checklist, audit) | The employee master | Remains the only employee record. Onboarding stores its process in `onboarding_instances` and writes setup back to `employees` | Additive columns only |
| `seed_onboarding_checklist` / `onboarding_checklist_items` | Service-only flat checklist | Left in place. The versioned, role-aware tasks come from `onboarding_templates` → `onboarding_tasks` | No |
| `set_employee_status` | Controls status changes, including the key-documents gate on activation | Activation calls it, so the documents gate is re-checked. Cancel and withdraw call it to set the employee inactive and revoke logins. 010 adds a guard so that the first activation happens only through onboarding | 010 only |
| `employee_missing_key_documents` | Passport, visa (except Emirati), Emirates ID, contract | The readiness engine uses the same function, so the two rules can never drift apart | No |
| `employee_documents`, `stage_document_upload`, `confirm_document_upload`, `approve_document`, `can_review_document`, document triggers | Upload, review and versioning | Document tasks follow these records (`_onb_sync_derived`). HR reviews stay on the existing document review path. The new `stage_my_onboarding_document` uses the same path format and review lifecycle, then the employee confirms with the existing `confirm_document_upload` | No (new self-staging RPC plus additive policies) |
| Storage policies on `employee-documents` | Staff access requires employment status `active` | Additive policies let the pre-boarding employee upload only to server-staged paths and read their own files while onboarding is open | Additive |
| `admin_grant_access`, `_apply_access_grant`, `handle_new_user`, `invite-user` Edge Function | Pending grants and linking a login at sign-up | The invitation creates a staff grant linked to the employee. Sign-up links the login through the existing trigger | No |
| `payroll_can`, `_payroll_can_edit_pay`, `payroll_set_compensation`, `compensation_versions` (payroll v2) | Pay permissions and effective-dated pay | Pending pay is checked with the same permission. At activation it becomes the first version through `payroll_set_compensation`. It is never written early, so payroll never sees an employee who has not started | No |
| `create_notification` (dedupe key) | Notifications | Every onboarding notification has a deterministic dedupe key, so retries never duplicate them | No |
| `evaluate_workflow_rules`, `workflow_rules`, `workflow_trigger_catalog` | Configurable notify rules | Adds the `onboarding` module and 7 events. The other modules' events are copied from the live catalog unchanged | Constraint widened, catalog extended |
| `audit_log` | Owner-readable audit | Onboarding audit rows carry `operation_id` and `onboarding_instance_id` | No |
| Leave balances | Seeded by the employee insert trigger | Already present for onboarding employees, so no extra step is needed | No |
| Scheduling eligibility | Shifts need an active employee | Automatically eligible after activation. Nothing was added | No |

## Missing transitions this build adds

1. Accepted offer or direct hire → a controlled onboarding instance: one lifecycle and one
   template snapshot.
2. Invitation → issued, accepted, expired or revoked, with reissue.
3. Employee save and resume → section submission → review → changes required → resubmission.
4. Pay entry → payroll review. Bank details → payroll verification. Both are maker-checker.
5. Server-calculated readiness that automatically moves the status to or from
   `ready_for_activation`.
6. Atomic, idempotent approve-and-activate.
7. Day one: started, no-show or delayed. Then initial-period tasks, then closure.
8. Probation: scheduled at activation, review, decision, extension capped at 6 months.
9. Reminders and escalation, invitation expiry, probation-due events.
