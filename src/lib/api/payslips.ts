import { callRpc } from './client'

// Staff self-service payslips. Both RPCs resolve the employee from
// auth.uid() and only ever return the caller's own PUBLISHED payslips
// (run status approved/paid); get_my_payslip also writes a payslip_viewed
// audit row. There is no stored PDF — the UI renders one from this data.

export interface MyPayslipListRow {
  payslip_id: string
  payroll_run_id: string
  period_start: string
  period_end: string
  run_status: string
  version: number
  is_revision: boolean
  superseded: boolean
  published_at: string | null
  currency: string
  gross_pay: number
  total_deductions: number
  net_pay: number
}

export interface PayslipLine {
  code?: string
  type?: string
  label?: string
  amount: number
  notes?: string | null
}

export interface MyPayslipDetail {
  payslip_id: string
  payroll_run_id: string
  version: number
  is_revision: boolean
  revises_payroll_run_id: string | null
  superseded: boolean
  run_status: string
  period_start: string
  period_end: string
  /** Salary month in words ("September 2026") and the pay date, when known. */
  title?: string | null
  pay_date?: string | null
  published_at: string | null
  generated_at: string | null
  currency: string
  employer: { entity_id: string; name: string; trade_license_no: string | null; emirate: string | null }
  employee: {
    employee_id: string
    full_name: string
    preferred_name: string | null
    position_title: string | null
    location_name: string | null
    employment_type: string | null
    join_date: string | null
  }
  salary: {
    pay_type: string | null
    pay_rate: number | null
    overtime_multiplier: number | null
    holiday_multiplier: number | null
    regular_hours: number | null
    overtime_hours: number | null
    holiday_hours: number | null
  } | null
  earnings: PayslipLine[]
  allowances: PayslipLine[]
  deductions: PayslipLine[]
  gross_pay: number
  total_deductions: number
  net_pay: number
}

export const getMyPayslips = () => callRpc<MyPayslipListRow[]>('get_my_payslips')
export const getMyPayslip = (payslipId: string) => callRpc<MyPayslipDetail>('get_my_payslip', { p_payslip_id: payslipId })

/** Owner / Entity Admin (own entity): one payslip from the payroll run screen, any run status. Audited. */
export const getPayrollPayslip = (payslipId: string) =>
  callRpc<MyPayslipDetail>('get_payroll_payslip', { p_payslip_id: payslipId })
