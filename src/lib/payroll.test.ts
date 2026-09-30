import { describe, expect, it } from 'vitest'
import { filterRows, monthStart, myV2ToPdfData, partitionForAction, periodLabel, sumBy, toCsv, worstSeverity } from './payroll'
import type { NotPreparedRow, PayrollRow } from './api/payroll'

const base: PayrollRow = {
  record_id: 'r1',
  employee_id: 'e1',
  name: 'Aisha',
  branch: 'Marina',
  location_id: 'l1',
  position: 'Barista',
  pay_type: 'monthly',
  record_status: 'draft',
  calc_version: 1,
  approved_version: null,
  fixed_pay: 5000,
  extra_earnings: 0,
  gross: 5000,
  deductions: 0,
  net: 5000,
  paid: 0,
  outstanding: null,
  payment_status: 'not_approved',
  failed_attempts: 0,
  published_at: null,
  attention: [],
  is_correction: false,
  returned_reason: null,
  hours_status: null,
  in_active_export: false,
}
const row = (o: Partial<PayrollRow>): PayrollRow => ({ ...base, ...o })
const np: NotPreparedRow = { employee_id: 'e9', name: 'New', branch: 'Marina', location_id: 'l1', record_status: 'not_prepared' }

describe('payroll helpers', () => {
  it('labels months and off-cycle runs', () => {
    expect(periodLabel({ period_start: '2026-09-01' })).toBe('September 2026')
    expect(periodLabel({ period_start: '2026-09-20', kind: 'off_cycle', label: 'Final settlement' })).toBe('Final settlement')
    // A one-off run with a salary month shows the month first, then the run's name.
    expect(periodLabel({ period_start: '2026-09-01', kind: 'off_cycle', label: 'Jordan September salary', for_month: '2026-09-01' })).toBe(
      'September 2026 · Jordan September salary'
    )
    expect(monthStart('2026-09')).toBe('2026-09-01')
  })

  it('ranks attention severity', () => {
    expect(worstSeverity([])).toBeNull()
    expect(worstSeverity([{ code: 'a', severity: 'info', message: '' }, { code: 'b', severity: 'blocking', message: '' }])).toBe('blocking')
  })

  it('filters by search, branch and status', () => {
    const rows = [row({ name: 'Aisha' }), row({ record_id: 'r2', name: 'Omar', location_id: 'l2', record_status: 'approved', payment_status: 'unpaid', outstanding: 10 }), np]
    expect(filterRows(rows, { search: 'om', branch: '', status: 'all' }).map((r) => r.name)).toEqual(['Omar'])
    expect(filterRows(rows, { search: '', branch: 'l1', status: 'all' })).toHaveLength(2)
    expect(filterRows(rows, { search: '', branch: '', status: 'unpaid' }).map((r) => r.name)).toEqual(['Omar'])
    expect(filterRows(rows, { search: '', branch: '', status: 'not_prepared' })).toEqual([np])
  })

  it('explains exclusions before a bulk action', () => {
    const rows = [
      row({}),
      row({ record_id: 'r2', record_status: 'approved', outstanding: 0, payment_status: 'paid', paid: 100 }),
      row({ record_id: 'r3', attention: [{ code: 'no_pay', severity: 'blocking', message: '' }] }),
      np,
    ]
    const approve = partitionForAction(rows, 'approve', { reviewMode: false })
    expect(approve.included).toHaveLength(1)
    expect(approve.excluded.map((x) => x.reason)).toEqual(['Already approved', 'Needs attention', 'Not prepared yet'])
    const pay = partitionForAction(rows, 'pay', { reviewMode: false })
    expect(pay.included).toHaveLength(0)
    expect(partitionForAction(rows, 'return', { reviewMode: false }).excluded[1].reason).toBe('Payment recorded; use a correction')
    expect(partitionForAction([row({})], 'approve', { reviewMode: true }).excluded[0].reason).toBe('Send it for review first')
  })

  it('sums money without float drift', () => {
    expect(sumBy([{ a: 0.1 }, { a: 0.2 }], (r) => r.a)).toBe(0.3)
  })

  it('writes RFC 4180 CSV', () => {
    expect(toCsv(['a', 'b'], [['x,y', 'q"t'], [1, null]])).toBe('a,b\r\n"x,y","q""t"\r\n1,')
  })

  it('maps a v2 payslip onto the PDF layout', () => {
    const pdf = myV2ToPdfData({
      record: { id: 'r1', gross: 5500, deductions: 200, net: 5300, published_at: '2026-10-01', is_correction: false, correction_reason: null, superseded: false },
      period: { start: '2026-09-01', end: '2026-09-30', label: null, kind: 'regular' },
      company: { name: 'Third State Cafe', currency: 'AED', note: null },
      employee: { name: 'Aisha', position: 'Barista', branch: 'Marina', join_date: '2025-01-01' },
      lines: [
        { kind: 'earning', code: 'basic', label: 'Basic salary', quantity: 30, amount: 5000, explanation: 'x' },
        { kind: 'earning', code: 'housing', label: 'Housing', quantity: 30, amount: 500, explanation: 'x' },
        { kind: 'deduction', code: 'unpaid_leave', label: 'Unpaid', quantity: 1, amount: 200, explanation: 'x' },
        { kind: 'info', code: 'tips_cash', label: 'Tips paid in cash', quantity: null, amount: 40, explanation: 'x' },
      ],
      payments: [],
    })
    expect(pdf.earnings.map((l) => l.code)).toEqual(['basic'])
    expect(pdf.allowances.map((l) => l.code)).toEqual(['housing'])
    expect(pdf.deductions.map((l) => l.code)).toEqual(['unpaid_leave'])
    expect(pdf.net_pay).toBe(5300)
  })
})
