import { callRpc } from './client'
import type { InitiatedBy, SeparationType } from '../offboarding'

// Offboarding RPCs (migration 013). Branch managers get their checklist and
// dates only; the reason and final-settlement figures are HR / payroll only.

export interface OffboardingRow {
  case_id: string
  employee_id: string
  name: string
  branch: string | null
  separation_type: SeparationType
  notice_date: string
  last_working_date: string
  settlement_due_date: string
  status: 'open' | 'completed' | 'cancelled'
  row_version: number
  open_tasks: number
  overdue_tasks: number
}

export interface OffboardingTask {
  id: string
  item_key: string
  label: string
  owner_role: 'location_manager' | 'hr' | 'payroll'
  is_required: boolean
  status: 'not_started' | 'done' | 'not_needed'
  due_date: string | null
  notes: string | null
  completed_at: string | null
  overdue: boolean
}

export interface OffboardingCase {
  case: {
    id: string
    employee_id: string
    separation_type: SeparationType
    initiated_by: InitiatedBy
    notice_date: string
    last_working_date: string
    in_probation: boolean
    leaving_uae: boolean
    min_notice_days: number
    settlement_due_date: string
    status: OffboardingRow['status']
    row_version: number
    reason?: string
    notice_shortfall_reason?: string | null
    close_notes: string | null
    source_onboarding_instance_id: string | null
  }
  employee: { id: string; name: string; employee_number: string | null; join_date: string | null; employment_status: string; branch: string | null; position: string | null }
  permissions: { manage: boolean; payroll: boolean; operate: boolean }
  notice_days: number
  tasks: OffboardingTask[]
  future_published_shifts: number
  settlement: {
    due_date: string
    gratuity: { ok: boolean; amount?: number; years?: number; explanation?: string; reason?: string; note?: string } | null
    leave_balances: { leave_type: string; balance_days: number }[]
  } | null
  timeline: { action: string; at: string; by: string | null }[] | null
}

export interface StartOffboardingInput {
  employeeId: string
  type: SeparationType
  initiatedBy: InitiatedBy
  noticeDate: string
  lastWorkingDate: string
  reason: string
  leavingUae: boolean
  shortfallReason: string | null
  sourceExceptionId: string | null
}

export const listOffboarding = (entityId: string, status: 'open' | 'completed' | 'cancelled' | 'all' = 'open') =>
  callRpc<OffboardingRow[]>('list_offboarding', { p_entity_id: entityId, p_status: status })

export const getOffboardingCase = (caseId: string) => callRpc<OffboardingCase>('get_offboarding_case', { p_case_id: caseId })

export const startOffboarding = (i: StartOffboardingInput) =>
  callRpc<{ ok: boolean; case_id: string; notice_days: number; min_notice_days: number; in_probation: boolean; settlement_due_date: string }>(
    'start_offboarding',
    {
      p_employee_id: i.employeeId,
      p_type: i.type,
      p_initiated_by: i.initiatedBy,
      p_notice_date: i.noticeDate,
      p_last_working_date: i.lastWorkingDate,
      p_reason: i.reason,
      p_leaving_uae: i.leavingUae,
      p_notice_shortfall_reason: i.shortfallReason,
      p_source_exception_id: i.sourceExceptionId,
    }
  )

export const updateOffboardingDates = (caseId: string, noticeDate: string, lastDay: string, reason: string, expectedVersion: number, shortfall: string | null) =>
  callRpc<{ ok: boolean }>('update_offboarding_dates', {
    p_case_id: caseId,
    p_notice_date: noticeDate,
    p_last_working_date: lastDay,
    p_reason: reason,
    p_expected_version: expectedVersion,
    p_notice_shortfall_reason: shortfall,
  })

export const completeOffboardingTask = (taskId: string, status: 'done' | 'not_needed' | 'not_started', notes: string | null) =>
  callRpc<{ ok: boolean }>('complete_offboarding_task', { p_task_id: taskId, p_status: status, p_notes: notes })

export const completeOffboarding = (caseId: string, notes: string | null) =>
  callRpc<{ ok: boolean }>('complete_offboarding', { p_case_id: caseId, p_notes: notes })

export const cancelOffboarding = (caseId: string, reason: string) => callRpc<{ ok: boolean }>('cancel_offboarding', { p_case_id: caseId, p_reason: reason })
