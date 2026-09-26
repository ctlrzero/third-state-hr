import { describe, expect, it } from 'vitest'
import { employeesMissingPay, fmtAed, fmtMultiplier, fmtPayRate, isCompensationChange, validateCompensation, type CompensationDraft } from './compensation'

const draft = (patch: Partial<CompensationDraft> = {}): CompensationDraft => ({
  payType: 'monthly',
  rate: '4500',
  overtimeMultiplier: '1.5',
  holidayMultiplier: '2',
  reason: '',
  ...patch,
})
const unset = { pay_type: 'monthly' as const, pay_rate: null, overtime_multiplier: 1.5, holiday_multiplier: 2 }
const set4500 = { ...unset, pay_rate: 4500 }

describe('rate formatting', () => {
  it('formats monthly and hourly rates in AED', () => {
    expect(fmtPayRate('monthly', 4500)).toBe('AED 4,500.00 / month')
    expect(fmtPayRate('hourly', 25)).toBe('AED 25.00 / hour')
    expect(fmtPayRate('hourly', 25.5)).toBe('AED 25.50 / hour')
    expect(fmtPayRate('monthly', 123456.7)).toBe('AED 123,456.70 / month')
  })
  it('shows "Not set" without a rate', () => {
    expect(fmtPayRate('monthly', null)).toBe('Not set')
    expect(fmtPayRate('hourly', undefined)).toBe('Not set')
  })
  it('formats amounts and multipliers', () => {
    expect(fmtAed(0)).toBe('AED 0.00')
    expect(fmtAed(null)).toBe('—')
    expect(fmtMultiplier(1.5)).toBe('1.5×')
    expect(fmtMultiplier(2)).toBe('2×')
  })
})

describe('validateCompensation', () => {
  it('accepts a first monthly salary without a reason', () => {
    const r = validateCompensation(draft(), unset)
    expect(r.errors).toEqual({})
    expect(r.value).toEqual({ pay_type: 'monthly', pay_rate: 4500, overtime_multiplier: 1.5, holiday_multiplier: 2, reason: null })
  })
  it('accepts thousands separators and 2 decimals', () => {
    expect(validateCompensation(draft({ rate: '4,500.50' }), unset).value?.pay_rate).toBe(4500.5)
    expect(validateCompensation(draft({ rate: '4500.10' }), unset).value?.pay_rate).toBe(4500.1)
  })
  it('rejects missing, zero, negative, non-numeric, too large and >2dp rates', () => {
    for (const rate of ['', '0', '-5', 'abc', '1000000', '25.125', '1e3']) {
      const r = validateCompensation(draft({ rate }), unset)
      expect(r.value, rate).toBeNull()
      expect(r.errors.rate, rate).toBeTruthy()
    }
    expect(validateCompensation(draft({ rate: '999999.99' }), unset).value).not.toBeNull()
  })
  it('bounds multipliers to 1..3 and defaults blanks', () => {
    expect(validateCompensation(draft({ overtimeMultiplier: '3.5' }), unset).errors.overtimeMultiplier).toBeTruthy()
    expect(validateCompensation(draft({ holidayMultiplier: '0.5' }), unset).errors.holidayMultiplier).toBeTruthy()
    const r = validateCompensation(draft({ overtimeMultiplier: '', holidayMultiplier: '' }), null)
    expect(r.value?.overtime_multiplier).toBe(1.5)
    expect(r.value?.holiday_multiplier).toBe(2)
  })
  it('requires a reason when changing an existing rate', () => {
    expect(validateCompensation(draft({ rate: '5000' }), set4500).errors.reason).toBeTruthy()
    expect(validateCompensation(draft({ rate: '5000', reason: 'Annual raise' }), set4500).value?.reason).toBe('Annual raise')
  })
  it('flags a save with no changes', () => {
    expect(validateCompensation(draft(), set4500).errors.rate).toBe('Nothing has changed.')
  })
  it('treats a pay type switch as a change', () => {
    expect(isCompensationChange(set4500, { pay_type: 'hourly', pay_rate: 4500, overtime_multiplier: 1.5, holiday_multiplier: 2 })).toBe(true)
    expect(isCompensationChange(set4500, { pay_type: 'monthly', pay_rate: 4500, overtime_multiplier: 1.5, holiday_multiplier: 2 })).toBe(false)
  })
})

describe('employeesMissingPay', () => {
  it('lists employees without a positive rate, sorted', () => {
    expect(
      employeesMissingPay(
        [
          { employee_id: 'a', name: 'Zara' },
          { employee_id: 'b', name: 'Ali' },
          { employee_id: 'c', name: 'Maya' },
          { employee_id: 'd', name: 'Omar' },
        ],
        [
          { employee_id: 'a', pay_rate: null },
          { employee_id: 'c', pay_rate: 4500 },
          { employee_id: 'd', pay_rate: 0 },
        ]
      )
    ).toEqual(['Ali', 'Omar', 'Zara'])
  })
})
