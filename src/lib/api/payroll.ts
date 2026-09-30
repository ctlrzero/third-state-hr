import { callRpc, type ApiResult } from './client'

// Payroll v2. Every action is a SECURITY DEFINER RPC that re-checks the
// caller's payroll permission and company; tables are read-only to the app.
// Bulk actions return a BulkResult so the UI can show what happened to
// each selected employee.

export type RecordStatus = 'draft' | 'in_review' | 'approved' | 'not_prepared'
export type PaymentStatus = 'not_approved' | 'unpaid' | 'partial' | 'paid' | 'failed' | 'overpaid'
export type Severity = 'blocking' | 'warning' | 'info'
export type PaymentMethod = 'bank_transfer' | 'cash' | 'cheque' | 'exchange_house' | 'wps_agent'
export type ApprovalMode = 'two_step' | 'owner_single_step' | 'review_then_approve'
export type TipMethod = 'equal' | 'hours' | 'role_points' | 'hours_points'
export type TipSettlement = 'payroll' | 'cash_paid'

export interface Attention {
  code: string
  severity: Severity
  message: string
  impact?: number
}

export interface Skipped {
  id: string
  name: string | null
  reason: string
}

export interface BulkResult {
  ok: boolean
  preview?: boolean
  processed: number
  created?: number
  total?: number
  impact?: number
  skipped: Skipped[]
  items?: { id: string; name: string; amount: number }[]
  reason?: string
}

export interface PayrollRow {
  record_id: string
  employee_id: string
  name: string
  branch: string | null
  location_id: string | null
  position: string | null
  pay_type: 'monthly' | 'hourly' | null
  record_status: Exclude<RecordStatus, 'not_prepared'>
  calc_version: number
  approved_version: number | null
  fixed_pay: number
  extra_earnings: number
  gross: number
  deductions: number
  net: number
  paid: number
  outstanding: number | null
  payment_status: PaymentStatus
  failed_attempts: number
  published_at: string | null
  attention: Attention[]
  is_correction: boolean
  returned_reason: string | null
  hours_status: 'pending' | 'confirmed' | null
  in_active_export: boolean
}

export interface NotPreparedRow {
  employee_id: string
  name: string
  branch: string | null
  location_id: string | null
  record_status: 'not_prepared'
}

export interface PayrollPeriod {
  id: string
  entity_id: string
  kind: 'regular' | 'off_cycle'
  period_start: string
  period_end: string
  label: string | null
  /** Stored pay date (null = worked out from the pay-day setting). */
  pay_date?: string | null
  publish_payslips_at?: string | null
  publish_requires_paid?: boolean
  /** Salary month of a one-off (off-cycle) run. */
  for_month?: string | null
}

export interface Workspace {
  period: PayrollPeriod
  /** Effective pay date and the salary month in words. */
  pay_date?: string | null
  title?: string | null
  entity: { id: string; name: string; currency: string }
  settings: { approval_mode: ApprovalMode; confirmed: boolean; pay_day: number; default_payment_method: PaymentMethod }
  permissions: { prepare: boolean; approve: boolean; pay: boolean; settings: boolean; single_step: boolean; user_id: string }
  rows: PayrollRow[]
  not_prepared: NotPreparedRow[]
  summary: {
    employees: number
    not_prepared: number
    total_net: number
    approved_net: number
    paid: number
    outstanding: number
    needs_attention: number
    draft: number
    in_review: number
    approved: number
    published: number
  }
  tip_pools: {
    id: string
    location: string
    location_id: string
    pool_start: string
    pool_end: string
    total_amount: number
    settlement: TipSettlement
    method: TipMethod
    employees: number
  }[]
  exports: { id: string; created_at: string; total: number; employees: number; invalidated_at: string | null; invalidated_reason: string | null }[]
}

export interface PayrollLine {
  id: string
  kind: 'earning' | 'deduction' | 'info'
  code: string
  label: string
  quantity: number | null
  rate: number | null
  amount: number
  source_type: string
  source_id: string | null
  explanation: string
}

export interface PaymentRow {
  id: string
  record_id: string
  amount: number
  paid_on: string
  method: PaymentMethod
  reference: string | null
  status: 'recorded' | 'failed'
  failure_reason: string | null
  created_at: string
}

export interface CompensationVersion {
  id: string
  effective_from: string
  pay_type: 'monthly' | 'hourly'
  basic_monthly: number | null
  hourly_rate: number | null
  overtime_eligible: boolean
  reason: string | null
}

export interface CompensationComponent {
  id: string
  kind: 'earning' | 'deduction'
  code: string
  label: string
  monthly_amount: number
  prorate: boolean
  effective_from: string
  effective_to: string | null
}

export interface Adjustment {
  id: string
  kind: 'earning' | 'deduction'
  code: string
  amount: number
  reason: string
  allocation: string
  created_at: string
  voided_at: string | null
  void_reason: string | null
}

export interface Advance {
  id: string
  amount: number
  disbursed_on: string
  disbursement_method: string
  repayment_start: string
  instalments: number
  instalment_amount: number
  status: 'active' | 'settled' | 'cancelled'
  reason: string
  outstanding: number
}

export interface HoursRow {
  id: string
  regular_hours: number
  overtime_hours: number
  night_overtime_hours: number
  holiday_hours: number
  status: 'pending' | 'confirmed'
  source: 'manual' | 'attendance'
  notes: string | null
}

export interface RecordDetail {
  row: PayrollRow
  record: { id: string; correction_reason: string | null; supersedes_record_id: string | null; calculated_at: string | null }
  period: PayrollPeriod
  employee: {
    id: string
    name: string
    join_date: string | null
    last_working_date: string | null
    probation_end_date: string | null
    employment_status: string
    nationality: string | null
  }
  lines: PayrollLine[]
  compensation: CompensationVersion[]
  components: CompensationComponent[]
  hours: HoursRow | null
  adjustments: Adjustment[]
  advances: Advance[]
  payments: PaymentRow[]
  history: { id: string; net: number; status: string; approved_at: string | null; correction_reason: string | null }[]
  audit: { action: string; at: string; by: string | null; new: Record<string, unknown> | null }[]
}

export interface PeriodListItem {
  id: string
  kind: 'regular' | 'off_cycle'
  period_start: string
  period_end: string
  label: string | null
  for_month?: string | null
  title?: string | null
  pay_date?: string | null
  employees: number
  approved: number
  net: number | null
}

export interface PayrollSettings {
  entity_id: string
  effective_from: string
  pay_day: number
  day_rate_basis: 'calendar_days' | 'fixed_30'
  approval_mode: ApprovalMode
  unpaid_leave_basis: 'basic' | 'basic_and_allowances'
  overtime_hour_divisor: number
  overtime_multiplier: number
  night_overtime_multiplier: number
  holiday_multiplier: number
  max_deduction_pct: number
  default_payment_method: PaymentMethod
  payslip_note: string | null
  confirmed: boolean
  can_edit: boolean
  is_owner: boolean
}

export interface TipSplit {
  ok: boolean
  reason?: string
  items: { id: string; name: string; hours: number; points: number; weight: number; amount: number }[]
  skipped: Skipped[]
  total: number
  allocated?: number
  default_points_used?: boolean
  pool_id?: string
}

export interface HoursSheetRow {
  employee_id: string
  name: string
  branch: string | null
  location_id: string | null
  hours: HoursRow | null
  record_status: Exclude<RecordStatus, 'not_prepared'> | null
}

export interface MyPayslipV2 {
  record_id: string
  period_start: string
  period_end: string
  label: string | null
  kind: 'regular' | 'off_cycle'
  /** The salary month in words, e.g. "September 2026" — what staff see (never the admin's run title). */
  title?: string | null
  pay_date?: string | null
  gross: number
  deductions: number
  net: number
  published_at: string
  is_correction: boolean
  superseded: boolean
  currency: string
}

export interface MyPayslipV2Detail {
  record: { id: string; gross: number; deductions: number; net: number; published_at: string; is_correction: boolean; correction_reason: string | null; superseded: boolean }
  period: { start: string; end: string; label: string | null; kind: string; title?: string | null; pay_date?: string | null }
  company: { name: string; currency: string; note: string | null }
  employee: { name: string; position: string | null; branch: string | null; join_date: string | null }
  lines: { kind: 'earning' | 'deduction' | 'info'; code: string; label: string; quantity: number | null; amount: number; explanation: string }[]
  payments: { amount: number; paid_on: string; method: string }[]
}

export type ReportKind = 'register' | 'branch_cost' | 'payments' | 'breakdown'

// ------------------------------------------------------------------ reads
export const canPayroll = (entityId: string, cap: string) =>
  callRpc<boolean>('payroll_can', { p_entity_id: entityId, p_cap: cap })
export const listPeriods = (entityId: string) => callRpc<PeriodListItem[]>('payroll_periods_list', { p_entity_id: entityId })
export const getWorkspace = (periodId: string) => callRpc<Workspace>('payroll_workspace', { p_period_id: periodId })
export const getRecordDetail = (recordId: string) => callRpc<RecordDetail>('payroll_record_detail', { p_record_id: recordId })
export const getHoursSheet = (periodId: string) => callRpc<HoursSheetRow[]>('payroll_hours_sheet', { p_period_id: periodId })
export const getSettings = (entityId: string) => callRpc<PayrollSettings>('payroll_get_settings', { p_entity_id: entityId })
export const getReport = (periodId: string, kind: ReportKind) =>
  callRpc<unknown>('payroll_report', { p_period_id: periodId, p_kind: kind })
export const getMyPayslipsV2 = () => callRpc<MyPayslipV2[]>('payroll_my_payslips')
export const getMyPayslipV2 = (recordId: string) => callRpc<MyPayslipV2Detail>('payroll_my_payslip', { p_record_id: recordId })

// ---------------------------------------------------------------- actions
export const openPeriod = (entityId: string, month: string) =>
  callRpc<string>('payroll_open_period', { p_entity_id: entityId, p_month: month })
export const openOffCycle = (entityId: string, payDate: string, label: string, forMonth?: string | null) =>
  callRpc<string>('payroll_open_off_cycle', { p_entity_id: entityId, p_pay_date: payDate, p_label: label, p_for_month: forMonth ?? null })
export const setPayrollSchedule = (periodId: string, payDate: string | null, publishAt: string | null, requirePaid: boolean) =>
  callRpc<{ ok: boolean; pay_date: string | null; publish_payslips_at: string | null; warning: string | null }>('payroll_set_schedule', {
    p_period_id: periodId,
    p_pay_date: payDate,
    p_publish_at: publishAt,
    p_require_paid: requirePaid,
  })
export const preparePayroll = (periodId: string, employeeIds: string[] | null) =>
  callRpc<BulkResult>('payroll_prepare', { p_period_id: periodId, p_employee_ids: employeeIds })
export const recalculate = (recordIds: string[]) => callRpc<BulkResult>('payroll_recalculate', { p_record_ids: recordIds })
export const setHours = (
  periodId: string,
  employeeId: string,
  h: { regular: number; overtime: number; night: number; holiday: number },
  confirm: boolean,
  notes: string | null,
) =>
  callRpc<{ ok: boolean; reason?: string }>('payroll_set_hours', {
    p_period_id: periodId,
    p_employee_id: employeeId,
    p_regular: h.regular,
    p_overtime: h.overtime,
    p_night_overtime: h.night,
    p_holiday: h.holiday,
    p_confirm: confirm,
    p_notes: notes,
  })
export const confirmHours = (periodId: string, employeeIds: string[]) =>
  callRpc<BulkResult>('payroll_confirm_hours', { p_period_id: periodId, p_employee_ids: employeeIds })
export const importAttendance = (periodId: string, employeeIds: string[] | null) =>
  callRpc<BulkResult>('payroll_import_attendance', { p_period_id: periodId, p_employee_ids: employeeIds })
export const addAdjustment = (
  periodId: string,
  employeeIds: string[],
  a: { kind: 'earning' | 'deduction'; code: string; amount: number; mode: 'individual' | 'per_employee' | 'distributed'; reason: string },
  preview: boolean,
) =>
  callRpc<BulkResult>('payroll_add_adjustment', {
    p_period_id: periodId,
    p_employee_ids: employeeIds,
    p_kind: a.kind,
    p_code: a.code,
    p_amount: a.amount,
    p_mode: a.mode,
    p_reason: a.reason,
    p_preview: preview,
  })
export const voidAdjustment = (id: string, reason: string) =>
  callRpc<{ ok: boolean; reason?: string }>('payroll_void_adjustment', { p_adjustment_id: id, p_reason: reason })
export const submitForReview = (recordIds: string[]) => callRpc<BulkResult>('payroll_submit_for_review', { p_record_ids: recordIds })
export const approve = (items: { record_id: string; calc_version: number }[], preview: boolean) =>
  callRpc<BulkResult>('payroll_approve', { p_items: items, p_preview: preview })
export const returnToDraft = (recordIds: string[], reason: string) =>
  callRpc<BulkResult>('payroll_return_to_draft', { p_record_ids: recordIds, p_reason: reason })
export const createCorrection = (recordId: string, reason: string) =>
  callRpc<{ ok: boolean; reason?: string; record_id?: string }>('payroll_create_correction', { p_record_id: recordId, p_reason: reason })
export const publish = (recordIds: string[]) => callRpc<BulkResult>('payroll_publish', { p_record_ids: recordIds })
export const createExport = (recordIds: string[]) =>
  callRpc<{
    ok: boolean
    reason?: string
    export_id?: string
    total?: number
    rows?: { record_id: string; employee_id: string; name: string; branch: string | null; amount: number; already_paid: number }[]
    skipped: Skipped[]
  }>('payroll_create_export', { p_record_ids: recordIds })
export const recordPayments = (
  items: { record_id: string; amount: number | null }[],
  p: { paidOn: string; method: PaymentMethod; reference: string; status: 'recorded' | 'failed'; failureReason: string | null; requestKey: string },
  preview: boolean,
) =>
  callRpc<BulkResult>('payroll_record_payments', {
    p_items: items,
    p_paid_on: p.paidOn,
    p_method: p.method,
    p_reference: p.reference,
    p_status: p.status,
    p_request_key: p.requestKey,
    p_failure_reason: p.failureReason,
    p_preview: preview,
  })

export interface TipInput {
  periodId: string
  locationId: string
  start: string
  end: string
  amount: number
  settlement: TipSettlement
  method: TipMethod
  employeeIds: string[]
}
const tipArgs = (t: TipInput) => ({
  p_period_id: t.periodId,
  p_location_id: t.locationId,
  p_start: t.start,
  p_end: t.end,
  p_amount: t.amount,
  p_settlement: t.settlement,
  p_method: t.method,
  p_employee_ids: t.employeeIds,
})
export const previewTips = (t: TipInput) => callRpc<TipSplit>('payroll_tip_preview', tipArgs(t))
export const confirmTips = (t: TipInput, notes: string | null) =>
  callRpc<TipSplit>('payroll_tip_confirm', { ...tipArgs(t), p_notes: notes })
export const voidTips = (poolId: string, reason: string) =>
  callRpc<{ ok: boolean; reason?: string }>('payroll_tip_void', { p_pool_id: poolId, p_reason: reason })
export const setRolePoints = (positionId: string, points: number | null) =>
  callRpc<null>('payroll_set_role_points', { p_position_id: positionId, p_points: points })

export const createAdvance = (a: {
  employeeId: string
  amount: number
  disbursedOn: string
  method: string
  repaymentStart: string
  instalments: number
  reason: string
}) =>
  callRpc<{ ok: boolean; advance_id: string; instalment_amount: number; note: string | null }>('payroll_create_advance', {
    p_employee_id: a.employeeId,
    p_amount: a.amount,
    p_disbursed_on: a.disbursedOn,
    p_method: a.method,
    p_repayment_start: a.repaymentStart,
    p_instalments: a.instalments,
    p_reason: a.reason,
  })
export const cancelAdvance = (id: string, reason: string) =>
  callRpc<{ ok: boolean; reason?: string }>('payroll_cancel_advance', { p_advance_id: id, p_reason: reason })

export const setCompensation = (c: {
  employeeId: string
  effectiveFrom: string
  payType: 'monthly' | 'hourly'
  basicMonthly: number | null
  hourlyRate: number | null
  overtimeEligible: boolean
  reason: string | null
}) =>
  callRpc<{ ok: boolean; version_id: string }>('payroll_set_compensation', {
    p_employee_id: c.employeeId,
    p_effective_from: c.effectiveFrom,
    p_pay_type: c.payType,
    p_basic_monthly: c.basicMonthly,
    p_hourly_rate: c.hourlyRate,
    p_overtime_eligible: c.overtimeEligible,
    p_reason: c.reason,
  })
export const addComponent = (c: {
  employeeId: string
  kind: 'earning' | 'deduction'
  code: string
  label: string
  amount: number
  prorate: boolean
  from: string
  to: string | null
  reason: string | null
}) =>
  callRpc<{ ok: boolean }>('payroll_add_component', {
    p_employee_id: c.employeeId,
    p_kind: c.kind,
    p_code: c.code,
    p_label: c.label,
    p_monthly_amount: c.amount,
    p_prorate: c.prorate,
    p_effective_from: c.from,
    p_effective_to: c.to,
    p_reason: c.reason,
  })
export const endComponent = (id: string, to: string, reason: string) =>
  callRpc<{ ok: boolean }>('payroll_end_component', { p_component_id: id, p_effective_to: to, p_reason: reason })
export const setLastWorkingDate = (employeeId: string, date: string | null, reason: string) =>
  callRpc<{ ok: boolean }>('payroll_set_last_working_date', { p_employee_id: employeeId, p_date: date, p_reason: reason })
export const gratuityPreview = (employeeId: string, lastDay: string) =>
  callRpc<{ ok: boolean; amount?: number; years?: number; explanation?: string; note?: string; reason?: string }>(
    'payroll_gratuity_preview',
    { p_employee_id: employeeId, p_last_day: lastDay },
  )
export const saveSettings = (entityId: string, effectiveFrom: string, values: Partial<PayrollSettings>) =>
  callRpc<{ ok: boolean }>('payroll_save_settings', { p_entity_id: entityId, p_effective_from: effectiveFrom, p: values })
export const setPermission = (userId: string, entityId: string, preset: 'payroll_admin' | 'accountant' | null, singleStep: boolean) =>
  callRpc<{ ok: boolean }>('payroll_set_permission', {
    p_user_id: userId,
    p_entity_id: entityId,
    p_preset: preset,
    p_single_step: singleStep,
  })

/** Unwrap {ok:false, reason} responses into an error string. */
export function reasonError<T extends { ok?: boolean; reason?: string }>(res: ApiResult<T>): string | null {
  if (res.error) return res.error
  if (res.data && res.data.ok === false) return res.data.reason ?? 'Nothing was changed.'
  return null
}
