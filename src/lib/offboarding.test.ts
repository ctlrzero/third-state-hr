import { describe, expect, it } from 'vitest'
import { defaultInitiatedBy, minNoticeDays, noticeDays, settlementDue } from './offboarding'

describe('UAE minimum notice', () => {
  it('probation: employer 14, employee 30 to a UAE employer, 14 leaving the UAE', () => {
    expect(minNoticeDays('termination', 'employer', true, false)).toBe(14)
    expect(minNoticeDays('resignation', 'employee', true, false)).toBe(30)
    expect(minNoticeDays('resignation', 'employee', true, true)).toBe(14)
    expect(minNoticeDays('probation_not_confirmed', 'employer', true, false)).toBe(14)
  })
  it('after probation at least 30 days', () => {
    expect(minNoticeDays('resignation', 'employee', false, true)).toBe(30)
    expect(minNoticeDays('termination', 'employer', false, false)).toBe(30)
  })
  it('no notice for Art. 44, end of contract, mutual, no-show, death', () => {
    for (const t of ['dismissal_art44', 'end_of_contract', 'mutual_agreement', 'no_show', 'death'] as const) expect(minNoticeDays(t, 'employer', false, false)).toBe(0)
  })
})

describe('dates', () => {
  it('counts notice days and the settlement deadline', () => {
    expect(noticeDays('2026-09-27', '2026-10-27')).toBe(30)
    expect(settlementDue('2026-10-27')).toBe('2026-11-10')
    expect(settlementDue('2026-12-25')).toBe('2027-01-08')
  })
  it('defaults who ended it from the type', () => {
    expect(defaultInitiatedBy('resignation')).toBe('employee')
    expect(defaultInitiatedBy('no_show')).toBe('employer')
    expect(defaultInitiatedBy('mutual_agreement')).toBe('mutual')
  })
})
