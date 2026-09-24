import { supabase } from '../supabase'
import { callRpc, type ApiResult } from './client'
import type { EmployeeChangeRequest, EmployeeStatus } from '../../types/db'

export interface Completeness {
  percent: number
  missing: string[]
}

export const setEmployeeStatus = (employeeId: string, newStatus: EmployeeStatus, reason: string | null) =>
  callRpc<unknown>('set_employee_status', { p_employee_id: employeeId, p_new_status: newStatus, p_reason: reason })

export const updateEmployeeDetails = (employeeId: string, changes: Record<string, unknown>) =>
  callRpc<unknown>('update_employee_details', { p_employee_id: employeeId, p_changes: changes })

export const getEmployeeCompleteness = (employeeId: string) =>
  callRpc<Completeness>('get_employee_completeness', { p_employee_id: employeeId })

export const decideEmployeeChangeRequest = (requestId: string, action: 'approve' | 'reject', reason: string | null) =>
  callRpc<null>('decide_employee_change_request', {
    p_request_id: requestId,
    p_action: action,
    p_decision_reason: reason,
  })

/** Pending change requests across the caller's RLS scope (manager/admin queue). */
export async function listPendingChangeRequests(): Promise<ApiResult<EmployeeChangeRequest[]>> {
  const { data, error } = await supabase
    .from('employee_change_requests')
    .select('*, employees(id, full_name)')
    .eq('status', 'pending')
    .order('requested_at', { ascending: true })
    .limit(100)
  return { data: (data ?? []) as unknown as EmployeeChangeRequest[], error: error?.message ?? null, notAvailable: false }
}

export interface AuditRow {
  id: string
  table_name: string
  action: string | null
  changed_at: string | null
  changed_by: string | null
  old_value: Record<string, unknown> | null
  new_value: Record<string, unknown> | null
}

/** audit_log is Owner-only under RLS; other roles get an empty list. */
export async function listEmployeeAudit(employeeId: string): Promise<ApiResult<AuditRow[]>> {
  const { data, error } = await supabase
    .from('audit_log')
    .select('id, table_name, action, changed_at, changed_by, old_value, new_value')
    .or(`employee_id.eq.${employeeId},record_id.eq.${employeeId}`)
    .order('changed_at', { ascending: false })
    .limit(100)
  return { data: (data ?? []) as AuditRow[], error: error?.message ?? null, notAvailable: false }
}

/** Fields an admin may edit through update_employee_details(). */
export const EDITABLE_FIELDS: { key: string; label: string; type: 'text' | 'date' | 'select'; options?: string[] }[] = [
  { key: 'full_name', label: 'Full name', type: 'text' },
  { key: 'preferred_name', label: 'Preferred name', type: 'text' },
  { key: 'phone', label: 'Phone', type: 'text' },
  { key: 'email', label: 'Email', type: 'text' },
  { key: 'nationality', label: 'Nationality', type: 'text' },
  { key: 'dob', label: 'Date of birth', type: 'date' },
  { key: 'emergency_contact_name', label: 'Emergency contact name', type: 'text' },
  { key: 'emergency_contact_phone', label: 'Emergency contact phone', type: 'text' },
  { key: 'employment_type', label: 'Employment type', type: 'select', options: ['full_time', 'part_time', 'on_call', 'seasonal'] },
  { key: 'join_date', label: 'Join date', type: 'date' },
  { key: 'probation_end_date', label: 'Probation end date', type: 'date' },
  { key: 'passport_exp', label: 'Passport expiry', type: 'date' },
  { key: 'visa_exp', label: 'Visa expiry', type: 'date' },
  { key: 'labor_card_exp', label: 'Labour card expiry', type: 'date' },
  { key: 'health_card_exp', label: 'Health card expiry', type: 'date' },
]

/** Returns only the fields whose value actually changed (empty string → null). */
export function diffEmployeeChanges(
  before: Record<string, unknown>,
  draft: Record<string, string>
): Record<string, string | null> {
  const out: Record<string, string | null> = {}
  for (const [key, raw] of Object.entries(draft)) {
    const next = raw.trim() === '' ? null : raw.trim()
    const prev = before[key] == null || before[key] === '' ? null : String(before[key])
    if (next !== prev) out[key] = next
  }
  return out
}
