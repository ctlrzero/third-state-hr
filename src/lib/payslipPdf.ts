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
  const periodText = p.title
    ? `${p.title}${p.pay_date ? `  ·  paid ${fmtDate(p.pay_date)}` : ''}`
    : `${fmtDate(p.period_start)} - ${fmtDate(p.period_end)}`
  doc.text(R, 60, periodText, { size: 9, color: [0.85, 0.92, 0.9], align: 'right' })

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

  doc.line(L, A4.height - 60, R, A4.height - 60)
  doc.text(L, A4.height - 44, 'Computer-generated payslip from Third State HR. No signature required.', { size: 8, color: MUTED })
  doc.text(R, A4.height - 44, `Generated ${fmtDate(new Date().toISOString())}`, { size: 8, color: MUTED, align: 'right' })

  return doc.toBytes({ title: p.title ? `Payslip ${p.title}` : `Payslip ${p.period_start} to ${p.period_end}` })
}
