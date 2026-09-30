import { supabase } from '../supabase'
import { callRpc, unwrapOk, type ApiResult } from './client'
import type { AttendanceException } from '../../types/db'

// All attendance RPCs in one place — a signature change is a one-file fix.

export type ClockState = 'not_started' | 'clocked_in' | 'clocked_out' | 'no_shift'

// Shapes per docs/API_CONTRACT.md §1 (verified against the live DB).
export interface ClockStatusShift {
  id: string
  shift_date: string
  start_time: string
  end_time: string
  planned_start: string | null
  planned_end: string | null
  location_id: string | null
  location_name: string | null
  position_title: string | null
  status: string | null
}

export interface ClockStatusAttendance {
  id: string
  shift_id: string | null
  clock_in_at: string
  clock_out_at: string | null
  worked_minutes: number | null
  late_minutes: number | null
  corrected: boolean | null
}

export interface ClockStatus {
  state: ClockState
  business_date: string
  server_time: string
  today_shift: ClockStatusShift | null
  attendance: ClockStatusAttendance | null
}

export type MyAttendanceStatus = 'scheduled' | 'in_progress' | 'completed' | 'missed' | 'unscheduled'

/** get_my_attendance row. attendance_id is null for a scheduled/missed shift with no clock-in. */
export interface MyAttendanceRow {
  attendance_id: string | null
  shift_id: string | null
  business_date: string
  location_id: string | null
  location_name: string | null
  planned_start: string | null
  planned_end: string | null
  clock_in_at: string | null
  clock_out_at: string | null
  worked_minutes: number | null
  late_minutes: number | null
  status: MyAttendanceStatus | string
  corrected: boolean | null
  correction_reason: string | null
}

export interface OverviewRow {
  shift_id: string
  employee_id: string
  shift_date: string
  planned_minutes: number
  default_payable_minutes: number
  final_payable_minutes: number | null
  payable_status: string
  pending_adjustment: boolean
}

export interface PayableRecord {
  id: string
  shift_id: string
  employee_id: string
  planned_minutes: number
  planned_break_minutes: number
  default_payable_minutes: number
  final_payable_minutes: number | null
  status: 'pending' | 'adjusted' | 'materialized'
}

export interface AttendanceAdjustment {
  id: string
  payable_shift_record_id: string
  proposed_minutes: number
  reason: string
  actor_role: string
  status: 'pending' | 'applied' | 'rejected'
  created_at: string
  decided_at: string | null
  decision_reason: string | null
}

export const getMyClockStatus = () => callRpc<ClockStatus>('get_my_clock_status')

export const getMyAttendance = (periodStart: string, periodEnd: string) =>
  callRpc<MyAttendanceRow[]>('get_my_attendance', { p_period_start: periodStart, p_period_end: periodEnd })

// Both are idempotent: a repeat tap returns the existing record with
// already_clocked_in / already_clocked_out = true.
export const clockIn = () =>
  callRpc<{ id: string; shift_id: string | null; clock_in_at: string; already_clocked_in: boolean }>('clock_in')
export const clockOut = () => callRpc<{ id: string; clock_out_at: string; already_clocked_out: boolean }>('clock_out')

export const getLocationAttendanceOverview = (locationId: string, periodStart: string, periodEnd: string) =>
  callRpc<OverviewRow[]>('get_location_attendance_overview', {
    p_location_id: locationId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  })

export const getAttendanceExceptions = (locationId: string, periodStart: string, periodEnd: string) =>
  callRpc<AttendanceException[]>('get_attendance_exceptions', {
    p_location_id: locationId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  })

/** NULL for either timestamp means "keep the current value" (server-side). */
export const correctAttendanceRecord = (
  recordId: string,
  newClockInAt: string | null,
  newClockOutAt: string | null,
  reason: string
) =>
  callRpc<null>('correct_attendance_record', {
    p_record_id: recordId,
    p_new_clock_in_at: newClockInAt,
    p_new_clock_out_at: newClockOutAt,
    p_reason: reason,
  })

export const seedPayableShiftRecords = (locationId: string, periodStart: string, periodEnd: string) =>
  callRpc<unknown>('seed_payable_shift_records', {
    p_location_id: locationId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  }).then(unwrapOk)

export const proposeAttendanceAdjustment = (payableShiftRecordId: string, proposedMinutes: number, reason: string) =>
  callRpc<{ ok: boolean; adjustment_id?: string; message?: string }>('propose_attendance_adjustment', {
    p_payable_shift_record_id: payableShiftRecordId,
    p_proposed_minutes: proposedMinutes,
    p_reason: reason,
  }).then(unwrapOk)

export const applyAttendanceAdjustment = (adjustmentId: string) =>
  callRpc<{ ok: boolean; message?: string }>('apply_attendance_adjustment', { p_adjustment_id: adjustmentId }).then(
    unwrapOk
  )

export const rejectAttendanceAdjustment = (adjustmentId: string, reason: string) =>
  callRpc<{ ok: boolean; message?: string }>('reject_attendance_adjustment', {
    p_adjustment_id: adjustmentId,
    p_reason: reason,
  }).then(unwrapOk)

/** P1-5: nightly missing clock-out suggestions. Never applied until a manager confirms. */
export interface ClockOutSuggestion {
  id: string
  attendance_record_id: string
  employee_id: string
  employee_name: string
  shift_id: string | null
  work_date: string
  clock_in_at: string
  /** Planned end of the shift; null when the clock-in had no shift. */
  suggested_clock_out_at: string | null
  reason: string
  status: 'pending'
  created_at: string
}

export const getClockOutSuggestions = (locationId: string) =>
  callRpc<ClockOutSuggestion[]>('get_clock_out_suggestions', { p_location_id: locationId })

/** Applies the suggested time (or `clockOutAt`) through the normal correction rules. */
export const confirmClockOutSuggestion = (id: string, clockOutAt: string | null = null, reason: string | null = null) =>
  callRpc<{ ok: boolean; clock_out_at: string }>('confirm_clock_out_suggestion', {
    p_id: id,
    p_clock_out_at: clockOutAt,
    p_reason: reason,
  })

export const dismissClockOutSuggestion = (id: string) =>
  callRpc<{ ok: boolean }>('dismiss_clock_out_suggestion', { p_id: id })

/** RLS-scoped reads that back the workspace (no RPC exists for these). */
export async function getAttendanceRecords(ids: string[]) {
  if (ids.length === 0) return { data: [], error: null }
  return supabase
    .from('attendance_records')
    .select('id, employee_id, shift_id, clock_in_at, clock_out_at, original_clock_in_at, original_clock_out_at, corrected, correction_reason')
    .in('id', ids)
}

export async function getShiftsByIds(ids: string[]) {
  if (ids.length === 0) return { data: [], error: null }
  return supabase.from('shifts').select('id, shift_date, start_time, end_time').in('id', ids)
}

export async function getPayableRecords(shiftIds: string[]): Promise<ApiResult<PayableRecord[]>> {
  if (shiftIds.length === 0) return { data: [], error: null }
  const { data, error } = await supabase.from('payable_shift_records').select('*').in('shift_id', shiftIds)
  return { data: (data ?? []) as PayableRecord[], error: error?.message ?? null }
}

export async function getAdjustments(payableIds: string[]): Promise<ApiResult<AttendanceAdjustment[]>> {
  if (payableIds.length === 0) return { data: [], error: null }
  const { data, error } = await supabase
    .from('attendance_adjustments')
    .select('*')
    .in('payable_shift_record_id', payableIds)
    .order('created_at', { ascending: false })
  return { data: (data ?? []) as AttendanceAdjustment[], error: error?.message ?? null }
}
