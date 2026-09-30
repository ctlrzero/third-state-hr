# TS-HR API contract (PostgREST RPC)

Every call is `POST /rest/v1/rpc/<name>` with the user's access token (`supabase.rpc(name, args)`),
arguments passed **by name**. All RPCs are `SECURITY DEFINER`, `search_path = ''`, EXECUTE granted to
`authenticated` only (never `anon`). Identity is always taken from `auth.uid()`; an inactive/revoked
profile resolves to no role, so every role-gated RPC denies it and every self-service RPC returns nothing.

Roles: **O** owner (group-wide, `profiles.entity_id` is NULL) · **EA** entity_admin (own entity) ·
**LM** location_manager (own location; never salary, allowances, payroll, bank or payslips of others) ·
**S** staff (own records only). "Scoped" = EA limited to own entity, LM to own location.

Errors are raised as Postgres exceptions (`{code, message}` from PostgREST); `42501` = not authorised,
`22023` = invalid input, `P0002` = not found. Some older payroll/attendance RPCs instead return
`{ok:false, code, message, request_id}` (noted below).

Business dates are **Asia/Dubai** everywhere (`business_date`, `shift_date`, exception dates).

Legend for changes in this pass (W3): **[new]**, **[fixed]** (body only, same signature/shape),
**[additive]** (signature or shape extended in a backwards-compatible way).

---

## 1. Attendance / clock screen

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `get_my_clock_status` | – | any with linked employee | `jsonb` (below) |
| `get_my_attendance` | `p_period_start date, p_period_end date` | own | `TABLE(attendance_id, shift_id, business_date date, location_id, location_name, planned_start tz, planned_end tz, clock_in_at tz, clock_out_at tz, worked_minutes int, late_minutes int, status text, corrected bool, correction_reason text)` |
| `clock_in` | – | active employee | `{id, shift_id, clock_in_at, already_clocked_in}` |
| `clock_out` | – | own open record | `{id, clock_out_at, already_clocked_out}` |
| `get_location_attendance_overview` | `p_location_id, p_period_start date, p_period_end date` | O, EA scoped, LM own location | `TABLE(shift_id, employee_id, shift_date, planned_minutes, default_payable_minutes, final_payable_minutes, payable_status, pending_adjustment bool)` |
| `get_attendance_exceptions` **[fixed]** | `p_location_id, p_period_start, p_period_end` | O, EA scoped, LM own | `TABLE(exception_type, employee_id, employee_name, shift_date, record_id, shift_id, clock_in_at, clock_out_at)` |
| `get_branch_today` **[new, P1-3]** | `p_location_id uuid` | O, EA scoped, LM own location | `jsonb {location_id, location_name, date, generated_at, people[{shift_id, employee_id, name, phone, position, start_time, end_time, planned_start, planned_end, attendance_id, clock_in_at, clock_out_at, late_minutes, status}], unscheduled[], missing_clock_outs[], open_gaps[], on_leave[], draft_shifts, approvals{leave, swaps, documents}}` |
| `report_absence` **[new, P1-4]** | `p_shift_id uuid, p_leave_type_id uuid, p_note text = null` | staff (own published shift, not ended) | `jsonb {ok, leave_request_id, shift_id, managers_notified}` |
| `transfer_employee` **[new, P1-6]** | `p_employee_id, p_new_home_location_id, p_effective_date date, p_reason text` | O, EA scoped | `jsonb {ok, transfer_id, status: scheduled/completed, effective_date, from_location_id, to_location_id, to_location_name, review}` |
| `cancel_employee_transfer` **[new, P1-6]** | `p_transfer_id, p_reason text = null` | O, EA scoped | `jsonb {ok}` |
| `get_transfer_review` **[new, P1-6]** | `p_transfer_id` | O, EA scoped, LM of old or new branch | `jsonb {shifts[], templates[], availability[], work_pattern}` |
| `correct_attendance_record` **[fixed]** | `p_record_id, p_new_clock_in_at tz, p_new_clock_out_at tz, p_reason text` | O, EA scoped, LM own location; never own record | `void` |
| `seed_payable_shift_records` | `p_location_id, p_period_start, p_period_end` | O, EA, LM own | `{ok, request_id, seeded_count}` or `{ok:false, code, message}` |
| `propose_attendance_adjustment` | `p_payable_shift_record_id, p_proposed_minutes int, p_reason` | O, EA, LM own | `{ok, ...}` |
| `apply_attendance_adjustment` | `p_adjustment_id` | O, EA | `{ok, request_id}` / `{ok:false, code:'ALREADY_DECIDED'...}` |
| `reject_attendance_adjustment` | `p_adjustment_id, p_reason` | O, EA | `{ok, ...}` |

`get_my_clock_status` shape:
```json
{ "state": "no_shift|not_started|clocked_in|clocked_out",
  "business_date": "2026-09-25", "server_time": "…",
  "today_shift": null | {"id","shift_date","start_time","end_time","planned_start","planned_end",
                         "location_id","location_name","position_title","status"},
  "attendance":  null | {"id","shift_id","clock_in_at","clock_out_at","worked_minutes","late_minutes","corrected"} }
```
`get_my_attendance.status`: `scheduled | in_progress | completed | missed | unscheduled`. Only published
shifts appear. Max range 93 days.

Notes
- `clock_in`/`clock_out` are idempotent (repeat taps return the open/closed record) and serialised per employee.
  An open record from a previous day (missing clock-out) keeps the employee `clocked_in` until corrected.
- `correct_attendance_record`: reason required; **NULL for a timestamp now means "keep current value"**
  (previously NULL clock-in raised 23502 and NULL clock-out silently erased the clock-out). Validation on the
  effective values: out > in, not in the future, must change something. First originals are preserved in
  `original_clock_in_at/out_at`; audited `attendance_corrected`.
- **Payroll explainer (P2-3).** `get_payroll_changes(p_period_id)` (payroll `view_pay`; read-only) → `{label, previous_label, currency, employees[{employee_id, name, record_status, net_now, net_prev, net_change, gross_now, gross_prev, new_this_month, changes[{kind, code, label, now, prev, change, explanation}]}], left_since_last_month[], totals{net_now, net_prev}}` against the previous regular month. Edge Function `payroll-explainer` (POST `{period_id}`, caller's JWT) turns it into `{summary[≤4], people[{employee_id, name, sentence}]}` with Claude (`PAYROLL_EXPLAINER_MODEL`, default `claude-sonnet-5-5`) — **pay amounts are sent (owner approved 2026-09-30)**; rule-based without a key. Stored via `log_payroll_explanation` in `ai_suggestions` (`kind = 'payroll_explainer'`), readable only by people with `view_pay`.
- **Roster summary (P2-4).** Edge Function `roster-assistant` (POST `{entity_id, period_start, period_end, location_ids|null}`, caller's JWT): re-runs the read-only `propose_auto_schedule`, summarises hours per person, branch moves, gaps and warnings, and asks Claude (`ROSTER_ASSISTANT_MODEL`, default `claude-sonnet-5-5`) for `{headline, points[≤5]}` — no pay; rule-based without a key. Stored via `log_roster_summary(p_entity_id, p_inputs, p_output, p_model)` (O, EA / LM same company) in `ai_suggestions` (`kind = 'roster_summary'`). Never creates shifts.
- **Absence cover (P2-1).** Edge Function `cover-assistant` (POST `{shift_id}`, caller's JWT; never the service role): reads `suggest_shift_cover`, asks Claude (`ANTHROPIC_API_KEY`, model `COVER_ASSISTANT_MODEL`, default `claude-sonnet-5-5`) to rank ≤3 of the eligible people and draft a ≤280-char offer — names, positions, the shift and hours this week only, never pay; falls back to the rule order and a template (`ai:false`) without a key or on error. Stores every result with `log_ai_suggestion` in `ai_suggestions` (inputs, output, model). Returns `{suggestion_id, ai, model, message, ranking[{employee_id, name, reason}], candidates, not_eligible}`.
  `send_shift_offer(p_shift_id, p_employee_ids uuid[], p_message, p_suggestion_id)` (O, EA, LM / supervisor own branch; published, not started): re-checks `_shift_eligibility` per person, skips the current assignee / yourself / already offered, notifies each (`shift_offer`, high) → `{ok, sent[{employee_id, name, offer_id}], skipped[{employee_id, name, reason}]}`. `respond_shift_offer(p_offer_id, p_accept)` (the offered employee): decline → notifies the sender; accept → only if the shift is unchanged (same person, not started/cancelled) and still eligible, reassigns it (history reason "Cover: shift offer accepted"), closes other offers, notifies the sender and the person covered. `get_my_shift_offers()` → pending offers for me. Cron `no-clock-in-alerts` (every 5 min, `run_no_clock_in_alerts`): published shift 15–45 min past start, no clock-in, no absence report or leave → `no_clock_in` notice to branch managers and supervisors (once per shift).
- `get_payroll_readiness(p_period_id)` (P2-2, read-only; needs payroll `prepare` or `approve`): `{period_id, entity_id, kind, label, period_start, period_end, pay_date, days_to_pay_day, records, approved, blocking, warnings, ready, items[{key, severity: blocking|warning, count, title, people[name | {name, detail}] (≤8), link, action}]}`. Items: `settings_unconfirmed`, `not_prepared`, `attention_<code>` (the engine's blocking/warning checks on current unpublished records), `pending_leave`, `missing_clock_out`, `shift_no_attendance`, `pending_time_adjustments`, `payment_details` (no verified details), `draft_shifts`. Names and counts only — no amounts. Pay date = `pay_day` of the month after a regular month; an off-cycle's own date.
- `activate_employee_with_open_items(p_instance_id, p_expected_version, p_reason)` (owner / company admin, reason required): runs `approve_and_activate_employee` while documents, tasks, pay review, contract or blocking problems are still open. Still refused: no home branch, no start date / start >30 days past, duplicate person, not pre-boarding, activating yourself. Starting pay is applied only if payroll approved it. Sets `onboarding_instances.activated_with_open_items` (+ `open_items_at_activation` snapshot); `_onb_open_items` counts what's left; `open_items_cleared_at` is set by the daily reminder job when it reaches 0. `list_onboarding` has tab `incomplete` and row fields `activated_with_open_items`, `open_items`; `onboarding_dashboard_summary.activated_incomplete`. Notices: `onboarding_open_items` to the employee (at activation, then the normal daily task reminder) and HR (at activation, Mondays, and once when cleared).
- `generate_shifts_from_templates` (P1-8): creates split shifts — a person can have several non-overlapping templates on one weekday (already allowed by `create_schedule_template`). A template day is skipped only if it would overlap a non-cancelled shift the person already has (same test as `validate_shift`, including overnight shifts from the day before/after) or they are on approved leave; skipped days never fail the run. Returns the number created; re-running is idempotent.
- **Shift supervisor (`shift_supervisor`, P1-7).** An employee login tied to their home branch (`admin_grant_access` needs company + branch + employee, branch = the employee's home branch). Keeps all staff self-service. Extra, own branch only: `get_branch_today` (leave/document approval counts are 0; `pending_swaps` list), `get_attendance_exceptions`, `correct_attendance_record` (never own record), `approve_shift_swap` (not a swap they're part of), `suggest_shift_cover`, and `adjust_published_shift` limited to changing the employee (not to/from themselves). Told about `absence_reported` at their branch. Everything else that checks roles lists roles explicitly, so supervisors get no pay, bank, other people's documents, employee edits, leave decisions, scheduling or payable-time access; table RLS treats them like staff. Test: `supabase/tests/p1_7_supervisor_test.sql`.
- `get_branch_today` also returns `pending_swaps[{swap_id, shift_id, shift_date, start_time, end_time, from_name, to_name, notes}]`, and each `people[]` / `open_gaps[]` row carries `shift_date, break_minutes, location_id` (for Find cover).
- Transfers (`employee_transfers`, read via RLS: O, EA scoped, LM of either branch; no direct writes): same company only (`22023` otherwise — offboard + onboard), reason required, date today or later, one scheduled transfer per employee. Effective today → applied at once; later → applied by cron `employee-transfers-due` (00:05 Dubai, `run_due_employee_transfers`). Applying sets `employees.home_location_id` and, for a staff login, `profiles.location_id`; audited as `employee_transfer_scheduled` / `employee_transferred` / `employee_transfer_cancelled`. `review` lists the employee's non-cancelled shifts at the old branch from the effective date, active recurring templates there, availability and work pattern — nothing is cancelled automatically. Notices: old-branch managers when scheduled; the employee and new-branch managers when applied.
- `report_absence`: creates a pending 1-day leave request for the shift date (normal leave triggers apply), adds a `shift_adjustments` row with `change_type = 'absence_reported'` (`new_values.leave_request_id`), and sends a high-priority `absence_reported` notice (target `shifts`) to the branch's active location managers, or the company's entity admins if the branch has none. The shift stays assigned; cover is found by a manager (`suggest_shift_cover`). Errors: `42501` not your shift / no employee record, `22023` shift not active or ended, bad leave type, or leave already covers the day. `get_branch_today` returns `status = 'absent_reported'` plus `absence_leave_request_id`, `absence_leave_status`, `absence_note` for these shifts while the leave is pending or approved.
- `get_branch_today.people[].status`: `upcoming | not_in | in | in_late | done | no_show` (published shifts only; late = clock-in more than 59 s after planned start). `missing_clock_outs` covers the previous 14 Dubai days; `approvals.documents` counts only documents this caller may review (`can_review_document`). No pay data. Errors: `42501` not authorized, `P0002` branch not found.
- `get_attendance_exceptions.exception_type`: `missing_clock_out` (open record from a previous Dubai day),
  **`late_clock_in` [additive value]** (clock-in > planned start; informational, no deduction),
  `unmatched_shift` (published past shift without attendance), `no_shift_match` (attendance without shift).
- Lateness/absence never changes pay automatically.

## 2. Workflows

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `workflow_trigger_catalog` | – | authenticated | `jsonb` catalog (below) |
| `get_workflow_rules` | `p_module text = null, p_entity_id uuid = null` | O (null = all entities), EA (own; other id → 42501) | `SETOF workflow_rules` |
| `get_workflow_runs` | `p_rule_id = null, p_limit int = 50, p_entity_id = null` | O, EA | `SETOF workflow_runs(id, rule_id, entity_id, source_table, source_record_id, event_type, result 'matched'|'skipped'|'failed', details jsonb, ran_at)` |
| `create_workflow_rule` | `p_name, p_module, p_trigger_event, p_condition_field, p_condition_operator, p_condition_value, p_action_type, p_action_target_role user_role, p_action_message_template, p_entity_id` | O (**p_entity_id required**), EA (null or own) | `uuid` |
| `test_workflow_rule` | `p_rule_id, p_sample_event jsonb` | O, EA scoped | `'matched' | 'skipped'` |
| `activate_workflow_rule` / `deactivate_workflow_rule` | `p_rule_id` | O, EA scoped | `void` |

`workflow_rules` columns: `id, entity_id, name, module, trigger_event, condition_field, condition_operator,
condition_value, action_type, action_target_role, action_message_template, is_active, is_starter,
version_number, supersedes_rule_id, created_by, created_at, updated_at, activated_at, deactivated_at`.

### Catalog accepted by the DB (exact)

Modules (`workflow_rules_module_check`): `leave, document, attendance, schedule, payroll, recruitment`.

| module | trigger_event | condition fields (event data keys) | fired by |
|---|---|---|---|
| leave | `leave_submitted` | `employee_id, location_id, leave_type_id, days_requested` | INSERT pending leave_request |
| document | `document_expiring_soon` | `employee_id, location_id, document_id, doc_type, expiry_date, days_to_expiry` | daily expiry check (T-30) |
| document | `submitted_for_review` | `employee_id, location_id, document_id, doc_type, is_renewal` | upload confirmed as pending_review |
| attendance | `late_clock_in` | `employee_id, location_id, shift_id, attendance_id, late_minutes` | clock-in after planned start |
| schedule | `schedule_published` | `employee_id, location_id, shift_date` | shift becomes published |
| schedule | `shift_adjusted` | `employee_id, previous_employee_id, location_id, shift_date, change_type` | published shift changed; `change_type` ∈ `cancelled, unpublished, reassigned, date_changed, location_changed, time_changed` |
| payroll | `payslip_published` | `employee_id, payroll_run_id, period_start, period_end, is_revision` | run → approved/paid (per payslip) |
| recruitment | *(none yet)* | – | – |

- Operators (`workflow_rules_condition_operator_check`): `eq, neq, gt, gte, lt, lte, contains`.
  Condition is all-or-nothing: field, operator and value are all NULL (always matches) or all set.
  Condition field must be in the trigger's list above (else 22023).
- `action_type`: `notify_role` (requires `p_action_target_role` ∈ `owner, entity_admin, location_manager, staff`;
  location_manager/staff recipients are filtered to the event's `location_id`) or `notify_employee`
  (target role must be NULL; notifies the event's employee).
- Notification text is the rule's `action_message_template` only; never include salary, bank or document numbers.

## 3. Organisation & access admin

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `admin_upsert_entity` | `p_id (null=create), p_name, p_code, p_trade_license_no, p_emirate, p_default_currency, p_payroll_day smallint, p_is_active` | O only | `uuid` |
| `admin_upsert_location` | `p_id (null=create), p_entity_id, p_name, p_code, p_address, p_is_active` | O, EA own entity | `uuid` |
| `get_entity_dependency_summary` | `p_entity_id, p_location_id` (either) | O, EA own | `{entity_id, location_id, active_employees, future_shifts, draft_payroll_runs, open_leave_requests}` |
| `admin_list_user_access` | `p_entity_id` (O: null = all) | O, EA own | `TABLE(user_id, email, full_name, role, entity_id, location_id, employee_id, is_active, last_sign_in_at, is_pending, grant_id)` |
| `admin_grant_access` | `p_email, p_role, p_entity_id, p_location_id, p_employee_id` | O; EA within own entity, never owner | `uuid` (grant id; applied at once if the user exists, else on sign-up) |
| `admin_revoke_access` | `p_user_id` **or** `p_grant_id`, `p_reason` (required) | O; EA own entity, never owner | `void` |

Scope rules for grants: owner → no entity/location/employee; entity_admin → entity, no location;
location_manager → entity + location; staff → entity + employee. Inactive entity/location rejected.
Deactivation is soft (`is_active=false`); dependency summary is for the confirm dialog.

### 3a. Invitations and passwords **[new]**

Logins are never self-created (sign-up stays disabled). The flow is:

1. `admin_grant_access(...)` creates a **pending** `access_grants` row (or applies it at once if a
   login already exists for that email).
2. The Admin UI then calls the **Edge Function `invite-user`** (not an RPC):
   `supabase.functions.invoke('invite-user', { body: { email } })` → `POST /functions/v1/invite-user`
   with the caller's user JWT (`verify_jwt = true`). Source: `supabase/functions/invite-user/index.ts`.
3. The invite email links to `https://hr.thirdstate.ae/set-password`. When the invite creates the auth
   user, the `on_auth_user_created` trigger (`handle_new_user()`) applies the pending grant, so the
   profile/role/scope exist before the person sets a password.

| Function | Body | Roles | Returns |
|---|---|---|---|
| `invite-user` | `{ email }` | O; EA only for a grant whose `entity_id` = own entity. Caller profile must be active. | `200 {status:'invited'\|'already_registered', message}` |

- Grant lookup is by lower-cased email: the pending grant, otherwise the latest **applied** grant (so an
  invite that has not been accepted can be **re-sent**). No such grant → `409 {error:'no_pending_grant'}`
  ("Grant access first").
- A confirmed login already exists → `200 already_registered` (the grant was applied when the login was
  created / when access was granted); nothing is sent.
- Errors are `{error, message}`: `400 invalid_email|bad_request`, `401 unauthenticated`, `403 forbidden`,
  `409 no_pending_grant`, `429 rate_limited` (Supabase email rate limit), `502 invite_failed`.
- On success writes `audit_log` (`table_name='access_grants'`, `record_id` = grant id,
  `action='user_invited'`, `changed_by` = caller, `new_value={email}`, `entity_id/location_id/employee_id`
  from the grant — `entity_id` is NULL for owner grants, which the `audit_log_entity_id_required_check`
  allows for `access_grants`).
- The function performs no other privileged operation; it never changes a role or scope.
- Env: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (or `SUPABASE_SECRET_KEYS.default`) are injected by
  Supabase; optional secret `SITE_URL` (default `https://hr.thirdstate.ae`) sets the redirect base.
  CORS allows `https://hr.thirdstate.ae` and `http://localhost:5173`.

Client-side auth calls (supabase-js, no custom backend):

| Call | Where | Notes |
|---|---|---|
| `auth.resetPasswordForEmail(email, { redirectTo: origin + '/set-password' })` | Sign-in → "Forgot password?" | The UI always shows the same neutral message; it never reveals whether the email has a login |
| `auth.updateUser({ password })` | `/set-password` | Min 8 characters (plus any Supabase password policy). Afterwards the app goes to `/` |

`/set-password` is a public route outside the role gate. It accepts the implicit-flow fragment
(`#access_token…&type=invite|recovery`, parsed by supabase-js, `PASSWORD_RECOVERY` event), a PKCE
`?code=` (`exchangeCodeForSession`) and `?token_hash=&type=` (`verifyOtp`) for custom email templates.
An `#error_code=otp_expired` (or no session) shows "link invalid or expired — ask your manager to resend".

## 4. Employees

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `set_employee_status` | `p_employee_id, p_new_status employee_status, p_reason` | O, EA scoped; LM only pre_boarding→active at own location; never self | `void` |
| `update_employee_details` | `p_employee_id, p_changes jsonb` | O, EA scoped (all whitelisted fields); LM own location (manager fields) | `void` |
| `get_employee_completeness` **[fixed]** | `p_employee_id` | O, EA scoped, LM own location, self | `{percent, missing text[], total, complete}` |
| `bulk_import_employees` | `p_entity_id, p_rows jsonb[]` | O, EA own | `TABLE(row_index, success, employee_id, errors text[])` |
| `decide_employee_change_request` | `p_request_id, p_action 'approve'|'reject', p_decision_reason` | O, EA scoped, LM own location | `void` |

- Status transitions: candidate→pre_boarding|inactive; pre_boarding→active|inactive; active→inactive;
  inactive→active (O/EA). Reason required for inactivate/reactivate. Inactivation deactivates the login and
  cancels future unpublished shifts.
- `update_employee_details` whitelist: `full_name, preferred_name, photo_url, dob, gender, nationality, phone,
  email, emergency_contact_name, emergency_contact_phone, passport_exp, visa_exp, labor_card_exp,
  health_card_exp, employment_type, join_date, probation_end_date, notes, position_id, home_location_id`;
  LM subset: `phone, email, emergency_contact_name, emergency_contact_phone, preferred_name, position_id`.
  Unknown/forbidden keys → 22023/42501. Before/after audited.
- Completeness `missing` values: `contact, emergency_contact, position, join_date, passport_document,
  visa_document, emirates_id_document, contract_document`. (Was raising 22P02 for every employee.)

### 4a. Compensation (pay) **[new, W7]**

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `get_employee_compensation` | `p_employee_id` | O (any entity), EA (own entity). LM/S → `42501` | `{pay_type 'monthly'|'hourly', pay_rate numeric|null, overtime_multiplier, holiday_multiplier, updated_at}` |
| `set_employee_compensation` | `p_employee_id, p_pay_type text, p_pay_rate numeric, p_overtime_multiplier numeric = null, p_holiday_multiplier numeric = null, p_reason text = null` | O (any entity), EA (own entity; not own pay; not an employee linked to an owner login). LM/S → `42501` | `void` |

- Validation (`22023`): `p_pay_type` in `monthly, hourly`; `0 < p_pay_rate < 1,000,000` (AED, max 2 dp);
  multipliers, when given, `1..3` (null keeps the current value, default 1.5 / 2.0); employee not `inactive`;
  `p_reason` required when an existing rate is changed. Unchanged values are a no-op (no audit row).
- Upserts `employee_compensation` and writes `audit_log` action `compensation_changed`
  (`old_value`/`new_value` = pay_type, pay_rate, multipliers; `new_value` also has `reason`, `actor_role`;
  entity/location/employee scope set).
- `employee_compensation.pay_type` defaults to **monthly**. Direct `INSERT/UPDATE/DELETE` on the table is
  revoked from `authenticated`; `SELECT` stays under RLS `comp_access` (O, EA own entity; LM/S see 0 rows).
- Payroll maths (`run_payroll_calculation`): hourly = regular_hours × rate (+ OT/holiday × multipliers when
  confirmed on the run); monthly = the fixed rate per run. A null rate pays AED 0.

## 5. Leave

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `approve_leave_request` | `p_request_id, p_action 'approve'|'reject', p_override bool=false, p_override_reason=null` | O, EA scoped, LM own location; never own request | `jsonb {ok, status, affected_shifts[]}` — on approve, `affected_shifts` lists the employee's non-cancelled shifts inside the leave (`shift_id, shift_date, start_time, end_time, location_id, location, is_published`). They are flagged, not cancelled; the branch managers get a `leave_shift_conflict` notification. |
| `cancel_leave_request` | `p_request_id, p_reason=null` | own / managers | `jsonb` |
| `configure_leave_accrual_policy` | `p_leave_type_id, p_frequency, p_days_per_period, p_rounding, p_max_balance_days, p_carry_forward_cap_days, p_probation_days, p_policy_start_date` | O, EA scoped (entity from leave type) | `uuid` |
| `approve_leave_accrual_policy` | `p_policy_id` | O / EA per function checks | `void` |
| `run_leave_accrual` | `p_leave_type_id, p_period_key` | O, EA | `integer` |
| `grant_leave_balance` | `p_employee_id, p_leave_type_id, p_days, p_reason` | O, EA | `void` |

Submitting (insert into `leave_requests` as pending) reserves balance when available; approval of an
unreserved request needs balance or an O/EA override with reason.

## 6. Documents

`get_documents_for_review(p_entity_id)` **[fixed]** – O: NULL = all entities (was empty); EA/LM: NULL = own
entity; LM rows for restricted types are redacted (`storage_path/notes` NULL, `redacted=true`).
`get_document_expiry_detail(p_entity_id=null, p_bucket='expiring_30_days'|'expired'|'ok')` **[fixed]** – O: NULL = all entities.
`approve_document(p_document_id)`, `reject_document(p_document_id, p_reason)`, `archive_document(p_document_id)` –
O, EA scoped, LM for non-restricted types; never own document. Upload flow:
`stage_document_upload(p_employee_id, p_doc_type, p_file_extension, p_expiry_date, p_notes) → jsonb`,
upload to bucket, `confirm_document_upload(p_document_id)`; renewals
`stage_document_renewal(p_current_document_id, p_file_extension, p_expiry_date=null, p_notes=null, p_upload_method=null) → jsonb {id, storage_path, upload_method}`
(P0-4: same authorisation as `stage_document_upload` — the employee; owner; entity admin in their company; location manager at
their branch for non-restricted types. `upload_method` is derived server-side: `self` for the employee, otherwise `assisted`.
Only the current approved version can be renewed, and only one confirmed renewal may wait for review at a time (`22023`).
The uploader can never reject or archive it; approval follows `can_review_document`).
`delete_pending_document`, `log_document_access(p_document_id, p_action 'preview'|'download')`,
`cleanup_incomplete_document_uploads(p_older_than_hours=24) → int`.

## 7. Scheduling

`publish_schedule_period(p_location_id, p_period_start, p_period_end) → jsonb {published, skipped_leave[]}` (O, EA scoped,
LM own). Draft (`is_published=false`) shifts are never visible to staff. Drafts held by someone on approved leave that day
stay unpublished and are listed in `skipped_leave` (`shift_id, shift_date, start_time, end_time, employee_id, employee`).
A non-cancelled shift cannot be created or moved onto a day its employee has approved leave (trigger `trg_shift_validate`, `22023`). Also:
`create_schedule_template`, `replace_schedule_template`, `deactivate_schedule_template`,
`generate_shifts_from_templates(p_location_id, p_period_start, p_period_end) → int` (skips approved-leave days),
`request_shift_swap(p_shift_id, p_notes) → uuid`, `claim_shift_swap`, `claim_open_shift`,
(P0-2) `claim_shift_swap`, `claim_open_shift` and `approve_shift_swap` (on approve) refuse an ineligible person with
`22023` and a plain reason from `_shift_eligibility` (internal): same company, active and employed that day, role matches
`shifts.position_id`, not on approved leave, not a fixed day off, available, no overlapping shift, ≤ 48 working hours and
≤ their weekly days (work pattern, default 6) in the Mon–Sun week. `claim_open_shift` also needs a published shift.
Staff may claim only at their home branch unless the owner turns on cross-branch claims for the company:
`set_cross_outlet_claims(p_entity_id, p_enabled) → void` (owner only; `app_settings` key `cross_outlet_claims:<entity_id>`).
(P0-6) A published shift can only be changed through `adjust_published_shift` / `cancel_published_shift` (reason required):
trigger `trg_guard_published_shift_update` refuses (`22023`) any signed-in change to its date, times, break, person, branch,
role, status or published flag without `app.shift_adjust_reason`. Notes and drafts are not guarded; internal calls with no JWT
are not guarded. `approve_shift_swap` and `claim_open_shift` record the reasons "Shift swap approved" / "Picked up open shift".
Shift swaps per company: `shift_swaps_enabled(p_entity_id) → boolean` (default true) and
`set_shift_swaps_enabled(p_entity_id, p_enabled) → void` (owner, or entity admin of that company). When off,
`request_shift_swap` / `claim_shift_swap` refuse (`22023`), staff stop seeing the open swap board, and the staff screen hides
all swap controls; managers and admins still see and can decide swaps that were already waiting.
`suggest_shift_cover(p_shift_id) → jsonb {shift, candidates[], not_eligible[]}` (O, EA scoped, LM own branch): candidates are
eligible people ranked home branch first, then fewest hours this week (`employee_id, name, home_location, position,
home_branch, hours_this_week, days_this_week`); `not_eligible` gives each other person's reason.
`cancel_shift_swap_request`, `approve_shift_swap(p_swap_id, p_action)`.

## 8. Payroll & payslips

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `run_payroll_calculation` | `p_payroll_run_id` | O, EA scoped | `void` (draft/in_review only) |
| `create_payroll_revision` | `p_source_run_id` | O, EA scoped | `uuid` (new draft run) |
| `record_timesheet_entry` / `delete_timesheet_entry` | see signature | O, EA (draft runs) | `{ok, …}` |
| `record_payslip_deduction` / `delete_payslip_deduction` | `…, p_deduction_type 'uniform'|'cash_shortage'|'advance'|'other'` | O, EA (draft) | `{ok, …}` |
| `record_tips_pool` / `delete_tips_pool` | see signature | O, EA (draft) | `{ok, …}` |
| `materialize_payroll_from_payable_shifts`, `override_materialized_payable_shift` | see signature | O, EA | `{ok, …}` |
| `add_employees_to_payroll_run` **[new, W7]** | `p_payroll_run_id` | O, EA scoped; LM → `42501` | `integer` = rows added. Draft runs only (`22023` otherwise). Adds a 0-hour timesheet row (notes `Added automatically`) through `record_timesheet_entry` (same checks, `payroll_change_succeeded` audit) for every **active** employee of the run's entity with no row yet and `join_date` null or ≤ `period_end`. Idempotent |
| `get_wps_export_readiness` | `p_payroll_run_id` | O, EA scoped | `TABLE(employee_id, employee_name, missing_labor_card_no, missing_bank_iban, missing_bank_name, net_pay)` |
| `get_my_payslips` **[new]** | – | self (any role with an employee record) | `TABLE(payslip_id, payroll_run_id, period_start, period_end, run_status, version int, is_revision, superseded, published_at, currency, gross_pay, total_deductions, net_pay)` |
| `get_my_payslip` **[new]** | `p_payslip_id` | self, published only | `jsonb` (below) |
| `get_payroll_payslip` **[new, W4]** | `p_payslip_id` | O (any entity), EA (own entity); any run status | same `jsonb` as `get_my_payslip` (`published_at` null until approved); audited `payslip_viewed` with `viewer_role` |

Only employees with a `timesheet_entries` row in the run get a payslip — use `add_employees_to_payroll_run`
so monthly-salaried staff (no hours) are not left out.

Published = run status `approved` or `paid`. LM has no payroll RPC access. Published payslips (and their
deductions/timesheets/tips) are immutable at the DB level (trigger); corrections go through
`create_payroll_revision`.

**Payslip rendering decision:** there is no stored payslip PDF. The UI renders/prints the PDF client-side
from `get_my_payslip`, which returns only the caller's own published payslip (same `P0002 Payslip not found`
for missing / someone else's / unpublished) and writes a `payslip_viewed` audit row.
```json
{ "payslip_id","payroll_run_id","version","is_revision","revises_payroll_run_id","superseded",
  "run_status","period_start","period_end","published_at","generated_at","currency",
  "employer": {"entity_id","name","trade_license_no","emirate"},
  "employee": {"employee_id","full_name","preferred_name","position_title","location_name","employment_type","join_date"},
  "salary":   {"pay_type","pay_rate","overtime_multiplier","holiday_multiplier","regular_hours","overtime_hours","holiday_hours"},
  "earnings": [{"code":"base|overtime|holiday|tips","label","amount"}],
  "allowances": [],
  "deductions": [{"type","amount","notes"}],
  "gross_pay","total_deductions","net_pay" }
```
`allowances` is always `[]`: the schema has no allowance model yet (earnings are base/overtime/holiday/tips).
No bank or identity-document numbers are returned.

## 9. Reporting, audit, settings

| RPC | Args | Roles | Returns |
|---|---|---|---|
| `get_owner_dashboard_kpis` **[fixed, additive key]** | `p_entity_id = null` | O (null = **all entities**), EA (own; other → 42501) | `{entity_id, scope 'entity'|'all_entities', generated_at, headcount{candidate,pre_boarding,active,inactive,total}, document_expiry{expired,expiring_30_days,ok}, document_review_queue, leave{pending_requests,approved_this_month}, payroll{draft_runs,in_review_runs,approved_unpaid_runs,paid_runs}, recruitment{open_requisitions,candidates_in_pipeline}, workflow{active_rules,runs_last_7_days}}` |
| `get_audit_log` | `p_limit=100, p_before, p_table_name, p_action, p_after, p_module, p_actor_id, p_entity_id, p_location_id, p_employee_id` | O all; EA own entity; LM own location (whitelisted actions); S own (whitelisted) | `TABLE(id, table_name, record_id, changed_by, changed_at, action, old_value, new_value, entity_id, location_id, employee_id)` |
| `export_audit_log` | same filters (no limit/5000 cap) | O, EA | same table; the export itself is audited per entity |
| `propose_data_retention_policy` **[additive]** | `p_table_name, p_retention_years, p_disposal_method 'manual_review'|'soft_delete'|'hard_delete', p_legal_basis, p_entity_id uuid = null` | O (**must pass p_entity_id**), EA (own) | `uuid` |
| `approve_data_retention_policy` **[fixed]** | `p_policy_id` | O only, any entity | `void` |

`data_retention_policies` is read directly (PostgREST select, **[fixed W4]**): O reads every entity, EA own entity, LM/S none; SELECT granted to `authenticated` (was missing, so reads failed with 42501). Writes only via the two RPCs above.
| `entity_admin_self_approval_enabled` / `set_entity_admin_self_approval(p_enabled)` | – | read: authenticated; set: O | `boolean` / `void` |

## 10. Notifications

`get_my_notifications(p_limit=50, p_before=null, p_unread_only=false)` → `TABLE(id, notification_type, title,
message, target_type, target_id, priority, read_at, resolved_at, created_at)` (own only);
`mark_notification_read(p_notification_id) → {ok,…}`, `mark_all_notifications_read() → {ok, updated}`,
`unread_notification_count() → int`.

## 11. Recruiting / interviews (unchanged)

`get_my_interviews`, `has_interview_assignments`, `get_interview_detail(p_interview_id) → jsonb`,
`save_interview_feedback_draft`, `submit_interview_feedback`, `reopen_interview_feedback`,
`get_application_interview_feedback`, `close_interview_round`, `cancel_interview`, `reschedule_interview`,
`list_candidate_files_for_interview`, `log_candidate_file_access`, `convert_offer_to_employee` — signatures as in
the DB (see `pg_get_function_arguments`). Interviewer secrecy rules unchanged.

---

## UAT support (postgres only, not callable from the API)

- `select public.uat_fixtures_refresh();` — rebuilds date-relative fixtures in UAT Entity A/B only.
- `select public.uat_purge_seed();` — **pre-go-live**: deletes all UAT Entity A/B data and the uat.* auth users.
  Aborts and deletes nothing if real rows still reference a uat.* user (currently: one Ateej Tea Brew draft job
  requisition created by uat.owner — reassign `created_by` first).
- UAT logins: the 8 `uat.*@example.com` users, password `TSHR-uat-2026!`.
- Negative-access suite: `npm run test:access` (API) and `supabase/tests/access_tests.sql` (rolled-back SQL mirror).


## Scheduled jobs (pg_cron, UTC)

| Job | Schedule | Runs | Notes |
|---|---|---|---|
| `document-expiry-t30-check` | `0 2 * * *` (06:00 Dubai) | `run_document_expiry_workflow_check()` | Documents expiring within 30 days → workflow rules. |
| `daily-hr-reminders` | `0 2 * * *` (06:00 Dubai) | `run_daily_hr_reminders()` | Four independent steps: `onboarding_send_reminders()` (expires invitations, reminds new starters, overdue onboarding tasks, probation reviews), `_imm_reminders(today)` (overdue visa / work-permit steps), `_off_reminders(today)` (overdue offboarding tasks, final settlement due), `_doc_renewal_reminders(today)` (P2-5: document expiry at 60 / 30 / 7 days, on the day, and weekly for 8 weeks after — employee notice with the next step, plus one daily digest per owner / company admin, and per branch manager for non-restricted types; skipped when a new copy is already waiting for review). A failing step is rolled back alone and recorded; the others still run. At most once per Dubai day (`p_force => true` re-runs; notifications are de-duplicated by per-day keys). Each run is logged in `system_job_runs` (owner-readable). System only: no execute grant for signed-in users. |
| `employee-transfers-due` | `5 20 * * *` (00:05 Dubai) | `run_due_employee_transfers()` | Applies scheduled transfers whose date has arrived; one failing transfer is skipped with a warning, the rest still apply. System only. |
| `payroll-readiness-reminders` | `0 4 * * *` (08:00 Dubai) | `run_payroll_readiness_reminders()` | From 3 days before pay day to a week after, daily until every record is approved with nothing blocking: notifies owner, company admins and payroll admins (`payroll_readiness`, high priority from the day before). Also warns when the month hasn't been opened. De-duplicated per day. System only. |
