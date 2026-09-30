import { supabase } from '../supabase'
import { callRpc, type ApiResult } from './client'
import type { CompensationView, ValidCompensation } from '../compensation'

// Salary is owner / entity_admin only. Reads and writes go through
// SECURITY DEFINER RPCs (w7_compensation_admin) that re-check the role and
// entity, so the UI never depends on table grants; direct INSERT/UPDATE/
// DELETE on employee_compensation is revoked from authenticated.

export const getEmployeeCompensation = (employeeId: string) =>
  callRpc<CompensationView>('get_employee_compensation', { p_employee_id: employeeId })

export const setEmployeeCompensation = (employeeId: string, v: ValidCompensation) =>
  callRpc<null>('set_employee_compensation', {
    p_employee_id: employeeId,
    p_pay_type: v.pay_type,
    p_pay_rate: v.pay_rate,
    p_overtime_multiplier: v.overtime_multiplier,
    p_holiday_multiplier: v.holiday_multiplier,
    p_reason: v.reason,
  })

/** Pay rates for a set of employees (RLS: owner / own-entity admin only; others get no rows). */
export async function listPayRates(employeeIds: string[]): Promise<ApiResult<{ employee_id: string; pay_rate: number | null }[]>> {
  if (employeeIds.length === 0) return { data: [], error: null }
  const { data, error } = await supabase.from('employee_compensation').select('employee_id, pay_rate').in('employee_id', employeeIds)
  return { data: (data ?? []) as { employee_id: string; pay_rate: number | null }[], error: error?.message ?? null }
}
