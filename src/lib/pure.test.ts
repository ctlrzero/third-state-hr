import { describe, expect, it } from 'vitest'
import { buildWorkflowSummary, validateWorkflowDraft } from './workflowSummary'
import { buildImportPreview, canCommitPreview, normaliseDate, parseCsv } from './csvImport'
import { clockButtonModel } from './clockState'
import { canAccessRoute, mobileNavForRole, navForRole } from './nav'
import { isMissingFunction } from './api/client'
import { diffEmployeeChanges } from './api/employees'
import { fmtClockRange, fmtMinutes, fmtTime, fromDubaiLocalInput, toDubaiLocalInput } from './format'

describe('buildWorkflowSummary', () => {
  it('builds the canonical leave example', () => {
    expect(
      buildWorkflowSummary({
        module: 'leave',
        trigger_event: 'leave_submitted',
        condition_field: 'days_requested',
        condition_operator: 'gt',
        condition_value: '3',
        action_type: 'notify_role',
        action_target_role: 'entity_admin',
      })
    ).toBe('When a leave request is submitted and days > 3, notify Entity Admin.')
  })

  it('omits an incomplete condition', () => {
    expect(
      buildWorkflowSummary({
        module: 'attendance',
        trigger_event: 'late_clock_in',
        condition_field: 'late_minutes',
        condition_operator: 'gte',
        condition_value: '',
        action_type: 'notify_role',
        action_target_role: 'location_manager',
      })
    ).toBe('When an employee clocks in late, notify Location Manager.')
  })

  it('quotes text values and uses word operators', () => {
    expect(
      buildWorkflowSummary({
        module: 'document',
        trigger_event: 'submitted_for_review',
        condition_field: 'doc_type',
        condition_operator: 'contains',
        condition_value: 'visa',
        action_type: 'notify_employee',
        action_target_role: null,
      })
    ).toBe('When a document is submitted for review and document type contains "visa", notify the employee.')
  })

  it('falls back gracefully for unknown triggers', () => {
    expect(
      buildWorkflowSummary({
        module: 'x',
        trigger_event: 'custom_thing',
        condition_field: null,
        condition_operator: null,
        condition_value: null,
        action_type: 'notify_role',
        action_target_role: null,
      })
    ).toBe('When custom thing happens, notify ….')
  })
})

describe('validateWorkflowDraft', () => {
  const base = {
    name: 'Long leave',
    module: 'leave',
    trigger_event: 'leave_submitted',
    condition_field: null,
    condition_operator: null,
    condition_value: null,
    action_type: 'notify_role',
    action_target_role: 'entity_admin' as const,
    action_message_template: 'Review this',
  }
  it('accepts a complete draft', () => {
    expect(validateWorkflowDraft(base).ok).toBe(true)
  })
  it('rejects a half-filled condition', () => {
    const r = validateWorkflowDraft({ ...base, condition_field: 'days_requested' })
    expect(r.errors.condition).toBeTruthy()
  })
  it('rejects non-numeric values for number fields', () => {
    const r = validateWorkflowDraft({ ...base, condition_field: 'days_requested', condition_operator: 'gt', condition_value: 'abc' })
    expect(r.errors.condition).toMatch(/number/)
  })
  it('requires a target role for notify_role and a message', () => {
    const r = validateWorkflowDraft({ ...base, action_target_role: null, action_message_template: ' ' })
    expect(r.errors.target).toBeTruthy()
    expect(r.errors.message).toBeTruthy()
  })
})

describe('parseCsv', () => {
  it('handles quotes, escaped quotes, CRLF and blank lines', () => {
    expect(parseCsv('a,b\r\n"x, y","he said ""hi"""\n\n1,2')).toEqual([
      ['a', 'b'],
      ['x, y', 'he said "hi"'],
      ['1', '2'],
    ])
  })
  it('strips a BOM', () => {
    expect(parseCsv('﻿full_name\nA')).toEqual([['full_name'], ['A']])
  })
})

describe('normaliseDate', () => {
  it('accepts ISO and UAE formats', () => {
    expect(normaliseDate('2026-10-01')).toBe('2026-10-01')
    expect(normaliseDate('01/10/2026')).toBe('2026-10-01')
  })
  it('rejects impossible dates', () => {
    expect(normaliseDate('31/02/2026')).toBeNull()
    expect(normaliseDate('tomorrow')).toBeNull()
  })
})

describe('buildImportPreview', () => {
  const branches = [{ id: 'loc-1', name: 'Marina', code: 'MAR' }]
  const positions = [{ id: 'pos-1', name: 'Barista' }]

  it('maps names to ids and passes a clean file', () => {
    const p = buildImportPreview(
      'full_name,email,employment_type,join_date,branch,position\nAisha,a@x.com,Full Time,01/10/2026,mar,barista',
      branches,
      positions
    )
    expect(p.invalidCount).toBe(0)
    expect(p.rows[0].payload).toMatchObject({
      full_name: 'Aisha',
      email: 'a@x.com',
      employment_type: 'full_time',
      join_date: '2026-10-01',
      home_location_id: 'loc-1',
      position_id: 'pos-1',
    })
    expect(canCommitPreview(p)).toBe(true)
  })

  it('flags per-row errors and blocks commit', () => {
    const p = buildImportPreview(
      'full_name,email,branch,employment_type\n,bad,Nowhere,intern\nB,dup@x.com,,\nC,DUP@x.com,,',
      branches,
      positions
    )
    expect(p.rows[0].errors.length).toBe(4)
    expect(p.rows[1].errors[0]).toMatch(/more than once/)
    expect(p.invalidCount).toBe(3)
    expect(canCommitPreview(p)).toBe(false)
  })

  it('requires the full_name header', () => {
    const p = buildImportPreview('email\na@x.com', branches, positions)
    expect(p.headerErrors[0]).toMatch(/full_name/)
    expect(canCommitPreview(p)).toBe(false)
  })

  it('treats unknown columns as a non-blocking warning', () => {
    const p = buildImportPreview('full_name,shoe_size\nA,42', branches, positions)
    expect(p.headerErrors[0]).toMatch(/shoe_size/)
    expect(canCommitPreview(p)).toBe(true)
  })
})

describe('clockButtonModel', () => {
  it('maps each state to the right action', () => {
    expect(clockButtonModel('not_started', false).action).toBe('clock_in')
    expect(clockButtonModel('no_shift', false).action).toBe('clock_in')
    expect(clockButtonModel('clocked_in', false).action).toBe('clock_out')
    expect(clockButtonModel('clocked_out', false)).toMatchObject({ action: null, disabled: true })
    expect(clockButtonModel(null, false).disabled).toBe(true)
  })
  it('disables while saving (double-tap protection)', () => {
    const m = clockButtonModel('clocked_in', true)
    expect(m.disabled).toBe(true)
    expect(m.label).toBe('Clocking out…')
  })
})

describe('nav mapping', () => {
  it('gives location_manager payroll inputs only, never Workflows/Admin', () => {
    const items = navForRole('location_manager')
    const paths = items.map((i) => i.to)
    expect(items.find((i) => i.to === '/payroll')?.label).toBe('Payroll inputs')
    expect(paths).not.toContain('/workflows')
    expect(paths).not.toContain('/admin')
    expect(paths).toContain('/attendance')
    expect(canAccessRoute('location_manager', '/payroll')).toBe(true)
    expect(canAccessRoute('location_manager', '/admin')).toBe(false)
  })
  it('gives staff the 4+More bottom nav', () => {
    const { primary, more } = mobileNavForRole('staff')
    expect(primary.map((i) => i.label)).toEqual(['Home', 'Schedule', 'Clock', 'Leave'])
    expect(more.map((i) => i.label)).toEqual(['Documents', 'Payslips', 'Profile', 'Notifications'])
  })
  it('only shows My Interviews when assigned', () => {
    expect(navForRole('staff').some((i) => i.to === '/my-interviews')).toBe(false)
    expect(navForRole('staff', { hasInterviewAssignments: true }).some((i) => i.to === '/my-interviews')).toBe(true)
  })
  it('admins see Workflows and Admin; staff do not', () => {
    expect(navForRole('entity_admin').map((i) => i.to)).toEqual(expect.arrayContaining(['/workflows', '/admin', '/payroll']))
    expect(canAccessRoute('staff', '/attendance')).toBe(false)
    expect(canAccessRoute('staff', '/clock')).toBe(true)
    expect(canAccessRoute(null, '/')).toBe(false)
  })
})

describe('api helpers', () => {
  it('detects missing functions', () => {
    expect(isMissingFunction({ code: 'PGRST202' })).toBe(true)
    expect(isMissingFunction({ code: '42883' })).toBe(true)
    expect(isMissingFunction({ message: 'Could not find the function public.x' })).toBe(true)
    expect(isMissingFunction({ code: '42501', message: 'permission denied' })).toBe(false)
  })
  it('diffs employee edits', () => {
    expect(diffEmployeeChanges({ phone: '050', email: null, nationality: 'UAE' }, { phone: '051', email: '', nationality: 'UAE ' })).toEqual({
      phone: '051',
    })
  })
})

describe('format', () => {
  it('formats minutes and Dubai times', () => {
    expect(fmtMinutes(450)).toBe('7h 30m')
    expect(fmtMinutes(45)).toBe('45m')
    expect(fmtTime('09:05:00')).toBe('09:05')
    expect(fmtTime('2026-09-25T05:05:00Z')).toBe('09:05')
  })
  it('round-trips datetime-local in Dubai time', () => {
    expect(toDubaiLocalInput('2026-09-25T05:05:00.000Z')).toBe('2026-09-25T09:05')
    expect(fromDubaiLocalInput('2026-09-25T09:05')).toBe('2026-09-25T05:05:00.000Z')
  })
  it('names a missing clock-out instead of rendering a dash', () => {
    expect(fmtClockRange('2026-09-25T08:02:00Z', null)).toBe('12:02 · no clock-out')
    expect(fmtClockRange('2026-09-25T08:02:00Z', '2026-09-25T13:30:00Z')).toBe('12:02–17:30')
    expect(fmtClockRange(null, '2026-09-25T13:30:00Z')).toBe('No clock-in · out 17:30')
    expect(fmtClockRange(null, null)).toBe('—')
  })
})
