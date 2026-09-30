import type { MyPayslipDetail, PayslipLine } from './api/payslips'
import type { Attention, MyPayslipV2Detail, NotPreparedRow, PaymentStatus, PayrollRow, RecordDetail } from './api/payroll'

// Pure helpers for the payroll v2 screens (no React, no network) so they can
// be unit-tested: labels, filtering, selection eligibility, CSV, and mapping
// v2 records onto the existing PDF payslip layout.

export function fmtMoney(n: number | null | undefined, currency = 'AED'): string {
  const v = Number(n ?? 0)
  return `${currency} ${v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

/** "September 2026" or the off-cycle label. */
export function periodLabel(p: { period_start: string; label?: string | null; kind?: string }): string {
  if (p.kind === 'off_cycle' && p.label) return p.label
  const d = new Date(`${p.period_start}T12:00:00Z`)
  return d.toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })
}

/** yyyy-mm-01 for an <input type="month"> value (yyyy-mm). */
export function monthStart(value: string): string {
  return /^\d{4}-\d{2}$/.test(value) ? `${value}-01` : value
}

export const RECORD_STATUS_LABEL: Record<string, string> = {
  not_prepared: 'Not prepared',
  draft: 'Draft',
  in_review: 'In review',
  approved: 'Approved',
}

export const PAYMENT_STATUS_LABEL: Record<PaymentStatus, string> = {
  not_approved: '',
  unpaid: 'Unpaid',
  partial: 'Part paid',
  paid: 'Paid',
  failed: 'Payment failed',
  overpaid: 'Overpaid',
}

export function worstSeverity(att: Attention[] | null | undefined): Attention['severity'] | null {
  if (!att?.length) return null
  if (att.some((a) => a.severity === 'blocking')) return 'blocking'
  if (att.some((a) => a.severity === 'warning')) return 'warning'
  return 'info'
}

export type StatusFilter = 'all' | 'attention' | 'not_prepared' | 'draft' | 'in_review' | 'approved' | 'unpaid' | 'paid'

export type AnyRow = PayrollRow | NotPreparedRow

export function isPrepared(r: AnyRow): r is PayrollRow {
  return r.record_status !== 'not_prepared'
}

export function filterRows(rows: AnyRow[], q: { search: string; branch: string; status: StatusFilter }): AnyRow[] {
  const s = q.search.trim().toLowerCase()
  return rows.filter((r) => {
    if (s && !r.name.toLowerCase().includes(s)) return false
    if (q.branch && r.location_id !== q.branch) return false
    switch (q.status) {
      case 'all':
        return true
      case 'not_prepared':
        return r.record_status === 'not_prepared'
      case 'attention':
        return isPrepared(r) && ['blocking', 'warning'].includes(worstSeverity(r.attention) ?? '')
      case 'unpaid':
        return isPrepared(r) && r.record_status === 'approved' && r.payment_status !== 'paid'
      case 'paid':
        return isPrepared(r) && r.payment_status === 'paid'
      default:
        return r.record_status === q.status
    }
  })
}

export type BulkAction =
  | 'prepare'
  | 'recalculate'
  | 'adjust'
  | 'review'
  | 'approve'
  | 'export'
  | 'pay'
  | 'publish'
  | 'return'
  | 'download'

/**
 * Which of the selected rows an action would touch, with a reason for each
 * one it would not. The server re-checks everything; this only lets the
 * UI show counts and reasons before the user confirms.
 */
export function partitionForAction(rows: AnyRow[], action: BulkAction, opts: { reviewMode: boolean }) {
  const included: AnyRow[] = []
  const excluded: { row: AnyRow; reason: string }[] = []
  for (const r of rows) {
    const reason = exclusionReason(r, action, opts)
    if (reason) excluded.push({ row: r, reason })
    else included.push(r)
  }
  return { included, excluded }
}

function exclusionReason(r: AnyRow, action: BulkAction, opts: { reviewMode: boolean }): string | null {
  if (action === 'prepare') {
    return isPrepared(r) && r.record_status !== 'draft' ? `Already ${RECORD_STATUS_LABEL[r.record_status].toLowerCase()}` : null
  }
  if (!isPrepared(r)) return action === 'adjust' ? null : 'Not prepared yet'
  const blocking = worstSeverity(r.attention) === 'blocking'
  switch (action) {
    case 'recalculate':
    case 'adjust':
      return r.record_status === 'draft' ? null : `${RECORD_STATUS_LABEL[r.record_status]}; return it to draft first`
    case 'review':
      if (r.record_status !== 'draft') return `Already ${RECORD_STATUS_LABEL[r.record_status].toLowerCase()}`
      return blocking ? 'Needs attention' : null
    case 'approve':
      if (r.record_status === 'approved') return 'Already approved'
      if (opts.reviewMode && r.record_status !== 'in_review') return 'Send it for review first'
      return blocking ? 'Needs attention' : null
    case 'export':
    case 'pay':
      if (r.record_status !== 'approved') return 'Not approved'
      return (r.outstanding ?? 0) > 0 ? null : 'Nothing outstanding'
    case 'publish':
      if (r.record_status !== 'approved') return 'Approve it first'
      return r.published_at ? 'Already published' : null
    case 'return':
      if (r.record_status === 'draft') return 'Already draft'
      return r.paid > 0 ? 'Payment recorded; use a correction' : null
    case 'download':
      return null
  }
  return null
}

export function sumBy<T>(rows: T[], f: (r: T) => number | null | undefined): number {
  return Math.round(rows.reduce((a, r) => a + Number(f(r) ?? 0), 0) * 100) / 100
}

/** RFC 4180 CSV. */
export function toCsv(headers: string[], rows: (string | number | null | undefined)[][]): string {
  const cell = (v: string | number | null | undefined) => {
    const s = v == null ? '' : String(v)
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  return [headers, ...rows].map((r) => r.map(cell).join(',')).join('\r\n')
}

export function newRequestKey(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(36).slice(2)}`
}

// -------------------------------------------------------------- PDF adapter
type V2Line = { kind: 'earning' | 'deduction' | 'info'; code: string; label: string; amount: number; explanation: string }

function splitLines(lines: V2Line[]): { earnings: PayslipLine[]; allowances: PayslipLine[]; deductions: PayslipLine[] } {
  const allowanceCodes = new Set(['housing', 'transport', 'food', 'phone', 'other_allowance'])
  const toLine = (l: V2Line): PayslipLine => ({ code: l.code, label: l.label, amount: Number(l.amount), notes: l.explanation })
  return {
    earnings: lines.filter((l) => l.kind === 'earning' && !allowanceCodes.has(l.code)).map(toLine),
    allowances: lines.filter((l) => l.kind === 'earning' && allowanceCodes.has(l.code)).map(toLine),
    deductions: lines.filter((l) => l.kind === 'deduction').map(toLine),
  }
}

/** Staff payslip (payroll_my_payslip) → the layout buildPayslipPdf already draws. */
export function myV2ToPdfData(d: MyPayslipV2Detail): MyPayslipDetail {
  const parts = splitLines(d.lines)
  return {
    payslip_id: d.record.id,
    payroll_run_id: d.record.id,
    version: d.record.is_correction ? 2 : 1,
    is_revision: d.record.is_correction,
    revises_payroll_run_id: null,
    superseded: d.record.superseded,
    run_status: 'approved',
    period_start: d.period.start,
    period_end: d.period.end,
    title: d.period.title ?? null,
    pay_date: d.period.pay_date ?? null,
    published_at: d.record.published_at,
    generated_at: d.record.published_at,
    currency: d.company.currency,
    employer: { entity_id: '', name: d.company.name, trade_license_no: null, emirate: null },
    employee: {
      employee_id: '',
      full_name: d.employee.name,
      preferred_name: null,
      position_title: d.employee.position,
      location_name: d.employee.branch,
      employment_type: null,
      join_date: d.employee.join_date,
    },
    salary: null,
    ...parts,
    gross_pay: Number(d.record.gross),
    total_deductions: Number(d.record.deductions),
    net_pay: Number(d.record.net),
  }
}

/** Admin record detail → PDF data (for downloads from the payroll screen). */
export function detailToPdfData(d: RecordDetail, company: { name: string; currency: string }): MyPayslipDetail {
  return myV2ToPdfData({
    record: {
      id: d.record.id,
      gross: d.row.gross,
      deductions: d.row.deductions,
      net: d.row.net,
      published_at: d.row.published_at ?? '',
      is_correction: d.row.is_correction,
      correction_reason: d.record.correction_reason,
      superseded: false,
    },
    period: { start: d.period.period_start, end: d.period.period_end, label: d.period.label, kind: d.period.kind },
    company: { name: company.name, currency: company.currency, note: null },
    employee: { name: d.employee.name, position: d.row.position, branch: d.row.branch, join_date: d.employee.join_date },
    lines: d.lines,
    payments: [],
  })
}
