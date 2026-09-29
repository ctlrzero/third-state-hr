import { callRpc } from './client'

// Manual per-employee balance override, for employees whose offer letter
// specifies a different entitlement than the entity-wide accrual policy.
// Owner / entity_admin only; direct INSERT/UPDATE on leave_balances is not
// granted to authenticated, so this RPC is the only write path.

export const adjustLeaveBalance = (employeeId: string, leaveTypeId: string, newBalance: number, reason: string) =>
  callRpc<null>('adjust_leave_balance', {
    p_employee_id: employeeId,
    p_leave_type_id: leaveTypeId,
    p_new_balance: newBalance,
    p_reason: reason,
  })
