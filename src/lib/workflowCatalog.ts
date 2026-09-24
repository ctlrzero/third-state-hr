import type { UserRole } from '../types/db'

// Allowed values mirror the workflow_rules CHECK constraints
// (module ∈ leave/document/attendance/schedule/payroll/recruitment,
// operator ∈ eq/neq/gt/gte/lt/lte/contains, action ∈ notify_role/notify_employee)
// and the event_data keys each trigger passes to evaluate_workflow_rules().
// Triggers marked `isNew` are being added by the backend; if the name the
// backend ships differs, this file is the single place to fix it.

export type WorkflowModule = 'leave' | 'document' | 'attendance' | 'schedule' | 'payroll' | 'recruitment'
export type WorkflowOperator = 'eq' | 'neq' | 'gt' | 'gte' | 'lt' | 'lte' | 'contains'
export type WorkflowActionType = 'notify_role' | 'notify_employee'

export interface ConditionFieldDef {
  key: string
  label: string
  /** Noun phrase used in the plain-language summary ("days"). */
  phrase: string
  kind: 'number' | 'text'
}

export interface TriggerDef {
  module: WorkflowModule
  event: string
  label: string
  /** Completes "When …" — e.g. "a leave request is submitted". */
  phrase: string
  fields: ConditionFieldDef[]
  isNew?: boolean
}

export const MODULE_LABEL: Record<WorkflowModule, string> = {
  leave: 'Leave',
  document: 'Documents',
  attendance: 'Attendance',
  schedule: 'Schedules',
  payroll: 'Payroll',
  recruitment: 'Recruiting',
}

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
    fields: [{ key: 'doc_type', label: 'Document type', phrase: 'document type', kind: 'text' }],
  },
  {
    module: 'document',
    event: 'submitted_for_review',
    label: 'Document submitted for review',
    phrase: 'a document is submitted for review',
    fields: [{ key: 'doc_type', label: 'Document type', phrase: 'document type', kind: 'text' }],
    isNew: true,
  },
  {
    module: 'attendance',
    event: 'late_clock_in',
    label: 'Late clock-in',
    phrase: 'an employee clocks in late',
    fields: [{ key: 'late_minutes', label: 'Minutes late', phrase: 'minutes late', kind: 'number' }],
    isNew: true,
  },
  {
    module: 'schedule',
    event: 'schedule_published',
    label: 'Schedule published',
    phrase: 'a schedule is published',
    fields: [{ key: 'shift_date', label: 'Shift date', phrase: 'shift date', kind: 'text' }],
  },
  {
    module: 'schedule',
    event: 'shift_adjusted',
    label: 'Shift adjusted',
    phrase: 'a published shift is adjusted',
    fields: [{ key: 'shift_date', label: 'Shift date', phrase: 'shift date', kind: 'text' }],
    isNew: true,
  },
  {
    module: 'payroll',
    event: 'payslip_published',
    label: 'Payslip published',
    phrase: 'a payslip is published',
    fields: [{ key: 'net_pay', label: 'Net pay (AED)', phrase: 'net pay', kind: 'number' }],
    isNew: true,
  },
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

export const ROLE_LABEL: Record<UserRole, string> = {
  owner: 'Owner',
  entity_admin: 'Entity Admin',
  location_manager: 'Location Manager',
  staff: 'Staff',
}

export const TARGET_ROLES: UserRole[] = ['owner', 'entity_admin', 'location_manager']

export function modulesWithTriggers(): WorkflowModule[] {
  return Array.from(new Set(TRIGGERS.map((t) => t.module)))
}

export function triggersFor(module: WorkflowModule | string): TriggerDef[] {
  return TRIGGERS.filter((t) => t.module === module)
}

export function findTrigger(module: string, event: string): TriggerDef | undefined {
  return TRIGGERS.find((t) => t.module === module && t.event === event)
}
