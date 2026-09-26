// Pure helpers for the employee Pay card / drawer. Kept free of React and
// Supabase so they can be unit-tested (see compensation.test.ts). The server
// (set_employee_compensation) re-validates everything below.

export type PayType = 'monthly' | 'hourly'

export interface CompensationView {
  pay_type: PayType
  pay_rate: number | null
  overtime_multiplier: number
  holiday_multiplier: number
  updated_at: string | null
}

export const DEFAULT_OVERTIME_MULTIPLIER = 1.5
export const DEFAULT_HOLIDAY_MULTIPLIER = 2.0
export const MAX_PAY_RATE = 1_000_000

export const PAY_TYPE_LABEL: Record<PayType, string> = {
  monthly: 'Monthly salary',
  hourly: 'Hourly',
}

/** "AED 4,500.00" */
export function fmtAed(amount: number | null | undefined): string {
  if (amount == null || Number.isNaN(Number(amount))) return '—'
  return `AED ${Number(amount).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

/** "AED 4,500.00 / month" or "AED 25.00 / hour"; "Not set" without a rate. */
export function fmtPayRate(payType: string | null | undefined, rate: number | null | undefined): string {
  if (rate == null || Number.isNaN(Number(rate))) return 'Not set'
  return `${fmtAed(rate)} / ${payType === 'hourly' ? 'hour' : 'month'}`
}

/** "1.5×" */
export function fmtMultiplier(m: number | null | undefined): string {
  if (m == null || Number.isNaN(Number(m))) return '—'
  return `${Number(m)}×`
}

export interface CompensationDraft {
  payType: PayType
  rate: string
  overtimeMultiplier: string
  holidayMultiplier: string
  reason: string
}

export type CompensationErrors = Partial<Record<keyof CompensationDraft, string>>

export interface ValidCompensation {
  pay_type: PayType
  pay_rate: number
  overtime_multiplier: number
  holiday_multiplier: number
  reason: string | null
}

function parseNumber(value: string): number | null {
  const s = value.replace(/,/g, '').trim()
  if (!s || !/^\d+(\.\d+)?$/.test(s)) return null
  return Number(s)
}

/**
 * Validate the drawer form against the same rules the RPC enforces.
 * `existing` is the current row: a reason is required when an existing rate
 * is being changed.
 */
export function validateCompensation(
  draft: CompensationDraft,
  existing: Pick<CompensationView, 'pay_type' | 'pay_rate' | 'overtime_multiplier' | 'holiday_multiplier'> | null
): { value: ValidCompensation | null; errors: CompensationErrors } {
  const errors: CompensationErrors = {}
  if (draft.payType !== 'monthly' && draft.payType !== 'hourly') errors.payType = 'Choose monthly or hourly.'

  const rate = parseNumber(draft.rate)
  if (!draft.rate.trim()) errors.rate = 'Enter a rate.'
  else if (rate == null) errors.rate = 'Enter a number, e.g. 4500 or 25.50.'
  else if (rate <= 0) errors.rate = 'Rate must be more than 0.'
  else if (rate >= MAX_PAY_RATE) errors.rate = 'Rate must be less than AED 1,000,000.'
  else if (!/^\d+(\.\d{1,2})?$/.test(draft.rate.replace(/,/g, '').trim())) errors.rate = 'Use at most 2 decimal places.'

  const mult = (raw: string, key: 'overtimeMultiplier' | 'holidayMultiplier', fallback: number) => {
    if (!raw.trim()) return fallback
    const n = parseNumber(raw)
    if (n == null || n < 1 || n > 3) {
      errors[key] = 'Must be between 1 and 3.'
      return fallback
    }
    return n
  }
  const ot = mult(draft.overtimeMultiplier, 'overtimeMultiplier', existing?.overtime_multiplier ?? DEFAULT_OVERTIME_MULTIPLIER)
  const hol = mult(draft.holidayMultiplier, 'holidayMultiplier', existing?.holiday_multiplier ?? DEFAULT_HOLIDAY_MULTIPLIER)

  const reason = draft.reason.trim()
  if (Object.keys(errors).length === 0 && rate != null) {
    const changed = isCompensationChange(existing, { pay_type: draft.payType, pay_rate: rate, overtime_multiplier: ot, holiday_multiplier: hol })
    if (!changed) errors.rate = 'Nothing has changed.'
    else if (existing?.pay_rate != null && !reason) errors.reason = 'A reason is required when changing an existing pay rate.'
  }

  if (Object.keys(errors).length > 0 || rate == null) return { value: null, errors }
  return {
    value: { pay_type: draft.payType, pay_rate: rate, overtime_multiplier: ot, holiday_multiplier: hol, reason: reason || null },
    errors,
  }
}

export function isCompensationChange(
  existing: Pick<CompensationView, 'pay_type' | 'pay_rate' | 'overtime_multiplier' | 'holiday_multiplier'> | null,
  next: Pick<ValidCompensation, 'pay_type' | 'pay_rate' | 'overtime_multiplier' | 'holiday_multiplier'>
): boolean {
  if (!existing) return true
  return (
    existing.pay_type !== next.pay_type ||
    Number(existing.pay_rate) !== next.pay_rate ||
    existing.pay_rate == null ||
    Number(existing.overtime_multiplier) !== next.overtime_multiplier ||
    Number(existing.holiday_multiplier) !== next.holiday_multiplier
  )
}

/** Names of employees with no pay rate, sorted, for the payroll warning. */
export function employeesMissingPay(
  employees: { employee_id: string; name: string }[],
  rates: { employee_id: string; pay_rate: number | null }[]
): string[] {
  const withRate = new Set(rates.filter((r) => r.pay_rate != null && Number(r.pay_rate) > 0).map((r) => r.employee_id))
  return employees
    .filter((e) => !withRate.has(e.employee_id))
    .map((e) => e.name)
    .sort((a, b) => a.localeCompare(b))
}
