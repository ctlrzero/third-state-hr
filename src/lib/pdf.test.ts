import { describe, expect, it } from 'vitest'
import { PdfDoc, pdfString, textWidth } from './pdf'
import { adminPayslipDetail, buildPayslipPdf, money, payslipFilename } from './payslipPdf'
import type { MyPayslipDetail } from './api/payslips'
import { effectiveTriggers, operatorsFor, TRIGGERS } from './workflowCatalog'
import { validateWorkflowDraft, buildWorkflowSummary } from './workflowSummary'
import { allowedStatusMoves, editableFieldsFor } from './api/employees'

const decode = (b: Uint8Array) => Array.from(b, (c) => String.fromCharCode(c)).join('')

describe('pdf writer', () => {
  it('escapes and encodes strings for WinAnsi', () => {
    expect(pdfString('a(b)c\\')).toBe('(a\\(b\\)c\\\\)')
    expect(pdfString('7–9 · é')).toBe('(7-9 \\267 \\351)')
    expect(pdfString('日本')).toBe('(??)')
  })

  it('produces a structurally valid PDF with a correct xref table', () => {
    const doc = new PdfDoc()
    doc.text(40, 40, 'Hello')
    doc.addPage()
    doc.text(40, 40, 'Page 2', { bold: true, align: 'right' })
    const s = decode(doc.toBytes({ title: 'T' }))
    expect(s.startsWith('%PDF-1.4')).toBe(true)
    expect(s.trimEnd().endsWith('%%EOF')).toBe(true)
    expect(s).toContain('/Count 2')
    const startxref = Number(/startxref\n(\d+)/.exec(s)![1])
    expect(s.slice(startxref, startxref + 4)).toBe('xref')
    // every xref offset points at "N 0 obj"
    const entries = s.slice(startxref).split('\n').slice(3).filter((l) => / n $/.test(l))
    entries.forEach((line, i) => {
      const off = Number(line.slice(0, 10))
      expect(s.slice(off, off + `${i + 1} 0 obj`.length)).toBe(`${i + 1} 0 obj`)
    })
  })

  it('measures Helvetica text', () => {
    expect(textWidth('00', 10)).toBeCloseTo(11.12)
  })
})

const sample: MyPayslipDetail = {
  payslip_id: 'abcdef12-0000-0000-0000-000000000000',
  payroll_run_id: 'r1',
  version: 1,
  is_revision: false,
  revises_payroll_run_id: null,
  superseded: false,
  run_status: 'approved',
  period_start: '2026-08-01',
  period_end: '2026-08-31',
  published_at: '2026-09-01T08:00:00Z',
  generated_at: '2026-09-01T08:00:00Z',
  currency: 'AED',
  employer: { entity_id: 'e', name: 'Third State Café LLC', trade_license_no: '123', emirate: 'Dubai' },
  employee: {
    employee_id: 'x',
    full_name: 'Aisha Rahman',
    preferred_name: null,
    position_title: 'Barista',
    location_name: 'Marina',
    employment_type: 'full_time',
    join_date: '2025-01-01',
  },
  salary: { pay_type: 'monthly', pay_rate: 4000, overtime_multiplier: 1.25, holiday_multiplier: 1.5, regular_hours: 160, overtime_hours: 4, holiday_hours: 0 },
  earnings: [
    { code: 'base', label: 'Basic salary', amount: 4000 },
    { code: 'tips', label: 'Tips', amount: 250.5 },
  ],
  allowances: [],
  deductions: [{ type: 'uniform', amount: 50, notes: 'Apron' }],
  gross_pay: 4250.5,
  total_deductions: 50,
  net_pay: 4200.5,
}

describe('payslip pdf', () => {
  it('renders employer, employee and net pay', () => {
    const s = decode(buildPayslipPdf(sample))
    expect(s).toContain('(Third State Caf\\351 LLC)')
    expect(s).toContain('(Aisha Rahman)')
    expect(s).toContain('(AED 4,200.50)')
    expect(s).toContain('(- AED 50.00)')
  })
  it('formats money and filenames', () => {
    expect(money(1234.5, 'AED')).toBe('AED 1,234.50')
    expect(payslipFilename(sample)).toBe('payslip-Aisha-Rahman-2026-08-01_2026-08-31.pdf')
  })
})

describe('workflow catalog alignment', () => {
  it('filters to the live catalog', () => {
    const live = { leave: { leave_submitted: ['employee_id', 'days_requested'] }, attendance: {} }
    const t = effectiveTriggers(live)
    expect(t.map((x) => x.event)).toEqual(['leave_submitted'])
    expect(t[0].fields.map((f) => f.key)).toEqual(['days_requested'])
    expect(effectiveTriggers(null)).toBe(TRIGGERS)
  })
  it('restricts operators by field kind', () => {
    expect(operatorsFor('enum').map((o) => o.value)).toEqual(['eq', 'neq'])
    expect(operatorsFor('text').some((o) => o.value === 'gt')).toBe(false)
    expect(operatorsFor('number')).toHaveLength(7)
  })
  it('validates enum values and summarises with labels', () => {
    const d = {
      name: 'Cancelled shifts',
      module: 'schedule',
      trigger_event: 'shift_adjusted',
      condition_field: 'change_type',
      condition_operator: 'eq',
      condition_value: 'cancelled',
      action_type: 'notify_role',
      action_target_role: 'location_manager' as const,
      action_message_template: 'A shift was cancelled.',
    }
    expect(validateWorkflowDraft(d).ok).toBe(true)
    expect(validateWorkflowDraft({ ...d, condition_value: 'moved' }).errors.condition).toBeTruthy()
    expect(buildWorkflowSummary(d)).toBe('When a published shift is changed and change type = Cancelled, notify Location Manager.')
  })
})

describe('employee permissions', () => {
  it('limits location managers to the manager subset and activation', () => {
    const keys = editableFieldsFor('location_manager').map((f) => f.key)
    expect(keys).toContain('phone')
    expect(keys).not.toContain('full_name')
    expect(keys).not.toContain('home_location_id')
    expect(allowedStatusMoves('location_manager', 'pre_boarding')).toEqual(['active'])
    expect(allowedStatusMoves('location_manager', 'active')).toEqual([])
    expect(allowedStatusMoves('entity_admin', 'inactive')).toEqual(['active'])
    expect(editableFieldsFor('staff')).toEqual([])
  })
})

describe('adminPayslipDetail', () => {
  it('derives earnings and gross from payslip components', () => {
    const d = adminPayslipDetail({
      payslip: {
        id: 'p1',
        payroll_run_id: 'r1',
        employee_id: 'e1',
        base_pay: 3000,
        overtime_pay: 150.25,
        holiday_pay: 0,
        tips_share: 99.75,
        total_deductions: 50,
        net_pay: 3200,
        generated_at: null,
        employees: { full_name: 'Omar' },
      },
      run: { period_start: '2026-08-01', period_end: '2026-08-31', status: 'paid', revises_payroll_run_id: 'r0' },
      employer: { entity_id: 'x', name: 'TSC', trade_license_no: null, emirate: 'Dubai' },
      currency: 'AED',
      deductions: [{ deduction_type: 'advance', amount: 50, notes: null }],
    })
    expect(d.earnings.map((e) => e.code)).toEqual(['base', 'overtime', 'tips'])
    expect(d.gross_pay).toBe(3250)
    expect(d.is_revision).toBe(true)
    expect(d.deductions[0]).toMatchObject({ type: 'advance', amount: 50 })
    expect(decode(buildPayslipPdf(d))).toContain('(AED 3,200.00)')
  })
})
