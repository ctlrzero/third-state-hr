import { callRpc } from './client'
import type { NotificationRow } from '../../types/db'

export const getMyNotifications = (limit = 50, before: string | null = null, unreadOnly = false) =>
  callRpc<NotificationRow[]>('get_my_notifications', { p_limit: limit, p_before: before, p_unread_only: unreadOnly })

export const markNotificationRead = (id: string) =>
  callRpc<{ ok?: boolean }>('mark_notification_read', { p_notification_id: id })

export const markAllNotificationsRead = () => callRpc<unknown>('mark_all_notifications_read')

// Navigation convenience only — each target page re-checks access itself.
export const NOTIFICATION_TARGET_ROUTE: Record<string, string> = {
  employee_documents: '/documents',
  leave_requests: '/leave',
  shift_swap_requests: '/schedules',
  shifts: '/schedules',
  employees: '/employees',
  payslips: '/payroll',
  interviews: '/my-interviews',
  attendance_records: '/attendance',
}
