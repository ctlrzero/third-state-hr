# API contract additions — Onboarding (Builds A–E)

These rows are for `claude/API_CONTRACT.md` and use its `RPC | Args | Roles | Returns` format.
They only add to the contract. Nothing existing changes, except that `set_employee_status` gains
the guard in migration 010. Its signature does not change.

**Roles:**

| Code | Who |
|---|---|
| O | owner |
| EA | entity admin, own entity |
| LM | location manager, own branch |
| PAY | `payroll_can(entity,'approve')`: owner, EA, payroll_admin preset |
| SELF | the employee, resolved from the login; never taken from the client |

**Errors:**

| SQLSTATE | Meaning |
|---|---|
| `42501` | not allowed |
| `22023` | invalid, or not in the right state |
| `23505` | duplicate |
| `40001` | stale `row_version`: reload and retry |
| `P0002` | not found |

Every pre-activation write returns or updates the readiness object:
`{ready, blockers[{code, owner_role, message, task_id?, due_date?}], warnings[], blocking_count, required_total, required_done, percent, next_action}`.

## 12. Onboarding

### 12.1 Setup (Build A)

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `set_onboarding_settings` | `p_entity_id uuid, p jsonb` (invitation_valid_days, probation_months ≤ 6, probation_review_days_before, default_task_sla_days, require_distinct_activation_approver) | O, EA (only O may turn off distinct approver) | `jsonb` settings |
| `set_employee_numbering` | `p_entity_id, p_prefix, p_next_value, p_pad_width` | O, EA | `jsonb` |
| `seed_default_onboarding_template` | `p_entity_id` | O, EA | `uuid` (idempotent) |
| `create_onboarding_template` | `p_entity_id, p_name, p_description, p_tasks jsonb, p_employment_types employment_type[] = null, p_position_ids uuid[] = null` | O, EA | `uuid` |
| `replace_onboarding_template` | `p_template_id, p_name, p_description, p_tasks, p_employment_types = null, p_position_ids = null` | O, EA | `uuid` (new version; open onboardings keep their snapshot) |
| `deactivate_onboarding_template` | `p_template_id` | O, EA | `void` |
| `upsert_onboarding_policy` | `p_entity_id, p_policy_key, p_version, p_title, p_body` | O, EA | `uuid` (a new version needs a new acknowledgement) |

### 12.2 Lifecycle (Build A)

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `start_onboarding_from_offer` | `p_offer_id, p_reporting_manager_employee_id = null` | O, EA | `jsonb {ok, already_started, employee_id, onboarding_instance_id, task_count}`; retry-safe |
| `start_onboarding_direct_hire` | `p_entity_id, p_full_name, p_email, p_phone, p_gender, p_home_location_id, p_position_id, p_employment_type, p_start_date, p_reporting_manager_employee_id, p_reason` | O, EA | `jsonb {ok, employee_id, onboarding_instance_id, task_count}` |
| `start_onboarding_for_employee` | `p_employee_id, p_reporting_manager_employee_id, p_reason` | O, EA | `jsonb {ok, employee_id, onboarding_instance_id}` (existing candidate or pre-boarding employee) |
| `update_onboarding_setup` | `p_instance_id, p jsonb` (home_location_id, position_id, reporting_manager_employee_id, employment_type, proposed_start_date), `p_reason, p_expected_version` | O, EA | readiness |
| `cancel_onboarding` / `withdraw_onboarding` | `p_instance_id, p_reason` | O, EA | `jsonb {ok, already, status}` (employee kept, set inactive) |
| `list_onboarding` | `p_entity_id, p_tab = 'all'` (`new`, `awaiting_employee`, `under_review`, `blocked`, `ready`, `starting_soon`, `in_progress`, `completed`, `cancelled` (cancelled or withdrawn), `all`) | O, EA, LM, PAY | `jsonb[]` rows with readiness summary |
| `get_onboarding_workspace` | `p_instance_id` | O, EA, LM, PAY | `jsonb` (pay for EA/PAY only; full IBAN for PAY, masked for HR; LM sees operations view) |
| `calculate_onboarding_readiness` | `p_instance_id` | O, EA, LM, PAY | readiness (and re-derives the status) |

### 12.3 Pre-boarding (Build B)

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `issue_onboarding_invitation` | `p_instance_id` | O, EA | `jsonb {ok, already_issued, invitation_id, email, expires_at, send_email}`; if `send_email`, call the `invite-user` Edge Function |
| `reissue_onboarding_invitation` | `p_instance_id, p_reason, p_new_email = null` | O, EA | same as issue |
| `get_my_onboarding` | none | SELF | `jsonb {ok, onboarding: {…, readiness, tasks, sections, documents, payment_details (last 4 digits), policies, contract} \| null}`; marks the invitation accepted |
| `save_my_onboarding_profile` | `p jsonb` (preferred_name, phone, dob, gender, nationality, residential_address, emergency_contact_name, emergency_contact_phone) | SELF, before activation, not while under review | `jsonb {ok}` |
| `stage_my_onboarding_document` | `p_doc_type, p_file_extension, p_expiry_date = null, p_notes = null` | SELF | `jsonb {id, storage_path}`; upload to `employee-documents/<storage_path>`, then call `confirm_document_upload(id)` |
| `save_my_payment_details` | `p_method, p_bank_name, p_account_name, p_iban, p_routing_code = null` | SELF | `jsonb {ok, id}` |
| `acknowledge_onboarding_policy` | `p_policy_id` | SELF | `jsonb {ok, already}` |
| `accept_employment_contract` | `p_onboarding_instance_id` | SELF | `jsonb {ok, already_accepted, acceptance_id}` |
| `get_my_contract` | none | SELF | `jsonb {ok, contract: {document_id, version, expiry_date, reviewed_at, storage_path, accepted_at} \| null}` |
| `get_my_job_description` | none | SELF | `jsonb {ok, position: {position_id, title, department, description} \| null}` |
| `submit_onboarding_section` | `p_instance_id, p_section` | the section's owner role | readiness |
| `complete_onboarding_task` | `p_task_id, p_evidence jsonb = null` | the task's owner role (manual tasks only) | `jsonb {ok, already, status}` |

### 12.4 Reviews (Build C)

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `review_onboarding_section` | `p_instance_id, p_section, p_decision` (approved / changes_required / rejected), `p_reason` | the section's reviewer role; not the submitter | readiness |
| `review_onboarding_task` | `p_task_id, p_decision, p_reason` | the reviewer role; not the completer | `jsonb {ok, status}` |
| `waive_onboarding_task` | `p_task_id, p_reason` | O, EA (not statutory, pay, contract or key documents) | `jsonb {ok, already}` |
| `set_onboarding_pending_compensation` | `p_instance_id, p_effective_from, p_pay_type, p_basic_monthly, p_hourly_rate, p_overtime_eligible, p_reason, p_variance_reason = null` | O, EA, PAY | `jsonb {ok, status, differs_from_offer}` |
| `review_onboarding_compensation` | `p_instance_id, p_decision, p_reason` | PAY; not the maker | `jsonb {ok, status}` |
| `verify_payment_details` | `p_payment_details_id, p_decision` (verified / rejected), `p_reason` | PAY; not the submitter | `jsonb {ok, status}` |
| `raise_onboarding_exception` | `p_instance_id, p_type, p_description, p_owner_role = 'hr', p_is_blocking = true, p_due_date = null` | O, EA, LM | `jsonb {ok, exception_id}` |
| `resolve_onboarding_exception` | `p_exception_id, p_resolution, p_cancel = false` | the owner role, or O / EA | `jsonb {ok, already}` |
| `onboarding_dashboard_summary` | `p_entity_id` | O, EA, LM, PAY | `jsonb` counts |

### 12.5 Activation (Build D)

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `approve_and_activate_employee` | `p_instance_id, p_expected_version, p_reason = null` | O, EA; never self; not the pay maker or reviewer unless O (setting) | `jsonb {ok, already_activated, operation_id, employee_id, status, join_date, probation_end_date, post_start_tasks}` |

### 12.6 Day one, probation and reports (Build E)

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `record_day_one_outcome` | `p_instance_id, p_outcome` (started / no_show / delayed), `p_new_start_date = null, p_reason = null` | O, EA, LM | `jsonb {ok, already, outcome}` |
| `close_onboarding` | `p_instance_id, p_notes = null` | O, EA | `jsonb {ok, already, summary}` |
| `record_probation_review` | `p_period_id, p_recommendation` (confirm / extend / not_confirm), `p_comments, p_ratings jsonb = null` | O, EA, LM | `jsonb {ok, review_id}` |
| `decide_probation_outcome` | `p_period_id, p_outcome` (confirmed / extended / not_confirmed), `p_effective_date, p_new_end_date = null, p_reason = null` | O, EA; needs a review by someone else | `jsonb {ok, outcome, new_period_id}` |
| `list_probation_due` | `p_entity_id, p_within_days = 30` | O, EA, LM | `jsonb[]` |
| `onboarding_report` | `p_entity_id, p_kind, p_from = null, p_to = null` | O, EA, LM (branch-scoped) | `jsonb {kind, from, to, data}` |

`p_kind` is one of: `funnel`, `ageing`, `blocked_reasons`, `starting_soon`, `overdue_tasks`,
`invitations`, `document_rejections`, `day_one`, `probation_due`, `time_to_activate`.

### 12.7 System-only (not callable by the app)

- `onboarding_send_reminders()`: run by pg_cron.

### 12.8 Direct reads (RLS, select only)

The tables are readable in scope as follows:

| Table | Who can read it |
|---|---|
| `onboarding_instances` | O, EA, LM (own branch), PAY, SELF |
| `onboarding_tasks` | as the instance, but payroll-section tasks only O / EA / PAY |
| `onboarding_pending_compensation` | O, EA, PAY only; never SELF or LM |
| `employee_payment_details` | PAY and SELF only |
| `employee_contract_acceptances` | O, EA, SELF; never LM |
| `employee_probation_reviews` | management only |
