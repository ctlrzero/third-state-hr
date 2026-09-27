import type { UserRole } from '../types/db'

// Mirrors what the DB accepts exactly (docs/API_CONTRACT.md §2 and
// public.workflow_trigger_catalog()): modules from workflow_rules_module_check,
// trigger events + event-data keys from the catalog, operators from
// workflow_rules_condition_operator_check. create_workflow_rule rejects a
// condition field not listed for its trigger (22023).
//
// Only fields that make sense to a person building a rule are offered as
// conditions; ids (employee_id, shift_id, …) are omitted from the builder.
// The page also loads workflow_trigger_catalog() at runtime and hides any
// trigger/field this static list has that the live DB does not.

export type WorkflowModule = 'leave' | 'document' | 'attendance' | 'schedule' | 'payroll' | 'recruitment' | 'onboarding' | 'offboarding'
export type WorkflowOperator = 'eq' | 'neq' | 'gt' | 'gte' | 'lt' | 'lte' | 'contains'
export type WorkflowActionType = 'notify_role' | 'notify_employee'

export interface ConditionFieldDef {
  key: string
  label: string
  /** Noun phrase used in the plain-language summary ("days"). */
  phrase: string
  kind: 'number' | 'text' | 'date' | 'boolean' | 'enum'
  options?: { value: string; label: string }[]
}

export interface TriggerDef {
  module: WorkflowModule
  event: string
  label: string
  /** Completes "When …" — e.g. "a leave request is submitted". */
  phrase: string
  fields: ConditionFieldDef[]
}

export const MODULE_LABEL: Record<WorkflowModule, string> = {
  leave: 'Leave',
  document: 'Documents',
  attendance: 'Attendance',
  schedule: 'Schedules',
  payroll: 'Payroll',
  recruitment: 'Recruiting',
  onboarding: 'Onboarding',
  offboarding: 'Offboarding',
}

const YES_NO = [
  { value: 'true', label: 'Yes' },
  { value: 'false', label: 'No' },
]

export const SHIFT_CHANGE_TYPES = [
  { value: 'cancelled', label: 'Cancelled' },
  { value: 'unpublished', label: 'Unpublished' },
  { value: 'reassigned', label: 'Reassigned' },
  { value: 'date_changed', label: 'Date changed' },
  { value: 'location_changed', label: 'Branch changed' },
  { value: 'time_changed', label: 'Time changed' },
]

const ONBOARDING_TRIGGERS: TriggerDef[] = [
  {
    module: 'onboarding',
    event: 'onboarding_started',
    label: 'Onboarding started',
    phrase: 'onboarding starts for a new hire',
    fields: [
      {
        key: 'source',
        label: 'Started from',
        phrase: 'source',
        kind: 'enum',
        options: [
          { value: 'offer', label: 'Accepted offer' },
          { value: 'direct_hire', label: 'Direct hire' },
          { value: 'existing_employee', label: 'Existing employee' },
        ],
      },
    ],
  },
  {
    module: 'onboarding',
    event: 'onboarding_section_submitted',
    label: 'New starter submitted a section',
    phrase: 'a new starter submits a section for review',
    fields: [{ key: 'section', label: 'Section', phrase: 'section', kind: 'text' }],
  },
  { module: 'onboarding', event: 'onboarding_changes_required', label: 'Changes requested from a new starter', phrase: 'changes are requested from a new starter', fields: [] },
  {
    module: 'onboarding',
    event: 'onboarding_ready_for_activation',
    label: 'New starter ready to activate',
    phrase: 'a new starter is ready to activate',
    fields: [{ key: 'proposed_start_date', label: 'Start date (YYYY-MM-DD)', phrase: 'start date', kind: 'date' }],
  },
  { module: 'onboarding', event: 'employee_activated', label: 'Employee activated', phrase: 'a new starter is activated', fields: [] },
  {
    module: 'onboarding',
    event: 'onboarding_task_overdue',
    label: 'Onboarding tasks overdue',
    phrase: 'onboarding tasks are overdue',
    fields: [
      { key: 'days_overdue', label: 'Days overdue', phrase: 'days overdue', kind: 'number' },
      {
        key: 'owner_role',
        label: 'Owner',
        phrase: 'owner',
        kind: 'enum',
        options: [
          { value: 'location_manager', label: 'Branch manager' },
          { value: 'hr', label: 'HR' },
          { value: 'payroll', label: 'Payroll' },
          { value: 'approver', label: 'Approver' },
        ],
      },
    ],
  },
  {
    module: 'onboarding',
    event: 'probation_review_due',
    label: 'Probation review due',
    phrase: 'a probation review is due',
    fields: [{ key: 'days_to_due', label: 'Days until due', phrase: 'days until due', kind: 'number' }],
  },
  {
    module: 'onboarding',
    event: 'immigration_step_overdue',
    label: 'Visa / work permit step overdue',
    phrase: 'a visa or work permit step is overdue',
    fields: [{ key: 'days_overdue', label: 'Days overdue', phrase: 'days overdue', kind: 'number' }],
  },
  {
    module: 'offboarding',
    event: 'offboarding_started',
    label: 'Offboarding started',
    phrase: 'an employee starts leaving',
    fields: [
      {
        key: 'separation_type',
        label: 'Type',
        phrase: 'leaving type',
        kind: 'enum',
        options: [
          { value: 'resignation', label: 'Resignation' },
          { value: 'termination', label: 'Termination' },
          { value: 'dismissal_art44', label: 'Dismissal (Art. 44)' },
          { value: 'end_of_contract', label: 'End of contract' },
          { value: 'mutual_agreement', label: 'Mutual agreement' },
          { value: 'probation_not_confirmed', label: 'Probation not confirmed' },
          { value: 'no_show', label: 'No-show' },
          { value: 'retirement', label: 'Retirement' },
        ],
      },
      { key: 'last_working_date', label: 'Last working day (YYYY-MM-DD)', phrase: 'last working day', kind: 'date' },
    ],
  },
  {
    module: 'offboarding',
    event: 'final_settlement_due',
    label: 'Final settlement due',
    phrase: 'a final settlement is due within 3 days',
    fields: [{ key: 'days_to_due', label: 'Days until due', phrase: 'days until due', kind: 'number' }],
  },
]

export const TRIGGERS: TriggerDef[] = [
  {
    module: 'leave',
    event: 'leave_submitted',
    label: 'Leave request submitted',
    phrase: 'a leave request is submitted',
    fields: [{ key: 'days_requested', label: 'Days requested', phrase: 'days', kind: 'number' }],
  },
  {
    module: 'document',
    event: 'document_expiring_soon',
    label: 'Document expiring within 30 days',
    phrase: 'a staff document is expiring within 30 days',
    fields: [
      { key: 'days_to_expiry', label: 'Days to expiry', phrase: 'days to expiry', kind: 'number' },
      { key: 'doc_type', label: 'Document type', phrase: 'document type', kind: 'text' },
      { key: 'expiry_date', label: 'Expiry date (YYYY-MM-DD)', phrase: 'expiry date', kind: 'date' },
    ],
  },
  {
    module: 'document',
    event: 'submitted_for_review',
    label: 'Document submitted for review',
    phrase: 'a document is submitted for review',
    fields: [
      { key: 'doc_type', label: 'Document type', phrase: 'document type', kind: 'text' },
      { key: 'is_renewal', label: 'Is a renewal', phrase: 'renewal', kind: 'boolean', options: YES_NO },
    ],
  },
  {
    module: 'attendance',
    event: 'late_clock_in',
    label: 'Late clock-in',
    phrase: 'an employee clocks in late',
    fields: [{ key: 'late_minutes', label: 'Minutes late', phrase: 'minutes late', kind: 'number' }],
  },
  {
    module: 'schedule',
    event: 'schedule_published',
    label: 'Schedule published',
    phrase: 'a shift is published',
    fields: [{ key: 'shift_date', label: 'Shift date (YYYY-MM-DD)', phrase: 'shift date', kind: 'date' }],
  },
  {
    module: 'schedule',
    event: 'shift_adjusted',
    label: 'Published shift changed',
    phrase: 'a published shift is changed',
    fields: [
      { key: 'change_type', label: 'Type of change', phrase: 'change type', kind: 'enum', options: SHIFT_CHANGE_TYPES },
      { key: 'shift_date', label: 'Shift date (YYYY-MM-DD)', phrase: 'shift date', kind: 'date' },
    ],
  },
  {
    module: 'payroll',
    event: 'payslip_published',
    label: 'Payslip published',
    phrase: 'a payslip is published',
    fields: [
      { key: 'is_revision', label: 'Is a revision', phrase: 'revision', kind: 'boolean', options: YES_NO },
      { key: 'period_start', label: 'Period start (YYYY-MM-DD)', phrase: 'period start', kind: 'date' },
    ],
  },
  ...ONBOARDING_TRIGGERS,
]


export const OPERATORS: { value: WorkflowOperator; label: string; symbol: string; numericOnly?: boolean }[] = [
  { value: 'eq', label: 'equals', symbol: '=' },
  { value: 'neq', label: 'does not equal', symbol: '≠' },
  { value: 'gt', label: 'is greater than', symbol: '>', numericOnly: true },
  { value: 'gte', label: 'is at least', symbol: '≥', numericOnly: true },
  { value: 'lt', label: 'is less than', symbol: '<', numericOnly: true },
  { value: 'lte', label: 'is at most', symbol: '≤', numericOnly: true },
  { value: 'contains', label: 'contains', symbol: 'contains' },
]

/** Operators that make sense for a field kind. The DB compares gt/lt numerically. */
export function operatorsFor(kind: ConditionFieldDef['kind'] | undefined) {
  if (kind === 'number') return OPERATORS
  if (kind === 'boolean' || kind === 'enum') return OPERATORS.filter((o) => o.value === 'eq' || o.value === 'neq')
  if (kind === 'date') return OPERATORS.filter((o) => o.value === 'eq' || o.value === 'neq')
  return OPERATORS.filter((o) => !o.numericOnly)
}

export const ROLE_LABEL: Record<UserRole, string> = {
  owner: 'Owner',
  entity_admin: 'Entity Admin',
  location_manager: 'Location Manager',
  staff: 'Staff',
}

/** notify_role targets accepted by the DB. LM/staff are filtered to the event's branch. */
export const TARGET_ROLES: UserRole[] = ['owner', 'entity_admin', 'location_manager', 'staff']

export type LiveCatalog = Record<string, Record<string, string[]>>

/** Restrict the static list to what the live catalog reports (null = use static list). */
export function effectiveTriggers(live: LiveCatalog | null): TriggerDef[] {
  if (!live) return TRIGGERS
  return TRIGGERS.filter((t) => Array.isArray(live[t.module]?.[t.event])).map((t) => ({
    ...t,
    fields: t.fields.filter((f) => live[t.module][t.event].includes(f.key)),
  }))
}

export function modulesWithTriggers(triggers: TriggerDef[] = TRIGGERS): WorkflowModule[] {
  return Array.from(new Set(triggers.map((t) => t.module)))
}

export function triggersFor(module: WorkflowModule | string, triggers: TriggerDef[] = TRIGGERS): TriggerDef[] {
  return triggers.filter((t) => t.module === module)
}

export function findTrigger(module: string, event: string): TriggerDef | undefined {
  return TRIGGERS.find((t) => t.module === module && t.event === event)
}
