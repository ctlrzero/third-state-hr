# Payroll v2 — design

Goal: an owner can run monthly payroll quickly, understand every amount, and
correct mistakes without a developer. Bulk and individual processing use the
same records and the same calculation engine.

## Workflow

**Prepare → Approve → Record payments**, with payslip publication separate.

| Record state (per employee) | Meaning | Editable |
|---|---|---|
| `draft` | Calculated, can change | yes |
| `in_review` | Optional stage when the company enables review | no (return to draft) |
| `approved` | Frozen against a calculation version | no |

Payment status is separate: `unpaid`, `partial`, `paid` (derived from recorded
payments; failed attempts never count). Publication is separate: `published_at`.

Approval preference (Payroll Settings):
- `two_step` — preparer and approver must be different users.
- `owner_single_step` — the owner (or a user explicitly granted it) may prepare
  and approve. Explicit setting, off by default.

The monthly workspace is the existing `payroll_runs` row (one per company and
month). Employee records are the existing `payslips` rows, extended. Individual
and bulk actions call the same per-employee functions.

## Data model (additive — old tables stay for history)

| Table | Purpose |
|---|---|
| `payroll_settings` | Per company: period, pay day, day-rate basis (calendar days), approval preference, rounding, default payment method, payslip details, overtime policy. Effective-dated. |
| `compensation_versions` | Effective-dated pay: pay type (monthly/hourly), basic salary or hourly rate, overtime eligibility (separate from pay type), multipliers. Seeded from `employee_compensation`. |
| `compensation_components` | Effective-dated recurring allowances and recurring deductions (housing, transport, food, other). |
| `payslips` (extended) | The employee payroll record: `record_status`, `calc_version`, `approved_version`, `approved_by/at`, `published_at`, gross/deductions/net, `supersedes_payslip_id` for paid corrections, `needs_attention` items. |
| `payroll_lines` | Every earning and deduction on a record with source, quantity, rate, amount and a plain-language explanation. Unique on source so nothing is imported twice. |
| `payroll_adjustments` | One-off earnings/deductions (bonus, reimbursement, correction, cash shortage…) with reason, bulk batch id, and allocation mode. |
| `salary_advances` + `advance_repayments` | Advance amount, disbursement, repayment start, instalments; repayment lines capped at the outstanding balance. |
| `tips_pools` (extended) + `tips_allocations` | Branch pool per period, method (equal / hours / role points / hours × points), cash-paid vs payroll-payable, exact reconciliation. |
| `tip_role_points` | Role points per position. |
| `payroll_payments` | Payment attempts: amount, date, method, reference, `recorded`/`failed`, idempotency key. |
| `payroll_exports` | Payment exports: employees, amounts, created by; invalidated if a record returns to draft. |
| `payroll_permissions` | Payroll role presets per user and company (payroll admin, accountant). Owner/entity admin keep their existing access. |
| `employees.last_working_date` | Leaver proration. |

## Calculation engine

One function, `payroll_calculate_employee(record)`, used by prepare,
recalculate, and individual actions. It rebuilds the record's lines:

1. **Basic** — monthly: effective-dated salary; each compensation version and
   the joining/leaving dates contribute `rate × days ÷ calendar days in month`.
   Hourly: approved payable hours × rate.
2. **Allowances** — effective-dated components, prorated the same way.
3. **Overtime** — only when the employee is overtime-eligible. Approved hours ×
   hourly equivalent × multiplier. Unconfirmed attendance shows a pending item;
   it is never silently dropped.
4. **Unpaid leave** — approved unpaid-leave days in the period × daily rate,
   once per leave day (unique on leave request + date).
5. **Tips** — confirmed allocations payable through payroll only.
6. **Adjustments** — one-off earnings and deductions.
7. **Advance repayments** — scheduled instalment, capped at the outstanding balance.
8. **Net** — gross − deductions, rounded half-up to 2 dp per line; the record
   total is the sum of rounded lines. Negative net is flagged, not allowed to
   approve.

Monthly employees without timesheets are included at their salary; the missing
timesheet shows as an exception with its impact.

## Corrections

- Draft: edit and recalculate freely.
- Approved, unpaid, not exported/paid: authorised users can return to draft
  with a reason; exports are invalidated.
- Paid (fully or partly): create a linked correction record that supersedes the
  original. Outstanding = corrected net − payments already recorded on the
  chain (e.g. 5,200 − 5,000 = 200).

## Permissions (enforced in the database)

| Preset | Can |
|---|---|
| Owner / payroll admin | Compensation, prepare, approve (per setting), corrections, reports, payments |
| Branch manager | Attendance, overtime and tips inputs for their branch; no salary |
| Accountant | Reports, exports, record payments |
| Employee | Own published payslips only |

## Reports

Monthly register, branch cost, payments and outstanding, tips/advances/deductions.

## WPS

Not generated until the bank's or agent's SIF specification is confirmed. The
payment export is labelled "Payment list", never "WPS file".
