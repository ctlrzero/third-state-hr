import type { OnboardingStatus, OnboardingTask, OwnerRole, ReadinessItem, TaskStatus } from './api/onboarding'

// Display helpers for onboarding. Pure (no I/O) so they are unit-tested.
// Every rule here is presentation only — the server decides readiness,
// permissions and transitions.

export const STATUS_LABEL: Record<OnboardingStatus, string> = {
  initiated: 'Setting up',
  awaiting_employee: 'Waiting for employee',
  under_review: 'Under review',
  changes_required: 'Changes required',
  blocked: 'Blocked',
  ready_for_activation: 'Ready to activate',
  activated: 'Activated',
  day_one: 'Day one',
  in_progress: 'First weeks',
  completed: 'Completed',
  cancelled: 'Cancelled',
  withdrawn: 'Withdrawn',
}

export type Tone = 'neutral' | 'info' | 'warning' | 'risk' | 'success'

export const STATUS_TONE: Record<OnboardingStatus, Tone> = {
  initiated: 'neutral',
  awaiting_employee: 'info',
  under_review: 'warning',
  changes_required: 'risk',
  blocked: 'risk',
  ready_for_activation: 'success',
  activated: 'success',
  day_one: 'info',
  in_progress: 'info',
  completed: 'success',
  cancelled: 'neutral',
  withdrawn: 'neutral',
}

export const TASK_STATUS_LABEL: Record<TaskStatus, string> = {
  not_started: 'To do',
  in_progress: 'In progress',
  submitted: 'Waiting for review',
  changes_required: 'Changes required',
  approved: 'Done',
  waived: 'Waived',
  cancelled: 'Cancelled',
}

export const TASK_STATUS_TONE: Record<TaskStatus, Tone> = {
  not_started: 'neutral',
  in_progress: 'info',
  submitted: 'warning',
  changes_required: 'risk',
  approved: 'success',
  waived: 'neutral',
  cancelled: 'neutral',
}

export const OWNER_LABEL: Record<OwnerRole, string> = {
  employee: 'Employee',
  location_manager: 'Branch manager',
  hr: 'HR',
  payroll: 'Payroll',
  approver: 'Approver',
}

export const SECTION_LABEL: Record<string, string> = {
  profile: 'Personal details',
  documents: 'Documents',
  payment: 'Salary payment',
  acknowledgements: 'Policies',
  availability: 'Availability',
  operations: 'Branch setup',
  employment: 'Contract',
  payroll: 'Pay',
  day_one: 'Day one',
  follow_up: 'Follow-up',
}

export const SECTION_ORDER = ['profile', 'documents', 'payment', 'acknowledgements', 'employment', 'availability', 'operations', 'payroll', 'day_one', 'follow_up']

export const PHASE_LABEL = {
  pre_activation: 'Before start',
  day_one: 'Day one',
  initial_period: 'First weeks',
} as const

export const EXCEPTION_TYPES: { value: string; label: string }[] = [
  { value: 'candidate_withdrew', label: 'Candidate withdrew' },
  { value: 'duplicate_identity', label: 'Possible duplicate person' },
  { value: 'start_date_change', label: 'Start date change' },
  { value: 'setup_change', label: 'Branch / job / manager change' },
  { value: 'invitation_problem', label: 'Invitation problem' },
  { value: 'cannot_complete_digitally', label: 'Cannot complete online' },
  { value: 'document_problem', label: 'Document problem' },
  { value: 'compensation_variance', label: 'Pay differs from offer' },
  { value: 'reviewer_unavailable', label: 'Reviewer unavailable' },
  { value: 'no_show', label: 'Did not arrive' },
  { value: 'delayed_start', label: 'Start delayed' },
  { value: 'activation_retry', label: 'Activation problem' },
  { value: 'probation_not_confirmed', label: 'Probation not confirmed' },
  { value: 'other', label: 'Other' },
]

export function exceptionLabel(type: string): string {
  return EXCEPTION_TYPES.find((t) => t.value === type)?.label ?? type.replace(/_/g, ' ')
}

export const OPEN_STATUSES: OnboardingStatus[] = [
  'initiated',
  'awaiting_employee',
  'under_review',
  'changes_required',
  'blocked',
  'ready_for_activation',
]

/** Before activation (setup, portal, reviews). */
export function isPreActivation(s: OnboardingStatus): boolean {
  return OPEN_STATUSES.includes(s)
}

/** After activation and not yet closed. */
export function isPostStart(s: OnboardingStatus): boolean {
  return s === 'activated' || s === 'day_one' || s === 'in_progress'
}

export function isClosed(s: OnboardingStatus): boolean {
  return s === 'completed' || s === 'cancelled' || s === 'withdrawn'
}

export function isTaskDone(s: TaskStatus): boolean {
  return s === 'approved' || s === 'waived' || s === 'cancelled'
}

/** Remove spaces, upper-case. */
export function normaliseIban(v: string): string {
  return v.replace(/\s+/g, '').toUpperCase()
}

/** UAE IBAN: AE + 21 digits (same rule as the database check). */
export function isValidUaeIban(v: string): boolean {
  return /^AE[0-9]{21}$/.test(normaliseIban(v))
}

/** "AE07 0331 2345 …" groups of four for readability. */
export function formatIban(v: string): string {
  return normaliseIban(v).replace(/(.{4})/g, '$1 ').trim()
}

/** Tasks grouped by section in display order, sections without tasks omitted. */
export function groupBySection(tasks: OnboardingTask[]): { section: string; label: string; tasks: OnboardingTask[] }[] {
  const by = new Map<string, OnboardingTask[]>()
  for (const t of tasks) {
    if (!by.has(t.section)) by.set(t.section, [])
    by.get(t.section)!.push(t)
  }
  const keys = [...by.keys()].sort((a, b) => {
    const ia = SECTION_ORDER.indexOf(a)
    const ib = SECTION_ORDER.indexOf(b)
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib)
  })
  return keys.map((k) => ({ section: k, label: SECTION_LABEL[k] ?? k, tasks: by.get(k)! }))
}

/** Blockers grouped by the role that must act. */
export function groupBlockersByOwner(items: ReadinessItem[]): { owner: OwnerRole | 'other'; label: string; items: ReadinessItem[] }[] {
  const order: (OwnerRole | 'other')[] = ['employee', 'hr', 'location_manager', 'payroll', 'approver', 'other']
  const by = new Map<OwnerRole | 'other', ReadinessItem[]>()
  for (const i of items) {
    const k = i.owner_role ?? 'other'
    if (!by.has(k)) by.set(k, [])
    by.get(k)!.push(i)
  }
  return order
    .filter((k) => by.has(k))
    .map((k) => ({ owner: k, label: k === 'other' ? 'Other' : OWNER_LABEL[k], items: by.get(k)! }))
}

/** Whole days from `from` (yyyy-mm-dd) to `to` (yyyy-mm-dd). */
export function daysBetween(from: string, to: string): number {
  const a = Date.UTC(+from.slice(0, 4), +from.slice(5, 7) - 1, +from.slice(8, 10))
  const b = Date.UTC(+to.slice(0, 4), +to.slice(5, 7) - 1, +to.slice(8, 10))
  return Math.round((b - a) / 86_400_000)
}

/** "Starts in 5 days" / "Started 2 days ago" / "Starts today". */
export function startsInLabel(startDate: string | null, today: string): string {
  if (!startDate) return 'No start date'
  const d = daysBetween(today, startDate)
  if (d === 0) return 'Starts today'
  if (d === 1) return 'Starts tomorrow'
  if (d > 1) return `Starts in ${d} days`
  return d === -1 ? 'Started yesterday' : `Started ${-d} days ago`
}

/**
 * The latest probation end date allowed for an extension: six months from
 * the first probation start, minus one day (Decree-Law 33/2021 Art. 9).
 */
export function maxProbationEnd(firstStart: string): string {
  const [y, m, d] = firstStart.split('-').map(Number)
  const end = new Date(Date.UTC(y, m - 1 + 6, d))
  // Month overflow (e.g. 31 Aug + 6 → 3 Mar) clamps to the month's last day, like Postgres.
  if (end.getUTCDate() !== d) end.setUTCDate(0)
  end.setUTCDate(end.getUTCDate() - 1)
  return end.toISOString().slice(0, 10)
}

/** What the employee still owes (their required, not-done pre-activation tasks). */
export function employeeOutstanding(tasks: OnboardingTask[]): OnboardingTask[] {
  return tasks.filter((t) => t.owner_role === 'employee' && t.is_required && t.phase === 'pre_activation' && !isTaskDone(t.status) && t.status !== 'submitted')
}

export const PROFILE_FIELDS: { key: string; label: string; type: 'text' | 'date' | 'tel' | 'select'; required: boolean; options?: string[] }[] = [
  { key: 'preferred_name', label: 'Preferred name', type: 'text', required: false },
  { key: 'phone', label: 'Mobile number', type: 'tel', required: true },
  { key: 'dob', label: 'Date of birth', type: 'date', required: true },
  { key: 'gender', label: 'Gender', type: 'select', required: true, options: ['female', 'male'] },
  { key: 'nationality', label: 'Nationality', type: 'text', required: true },
  { key: 'residential_address', label: 'Home address in the UAE', type: 'text', required: true },
  { key: 'emergency_contact_name', label: 'Emergency contact name', type: 'text', required: true },
  { key: 'emergency_contact_phone', label: 'Emergency contact phone', type: 'tel', required: true },
]

/** Required profile fields still empty (mirrors submit_onboarding_section's check). */
export function missingProfileFields(p: Record<string, string | null | undefined>): string[] {
  return PROFILE_FIELDS.filter((f) => f.required && !String(p[f.key] ?? '').trim()).map((f) => f.label)
}

// ------------------------------------------------------ template editor
/** "Upload the signed contract!" → "upload_the_signed_contract" (the server's key rule). */
export function taskKey(label: string): string {
  return (
    label
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[^a-z0-9]+/g, '_')
      .replace(/^_+|_+$/g, '')
      .slice(0, 40) || 'task'
  )
}

export interface EditableTask {
  item_key: string
  item_label: string
  kind: string
  doc_type?: string | null
  policy_key?: string | null
  depends_on: string[]
  is_statutory: boolean
  is_required: boolean
}

/**
 * Client-side mirror of the server's template checks, so the editor can
 * point at the exact row before saving. The server re-checks everything.
 */
export function validateTemplateTasks(tasks: EditableTask[]): string[] {
  const errs: string[] = []
  if (tasks.length === 0) errs.push('Add at least one task.')
  const keys = new Set<string>()
  for (const t of tasks) {
    if (!t.item_label.trim()) errs.push('Every task needs a name.')
    if (!/^[a-z0-9_]+$/.test(t.item_key)) errs.push(`“${t.item_label}”: key must be lowercase letters, digits and _.`)
    if (keys.has(t.item_key)) errs.push(`Two tasks share the key “${t.item_key}”. Rename one.`)
    keys.add(t.item_key)
    if (t.kind === 'document' && !t.doc_type) errs.push(`“${t.item_label}”: choose which document.`)
    if (t.kind === 'acknowledgement' && !t.policy_key) errs.push(`“${t.item_label}”: choose which policy.`)
  }
  for (const t of tasks) for (const d of t.depends_on) if (!keys.has(d)) errs.push(`“${t.item_label}” waits for a task that no longer exists.`)
  // Loops: depth-first search over depends_on.
  const by = new Map(tasks.map((t) => [t.item_key, t.depends_on]))
  const state = new Map<string, 1 | 2>()
  const visit = (k: string): boolean => {
    if (state.get(k) === 1) return true
    if (state.get(k) === 2) return false
    state.set(k, 1)
    for (const d of by.get(k) ?? []) if (by.has(d) && visit(d)) return true
    state.set(k, 2)
    return false
  }
  if (tasks.some((t) => visit(t.item_key))) errs.push('Some tasks wait for each other in a loop. Remove one of the “waits for” links.')
  return [...new Set(errs)]
}

// ------------------------------------------------ work permit / visa
export const TRACK_LABEL = {
  outside_uae: 'New visa — employee outside the UAE',
  inside_uae: 'New visa — employee already in the UAE (change of status)',
  transfer: 'Transfer from another UAE employer',
  own_visa: 'Has own residence visa (family / golden) — work permit only',
  uae_national: 'UAE national',
  gcc_national: 'GCC national',
} as const
