import { describe, expect, it } from 'vitest'
import { friendlyError } from './client'

describe('friendlyError', () => {
  it('keeps messages our own functions raise', () => {
    expect(friendlyError({ code: '22023', message: 'This shift has already ended' })).toBe('This shift has already ended')
    expect(friendlyError({ code: '42501', message: 'Only the owner or a company admin can transfer an employee' })).toBe(
      'Only the owner or a company admin can transfer an employee'
    )
  })
  it('replaces raw database and network wording', () => {
    expect(friendlyError({ code: '42501', message: 'new row violates row-level security policy for table "shifts"' })).toBe(
      'You can’t do this. Please ask your manager.'
    )
    expect(friendlyError({ message: 'permission denied for table payroll_records' })).toBe('You can’t do this. Please ask your manager.')
    expect(friendlyError(new Error('TypeError: Failed to fetch'))).toBe('No internet connection. Check your signal and try again.')
    expect(friendlyError({ message: 'JWT expired' })).toBe('Your session has expired. Please sign in again.')
    expect(friendlyError({ message: 'duplicate key value violates unique constraint "x"' })).toBe('This already exists.')
    expect(friendlyError({ message: 'Swap request 3f2a1b4c-1111-4222-8333-444455556666 not found' })).toBe(
      'This item no longer exists. Refresh and try again.'
    )
    expect(friendlyError({ message: 'ERROR: No home location or shift location to clock in at' })).toBe(
      'We can’t tell which branch you work at. Please tell your manager.'
    )
  })
  it('strips the ERROR prefix and falls back for empty or very long text', () => {
    expect(friendlyError({ message: 'ERROR:  Give a reason for the transfer' })).toBe('Give a reason for the transfer')
    expect(friendlyError(null)).toBe('Something went wrong. Please try again.')
    expect(friendlyError({ message: 'x'.repeat(400) })).toBe('Something went wrong. Please try again.')
  })
})
