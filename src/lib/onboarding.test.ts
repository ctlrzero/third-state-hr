import { describe, expect, it } from 'vitest'
import {
  daysBetween,
  employeeOutstanding,
  formatIban,
  groupBlockersByOwner,
  groupBySection,
  isValidUaeIban,
  maxProbationEnd,
  missingProfileFields,
  startsInLabel,
  taskKey,
  validateTemplateTasks,
  type EditableTask,
} from './onboarding'
import type { OnboardingTask } from './api/onboarding'

function task(p: Partial<OnboardingTask>): OnboardingTask {
  return {
    id: p.id ?? Math.random().toString(),
    item_key: 'k',
    item_label: 'Task',
    section: 'profile',
    phase: 'pre_activation',
    kind: 'manual',
    owner_role: 'employee',
    reviewer_role: null,
    status: 'not_started',
    is_required: true,
    is_waivable: true,
    due_date: null,
    review_reason: null,
    depends_on: null,
    ...p,
  }
}

describe('UAE IBAN', () => {
  it('accepts AE + 21 digits with spaces', () => {
    expect(isValidUaeIban('AE07 0331 2345 6789 0123 456')).toBe(true)
    expect(isValidUaeIban('ae070331234567890123456')).toBe(true)
  })
  it('rejects wrong country or length', () => {
    expect(isValidUaeIban('GB07033123456789012345')).toBe(false)
    expect(isValidUaeIban('AE07 0331')).toBe(false)
    expect(isValidUaeIban('AE0703312345678901234567')).toBe(false)
  })
  it('formats in groups of four', () => {
    expect(formatIban('ae070331234567890123456')).toBe('AE07 0331 2345 6789 0123 456')
  })
})

describe('probation cap', () => {
  it('is six months minus a day', () => {
    expect(maxProbationEnd('2026-10-07')).toBe('2027-04-06')
  })
  it('clamps month overflow like Postgres', () => {
    // 31 Aug + 6 months = 28 Feb (non-leap) → last allowed day 27 Feb
    expect(maxProbationEnd('2026-08-31')).toBe('2027-02-27')
  })
})

describe('dates', () => {
  it('counts whole days', () => {
    expect(daysBetween('2026-09-27', '2026-10-07')).toBe(10)
    expect(daysBetween('2026-10-07', '2026-09-27')).toBe(-10)
  })
  it('labels start dates', () => {
    expect(startsInLabel('2026-09-27', '2026-09-27')).toBe('Starts today')
    expect(startsInLabel('2026-09-28', '2026-09-27')).toBe('Starts tomorrow')
    expect(startsInLabel('2026-10-02', '2026-09-27')).toBe('Starts in 5 days')
    expect(startsInLabel('2026-09-25', '2026-09-27')).toBe('Started 2 days ago')
    expect(startsInLabel(null, '2026-09-27')).toBe('No start date')
  })
})

describe('grouping', () => {
  it('orders sections and drops empty ones', () => {
    const g = groupBySection([task({ section: 'payroll' }), task({ section: 'profile' }), task({ section: 'documents' })])
    expect(g.map((s) => s.section)).toEqual(['profile', 'documents', 'payroll'])
    expect(g[0].label).toBe('Personal details')
  })
  it('groups blockers by owner role', () => {
    const g = groupBlockersByOwner([
      { code: 'a', message: 'x', owner_role: 'payroll' },
      { code: 'b', message: 'y', owner_role: 'employee' },
      { code: 'c', message: 'z' },
    ])
    expect(g.map((x) => x.owner)).toEqual(['employee', 'payroll', 'other'])
  })
  it('lists what the employee still owes', () => {
    const out = employeeOutstanding([
      task({ id: '1' }),
      task({ id: '2', status: 'submitted' }),
      task({ id: '3', status: 'approved' }),
      task({ id: '4', owner_role: 'hr' }),
      task({ id: '5', is_required: false }),
      task({ id: '6', phase: 'day_one' }),
      task({ id: '7', status: 'changes_required' }),
    ])
    expect(out.map((t) => t.id)).toEqual(['1', '7'])
  })
})

describe('profile completeness', () => {
  it('names missing required fields', () => {
    expect(missingProfileFields({ phone: '050', dob: '1990-01-01', gender: 'female', nationality: 'India' })).toEqual([
      'Home address in the UAE',
      'Emergency contact name',
      'Emergency contact phone',
    ])
  })
})

const et = (k: string, deps: string[] = [], extra: Partial<EditableTask> = {}): EditableTask => ({
  item_key: k,
  item_label: k,
  kind: 'manual',
  depends_on: deps,
  is_statutory: false,
  is_required: true,
  ...extra,
})

describe('template editor checks', () => {
  it('makes server-safe keys', () => {
    expect(taskKey('Upload the signed contract!')).toBe('upload_the_signed_contract')
    expect(taskKey('   ')).toBe('task')
  })
  it('accepts a valid list', () => {
    expect(validateTemplateTasks([et('a'), et('b', ['a'])])).toEqual([])
  })
  it('finds duplicates, missing links and loops', () => {
    expect(validateTemplateTasks([et('a'), et('a')]).join()).toContain('share the key')
    expect(validateTemplateTasks([et('a', ['zz'])]).join()).toContain('no longer exists')
    expect(validateTemplateTasks([et('a', ['b']), et('b', ['a'])]).join()).toContain('loop')
  })
  it('needs a document / policy for those kinds', () => {
    expect(validateTemplateTasks([et('a', [], { kind: 'document' })]).join()).toContain('which document')
    expect(validateTemplateTasks([et('a', [], { kind: 'acknowledgement' })]).join()).toContain('which policy')
  })
})
