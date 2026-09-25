import { A4, PdfDoc } from './pdf'
import type { MyPayslipDetail, PayslipLine } from './api/payslips'
import { fmtDate, humanize } from './format'

export function money(amount: number | null | undefined, currency = 'AED'): string {
  const v = Number(amount ?? 0)
  return `${currency} ${v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

export function lineLabel(l: PayslipLine): string {
  if (l.label) return l.label
  return humanize(l.code ?? l.type ?? 'item')
}

export function payslipFilename(p: MyPayslipDetail): string {
  const name = (p.employee?.full_name ?? 'employee').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '')
  return `payslip-${name}-${p.period_start}_${p.period_end}${p.version > 1 ? `-v${p.version}` : ''}.pdf`
}

const INK: [number, number, number] = [0.09, 0.13, 0.2]
const MUTED: [number, number, number] = [0.37, 0.42, 0.48]
const PRIMARY: [number, number, number] = [0.07, 0.25, 0.23]
const SOFT: [number, number, number] = [0.96, 0.97, 0.98]

/** Lay out a single-page A4 payslip from get_my_payslip() data. */
export function buildPayslipPdf(p: MyPayslipDetail): Uint8Array {
  const doc = new PdfDoc()
  const cur = p.currency || 'AED'
  const L = 48
  const R = A4.width - 48

  // Header band
  doc.rect(0, 0, A4.width, 92, PRIMARY)
  doc.text(L, 40, p.employer?.name ?? 'Employer', { size: 16, bold: true, color: [1, 1, 1] })
  const employerMeta = [p.employer?.emirate, p.employer?.trade_license_no && `Trade licence ${p.employer.trade_license_no}`].filter(Boolean).join('  ·  ')
  if (employerMeta) doc.text(L, 60, employerMeta, { size: 9, color: [0.85, 0.92, 0.9] })
  doc.text(R, 40, 'PAYSLIP', { size: 16, bold: true, color: [1, 1, 1], align: 'right' })
  doc.text(R, 60, `${fmtDate(p.period_start)} - ${fmtDate(p.period_end)}`, { size: 9, color: [0.85, 0.92, 0.9], align: 'right' })

  let y = 124
  if (p.is_revision || p.superseded) {
    const note = p.superseded
      ? 'This payslip has been superseded by a later revision.'
      : `Revised payslip (version ${p.version}).`
    doc.rect(L, y - 14, R - L, 22, [1, 0.96, 0.9])
    doc.text(L + 8, y, note, { size: 9, bold: true, color: [0.56, 0.31, 0.02] })
    y += 24
  }

  // Employee block
  const e = p.employee ?? ({} as MyPayslipDetail['employee'])
  const rows: [string, string][] = [
    ['Employee', e.full_name ?? '-'],
    ['Position', e.position_title ?? '-'],
    ['Branch', e.location_name ?? '-'],
    ['Employment type', humanize(e.employment_type)],
    ['Join date', fmtDate(e.join_date)],
    ['Status', humanize(p.run_status)],
    ['Published', fmtDate(p.published_at ?? p.generated_at)],
    ['Reference', `${p.payslip_id.slice(0, 8).toUpperCase()}${p.version > 1 ? ` v${p.version}` : ''}`],
  ]
  const colW = (R - L) / 2
  rows.forEach(([k, v], i) => {
    const cx = L + (i % 2) * colW
    const cy = y + Math.floor(i / 2) * 30
    doc.text(cx, cy, k.toUpperCase(), { size: 7.5, color: MUTED })
    doc.text(cx, cy + 12, v, { size: 10.5, color: INK })
  })
  y += Math.ceil(rows.length / 2) * 30 + 10

  const section = (title: string, lines: PayslipLine[], negative = false) => {
    doc.rect(L, y, R - L, 20, SOFT)
    doc.text(L + 8, y + 14, title, { size: 9.5, bold: true, color: INK })
    doc.text(R - 8, y + 14, 'Amount', { size: 9, bold: true, color: MUTED, align: 'right' })
    y += 34
    if (lines.length === 0) {
      doc.text(L + 8, y, 'None', { size: 10, color: MUTED })
      y += 18
    }
    for (const l of lines) {
      doc.text(L + 8, y, lineLabel(l), { size: 10 })
      if (l.notes) doc.text(L + 160, y, l.notes.slice(0, 60), { size: 8.5, color: MUTED })
      doc.text(R - 8, y, `${negative ? '- ' : ''}${money(l.amount, cur)}`, { size: 10, align: 'right' })
      doc.line(L, y + 6, R, y + 6)
      y += 20
    }
    y += 6
  }

  section('Earnings', p.earnings ?? [])
  if ((p.allowances ?? []).length) section('Allowances', p.allowances)
  section('Deductions', p.deductions ?? [], true)

  // Totals
  const totals: [string, number, boolean][] = [
    ['Gross pay', p.gross_pay, false],
    ['Total deductions', p.total_deductions, false],
  ]
  for (const [k, v] of totals) {
    doc.text(R - 170, y, k, { size: 10, color: MUTED })
    doc.text(R - 8, y, money(v, cur), { size: 10, align: 'right' })
    y += 18
  }
  doc.rect(R - 250, y - 4, 250, 30, PRIMARY)
  doc.text(R - 240, y + 15, 'NET PAY', { size: 10, bold: true, color: [1, 1, 1] })
  doc.text(R - 10, y + 15, money(p.net_pay, cur), { size: 13, bold: true, color: [1, 1, 1], align: 'right' })
  y += 50

  // Hours
  const s = p.salary
  if (s && (s.regular_hours || s.overtime_hours || s.holiday_hours)) {
    doc.text(L, y, 'Hours this period', { size: 9, bold: true, color: MUTED })
    y += 14
    doc.text(
      L,
      y,
      `Regular ${Number(s.regular_hours ?? 0)} h   ·   Overtime ${Number(s.overtime_hours ?? 0)} h   ·   Holiday ${Number(s.holiday_hours ?? 0)} h`,
      { size: 10 }
    )
    y += 20
  }

  doc.line(L, A4.height - 60, R, A4.height - 60)
  doc.text(L, A4.height - 44, 'Computer-generated payslip from Third State HR. No signature required.', { size: 8, color: MUTED })
  doc.text(R, A4.height - 44, `Generated ${fmtDate(new Date().toISOString())}`, { size: 8, color: MUTED, align: 'right' })

  return doc.toBytes({ title: `Payslip ${p.period_start} to ${p.period_end}` })
}

export interface AdminPayslipSource {
  payslip: {
    id: string
    payroll_run_id: string
    employee_id: string
    base_pay: number
    overtime_pay: number
    holiday_pay: number
    tips_share: number
    total_deductions: number
    net_pay: number
    generated_at: string | null
    employees?: { full_name: string } | null
  }
  run: { period_start: string; period_end: string; status: string; approved_at?: string | null; revises_payroll_run_id?: string | null }
  employer: { entity_id: string; name: string; trade_license_no: string | null; emirate: string | null }
  currency: string
  deductions: { deduction_type: string; amount: number; notes: string | null }[]
  hours?: { regular_hours: number; overtime_hours: number; holiday_hours: number } | null
}

/**
 * Owner / Entity Admin view: build the same payslip document from the
 * payroll run screen's own (RLS-scoped) rows, so admins can hand an
 * employee an identical PDF. get_my_payslip() is self-only by design.
 */
export function adminPayslipDetail(src: AdminPayslipSource): MyPayslipDetail {
  const p = src.payslip
  const earnings = [
    { code: 'base', label: 'Basic pay', amount: Number(p.base_pay) },
    { code: 'overtime', label: 'Overtime', amount: Number(p.overtime_pay) },
    { code: 'holiday', label: 'Holiday pay', amount: Number(p.holiday_pay) },
    { code: 'tips', label: 'Tips share', amount: Number(p.tips_share) },
  ].filter((e) => e.amount !== 0 || e.code === 'base')
  const gross = earnings.reduce((s, e) => s + e.amount, 0)
  return {
    payslip_id: p.id,
    payroll_run_id: p.payroll_run_id,
    version: src.run.revises_payroll_run_id ? 2 : 1,
    is_revision: Boolean(src.run.revises_payroll_run_id),
    revises_payroll_run_id: src.run.revises_payroll_run_id ?? null,
    superseded: false,
    run_status: src.run.status,
    period_start: src.run.period_start,
    period_end: src.run.period_end,
    published_at: src.run.approved_at ?? null,
    generated_at: p.generated_at,
    currency: src.currency,
    employer: src.employer,
    employee: {
      employee_id: p.employee_id,
      full_name: p.employees?.full_name ?? 'Employee',
      preferred_name: null,
      position_title: null,
      location_name: null,
      employment_type: null,
      join_date: null,
    },
    salary: src.hours
      ? { pay_type: null, pay_rate: null, overtime_multiplier: null, holiday_multiplier: null, ...src.hours }
      : null,
    earnings,
    allowances: [],
    deductions: src.deductions.map((d) => ({ type: d.deduction_type, label: undefined, amount: Number(d.amount), notes: d.notes })),
    gross_pay: Math.round(gross * 100) / 100,
    total_deductions: Number(p.total_deductions),
    net_pay: Number(p.net_pay),
  }
}
