import type { PaymentMethod } from '../../lib/api/payroll'

export const EARNING_CODES = [
  { value: 'bonus', label: 'Bonus' },
  { value: 'commission', label: 'Commission' },
  { value: 'reimbursement', label: 'Reimbursement' },
  { value: 'correction', label: 'Correction (underpaid)' },
  { value: 'gratuity', label: 'End-of-service gratuity' },
  { value: 'leave_encashment', label: 'Leave encashment' },
  { value: 'notice_pay', label: 'Notice pay' },
  { value: 'other_earning', label: 'Other earning' },
]
export const DEDUCTION_CODES = [
  { value: 'cash_shortage', label: 'Cash shortage' },
  { value: 'uniform', label: 'Uniform' },
  { value: 'damage', label: 'Damage (max 5 days’ wage a month)' },
  { value: 'fine', label: 'Approved fine (max 5% of wage)' },
  { value: 'other_deduction', label: 'Other deduction' },
]
export const PAYMENT_METHODS: { value: PaymentMethod; label: string }[] = [
  { value: 'bank_transfer', label: 'Bank transfer' },
  { value: 'wps_agent', label: 'WPS agent / exchange' },
  { value: 'exchange_house', label: 'Exchange house' },
  { value: 'cash', label: 'Cash' },
  { value: 'cheque', label: 'Cheque' },
]
