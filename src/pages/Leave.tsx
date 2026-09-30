import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { fmtDate as fmtDateUae, fmtDayShort, fmtTime } from '../lib/format'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { AccrualPolicyPanel } from '../components/AccrualPolicyPanel'
import type { LeaveBalance, LeaveRequest, LeaveType } from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'
import { confirmDialog } from '../lib/confirm'
import { isSelfServiceRole } from '../types/db'
import { friendlyError } from '../lib/api/client'
import { FindCoverSheet, type CoverShift } from './schedules/SchedulingTools'

const LEAVE_STATUS_TONE: Record<string, 'neutral' | 'info' | 'warning' | 'success' | 'risk'> = {
  pending: 'warning',
  approved: 'success',
  rejected: 'risk',
  cancelled: 'neutral',
}

// UAE-readable dates (Asia/Dubai) shared across the app.
const fmtDate = (d: string) => fmtDateUae(d)

interface AffectedShift {
  shift_id: string
  shift_date: string
  start_time: string
  end_time: string
  location_id: string
  location: string | null
  is_published: boolean
}

// Leave: leave_requests + leave_types + leave_balances. Admin
// (owner/entity_admin/location_manager) get a decision queue for pending
// requests plus recent history, resolved through the SECURITY DEFINER
// approve_leave_request() RPC — never a raw status UPDATE — because that
// RPC independently re-checks the caller's authority AND (after this
// session's audit) that the request is still 'pending' before applying a
// decision, so a duplicate click can never double-decrement a balance.
// Staff get "My Leave": their own per-type balances, a request form, and
// their own request history. leave_types_select_self and
// leave_balances_select_self (added this session — previously staff had
// no read access to either table at all) scope reads to the caller's own
// entity/employee record; leave_requests itself already had a safe
// self-insert-as-pending-only policy mirroring employee_change_requests.
export default function Leave() {
  const { profile } = useAuth()
  if (isSelfServiceRole(profile?.role)) return <MyLeave />
  return <LeaveAdmin />
}

function LeaveAdmin() {
  const { profile } = useAuth()
  const canOverride = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const [requests, setRequests] = useState<LeaveRequest[]>([])
  const [balances, setBalances] = useState<LeaveBalance[]>([])
  const [leaveTypes, setLeaveTypes] = useState<LeaveType[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [overridingId, setOverridingId] = useState<string | null>(null)
  const [overrideReason, setOverrideReason] = useState('')
  const [clashes, setClashes] = useState<{ name: string; employeeId: string; shifts: AffectedShift[] } | null>(null)
  const [cover, setCover] = useState<CoverShift | null>(null)
  const [coveredIds, setCoveredIds] = useState<string[]>([])

  async function load() {
    setLoading(true)
    setError(null)
    // RLS (leave_requests_select) already scopes this to the caller's own
    // entity (entity_admin) or location (location_manager), or everything
    // for owner — the .order() is presentation only.
    const { data, error: fetchError } = await supabase
      .from('leave_requests')
      .select('*, employees(id, full_name), leave_types(id, name)')
      .order('requested_at', { ascending: false })
    if (fetchError) setError(friendlyError(fetchError))
    else setRequests((data ?? []) as unknown as LeaveRequest[])

    // leave_balances_select already scopes this the same way
    // leave_requests_select does (entity/location match, or everything for
    // owner) — fetched separately here purely so the queue can show the
    // employee's remaining balance next to each pending request, so an
    // admin can see an insufficient-balance case before clicking Approve
    // rather than only finding out from the RPC's error message.
    const { data: balData, error: balError } = await supabase.from('leave_balances').select('*')
    if (!balError) setBalances((balData ?? []) as unknown as LeaveBalance[])

    if (canOverride) {
      const { data: typesData } = await supabase.from('leave_types').select('*').order('name')
      setLeaveTypes((typesData ?? []) as LeaveType[])
    }
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // p_override/p_reason: an owner/entity_admin-only escape hatch for approving against
  // an insufficient balance. The RPC requires a non-empty reason whenever override=true,
  // logs a dedicated leave_balance_override_approved audit event (in addition to the
  // normal leave_approved / leave_balance_used events), and rejects the call outright for
  // any other role — this UI only ever shows the control to owner/entity_admin in the
  // first place, but the RPC is the real enforcement point either way.
  async function handleDecide(id: string, action: 'approve' | 'reject', override = false, reason?: string) {
    if (action === 'reject') {
      const who = requests.find((r) => r.id === id)?.employees?.full_name ?? 'this person'
      if (!(await confirmDialog(`Reject ${who}’s leave?`))) return
    }
    setBusyId(id)
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('approve_leave_request', {
      p_request_id: id,
      p_action: action,
      p_override: override,
      p_override_reason: reason ?? null,
    })
    setBusyId(null)
    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    const affected = ((data as { affected_shifts?: AffectedShift[] } | null)?.affected_shifts ?? [])
    const req = requests.find((r) => r.id === id)
    const who = req?.employees?.full_name ?? 'This person'
    setCoveredIds([])
    setClashes(action === 'approve' && affected.length > 0 && req ? { name: who, employeeId: req.employee_id, shifts: affected } : null)
    setNotice(action === 'approve' ? 'Leave approved — balance updated.' : 'Leave rejected.')
    setOverridingId(null)
    setOverrideReason('')
    load()
  }

  const pending = requests.filter((r) => r.status === 'pending')
  const decided = requests.filter((r) => r.status !== 'pending').slice(0, 25)

  function balanceFor(employeeId: string, leaveTypeId: string) {
    return balances.find((b) => b.employee_id === employeeId && b.leave_type_id === leaveTypeId)?.balance_days ?? 0
  }

  return (
    <div className="space-y-5">
      <div>
        <EntityEyebrow />
        <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Leave</h1>
        <p className="text-xs text-muted">{loading ? 'Loading…' : `${pending.length} pending`}</p>
      </div>

      {error && (
        <p role="alert" className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">
          {error}{' '}
          <button className="underline" onClick={() => setError(null)}>
            Dismiss
          </button>
        </p>
      )}
      {notice && (
        <p role="status" className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      {clashes && (
        <div role="status" className="rounded-[14px] border border-brand-warning/40 bg-brand-warning-soft p-4">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div>
              <h2 className="text-sm font-semibold text-brand-warning-solid">
                {clashes.name} still has {clashes.shifts.length} shift{clashes.shifts.length === 1 ? '' : 's'} during this leave
              </h2>
              <p className="text-xs text-brand-warning-solid">
                They were not cancelled. Find cover for each one — shifts not shared yet won't be shared with staff on leave days.
              </p>
            </div>
            <button className="text-xs font-medium text-brand-warning-solid underline" onClick={() => setClashes(null)}>
              Dismiss
            </button>
          </div>
          <ul className="mt-3 space-y-1.5">
            {clashes.shifts.map((s) => (
              <li key={s.shift_id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface px-3 py-2 text-sm">
                <span className="text-ink">
                  {fmtDayShort(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                  {s.location && <span className="text-muted"> · {s.location}</span>}
                  <span className="text-muted"> · {s.is_published ? 'shared with staff' : 'not shared yet'}</span>
                </span>
                {coveredIds.includes(s.shift_id) ? (
                  <span className="text-xs font-medium text-brand-action-text">Covered</span>
                ) : (
                  <button
                    type="button"
                    onClick={() =>
                      setCover({
                        id: s.shift_id,
                        shift_date: s.shift_date,
                        start_time: s.start_time,
                        end_time: s.end_time,
                        break_minutes: 0,
                        location_id: s.location_id,
                        employee_id: clashes.employeeId,
                        is_published: s.is_published,
                        currentName: clashes.name,
                      })
                    }
                    className="min-h-[44px] rounded-lg border border-border px-4 py-2 text-sm font-medium text-brand-blue hover:bg-surface-alt"
                  >
                    Find cover
                  </button>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      {cover && (
        <FindCoverSheet
          shift={cover}
          onClose={() => setCover(null)}
          onAssigned={(message) => {
            setCoveredIds((ids) => [...ids, cover.id])
            setCover(null)
            setNotice(message)
          }}
        />
      )}

      {loading ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-16 animate-pulse rounded-[14px] bg-surface" />
          ))}
        </div>
      ) : (
        <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Awaiting your decision</h2>
          {pending.length === 0 ? (
            <p className="text-sm text-muted">No pending leave requests.</p>
          ) : (
            <ul className="space-y-2">
              {pending.map((r) => {
                const remaining = balanceFor(r.employee_id, r.leave_type_id)
                const insufficient = remaining < r.days_requested
                return (
                  <li key={r.id} className="rounded-lg bg-surface-alt px-3 py-3 text-sm">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div>
                        <p className="font-medium text-ink">{r.employees?.full_name ?? 'Unknown'}</p>
                        <p className="text-xs text-muted">
                          {r.leave_types?.name ?? 'Leave'} · {fmtDate(r.start_date)} – {fmtDate(r.end_date)} ·{' '}
                          {r.days_requested} day{r.days_requested === 1 ? '' : 's'} ·{' '}
                          <span className={insufficient ? 'font-medium text-brand-risk' : ''}>
                            {remaining} day{remaining === 1 ? '' : 's'} remaining
                          </span>
                        </p>
                        {insufficient && (
                          <p className="mt-1 text-xs font-medium text-brand-risk">
                            Not enough leave balance. Ask HR to approve it, or reject and ask {r.employees?.full_name ?? 'them'} for fewer days.
                          </p>
                        )}
                        {r.reason && <p className="mt-1 text-xs text-muted">“{r.reason}”</p>}
                      </div>
                      <span className="flex gap-2">
                        <button
                          onClick={() => handleDecide(r.id, 'reject')}
                          disabled={busyId === r.id}
                          className="min-h-[44px] rounded-lg border border-brand-risk/40 bg-surface px-4 py-2 text-sm font-medium text-brand-risk-text disabled:opacity-60"
                        >
                          Reject
                        </button>
                        {insufficient && canOverride && (
                          <button
                            onClick={() => setOverridingId(overridingId === r.id ? null : r.id)}
                            disabled={busyId === r.id}
                            className="min-h-[44px] rounded-lg bg-brand-risk-soft px-4 py-2 text-sm font-medium text-brand-risk-text disabled:opacity-60"
                          >
                            Override & approve…
                          </button>
                        )}
                        {!insufficient && (
                          <button
                            onClick={() => handleDecide(r.id, 'approve')}
                            disabled={busyId === r.id}
                            className="min-h-[44px] rounded-lg bg-brand-action px-4 py-2 text-sm font-medium text-white disabled:opacity-60"
                          >
                            {busyId === r.id ? 'Working…' : 'Approve'}
                          </button>
                        )}
                      </span>
                    </div>
                    {overridingId === r.id && (
                      <div className="mt-2 flex flex-wrap items-center gap-2 rounded-lg bg-surface px-3 py-2">
                        <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted flex-1">
                          Override reason (required)
                          <input
                            type="text"
                            value={overrideReason}
                            onChange={(e) => setOverrideReason(e.target.value)}
                            placeholder="Reason for overriding the balance check (required)"
                            className="min-w-[220px] flex-1 rounded-lg border border-border px-2.5 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                          />
                        </label>
                        <button
                          onClick={() => handleDecide(r.id, 'approve', true, overrideReason)}
                          disabled={busyId === r.id || overrideReason.trim().length === 0}
                          className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
                        >
                          Confirm override
                        </button>
                        <button
                          onClick={() => {
                            setOverridingId(null)
                            setOverrideReason('')
                          }}
                          className="text-xs text-muted hover:underline"
                        >
                          Cancel
                        </button>
                      </div>
                    )}
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      )}

      {!loading && decided.length > 0 && (
        <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Recent decisions</h2>
          <ul className="space-y-1.5">
            {decided.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  {r.employees?.full_name ?? 'Unknown'} · {r.leave_types?.name ?? 'Leave'} · {fmtDate(r.start_date)} –{' '}
                  {fmtDate(r.end_date)}
                </span>
                <StatusBadge status={r.status} tone={LEAVE_STATUS_TONE[r.status]} />
              </li>
            ))}
          </ul>
        </div>
      )}

      {!loading && canOverride && (
        <AccrualPolicyPanel leaveTypes={leaveTypes} isOwner={profile?.role === 'owner'} />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Staff self-service
// ---------------------------------------------------------------------------

function MyLeave() {
  const [balances, setBalances] = useState<LeaveBalance[]>([])
  const [leaveTypes, setLeaveTypes] = useState<LeaveType[]>([])
  const [myRequests, setMyRequests] = useState<LeaveRequest[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)

  async function load() {
    setLoading(true)
    setError(null)
    const {
      data: { user },
    } = await supabase.auth.getUser()
    if (!user) {
      setLoading(false)
      return
    }
    // leave_balances_select_self / leave_types_select_self (this session's
    // additions) scope these to the caller's own employee record / entity —
    // there is no RLS gap here that would let staff see a peer's balance.
    const [balRes, typesRes, reqRes] = await Promise.all([
      supabase.from('leave_balances').select('*, leave_types(id, name)').order('updated_at', { ascending: false }),
      supabase.from('leave_types').select('*').order('name'),
      supabase
        .from('leave_requests')
        .select('*, leave_types(id, name)')
        .order('requested_at', { ascending: false }),
    ])
    if (balRes.error) setError(friendlyError(balRes.error))
    else setBalances((balRes.data ?? []) as unknown as LeaveBalance[])
    const STAFF_LEAVE_TYPES = ['Annual Leave', 'Sick Leave']
    setLeaveTypes(((typesRes.data ?? []) as LeaveType[]).filter((t) => STAFF_LEAVE_TYPES.includes(t.name)))
    setMyRequests((reqRes.data ?? []) as unknown as LeaveRequest[])
    setLoading(false)
  }

  useEffect(() => {
    load()
  }, [])

  // Phase 2.9: self-cancel a still-Pending request via cancel_leave_request()
  // — the RPC re-verifies ownership and pending status itself and is
  // idempotent (a repeat call on an already-cancelled request is a no-op),
  // so a duplicate click can never double-release the reserved balance.
  async function handleCancel(id: string) {
    if (!(await confirmDialog('Cancel this leave request? Any balance held for it will be released.'))) return
    setBusyId(id)
    setError(null)
    const { error: rpcError } = await supabase.rpc('cancel_leave_request', { p_request_id: id, p_reason: null })
    setBusyId(null)
    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    setNotice('Leave request cancelled.')
    load()
  }

  const balancesByType = useMemo(() => new Map(balances.map((b) => [b.leave_type_id, b])), [balances])

  if (loading) {
    return (
      <div className="space-y-3">
        <div className="h-20 animate-pulse rounded-[14px] bg-surface" />
        <div className="h-32 animate-pulse rounded-[14px] bg-surface" />
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">My leave</h1>
        </div>
        <button
          onClick={() => setFormOpen(true)}
          disabled={leaveTypes.length === 0}
          className="min-h-[44px] rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
        >
          Request leave
        </button>
      </div>

      {error && <p role="alert" className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
      {notice && (
        <p role="status" className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Balances</h2>
        {leaveTypes.length === 0 ? (
          <p className="text-sm text-muted">Leave isn’t set up for you yet. Please ask your manager.</p>
        ) : (
          <ul className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            {leaveTypes.map((t) => {
              const bal = balancesByType.get(t.id)
              return (
                <li key={t.id} className="rounded-lg bg-surface-alt p-3">
                  <p className="text-xs text-muted">{t.name}</p>
                  <p className="mt-1 text-lg font-medium text-ink">
                    {bal ? bal.balance_days : 0} <span className="text-xs font-normal text-muted">days</span>
                  </p>
                </li>
              )
            })}
          </ul>
        )}
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Your requests</h2>
        {myRequests.length === 0 ? (
          <EmptyState title="No leave requests yet" description="Request leave using the button above." />
        ) : (
          <ul className="space-y-2">
            {myRequests.map((r) => (
              <li key={r.id} className="rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-ink">
                    {r.leave_types?.name ?? 'Leave'} · {fmtDate(r.start_date)} – {fmtDate(r.end_date)} · {r.days_requested} day
                    {r.days_requested === 1 ? '' : 's'}
                  </span>
                  <span className="flex items-center gap-2">
                    <StatusBadge status={r.status} tone={LEAVE_STATUS_TONE[r.status]} />
                    {r.status === 'pending' && (
                      <button
                        onClick={() => handleCancel(r.id)}
                        disabled={busyId === r.id}
                        className="min-h-[44px] rounded-lg border border-brand-risk/40 bg-surface px-4 py-2 text-sm font-medium text-brand-risk disabled:opacity-60"
                      >
                        {busyId === r.id ? 'Cancelling…' : 'Cancel'}
                      </button>
                    )}
                  </span>
                </div>
                {r.reason && <p className="mt-1 text-muted">“{r.reason}”</p>}
                {r.status !== 'pending' && r.manager_notes && <p className="mt-1 text-muted">Note: {r.manager_notes}</p>}
              </li>
            ))}
          </ul>
        )}
      </div>

      {formOpen && (
        <RequestLeaveModal
          leaveTypes={leaveTypes}
          balances={balances}
          onClose={() => setFormOpen(false)}
          onSubmitted={() => {
            setFormOpen(false)
            setNotice('Leave request submitted — your manager needs to approve it.')
            load()
          }}
        />
      )}
    </div>
  )
}

function daysBetweenInclusive(start: string, end: string) {
  const s = new Date(start + 'T00:00:00')
  const e = new Date(end + 'T00:00:00')
  const diff = Math.round((e.getTime() - s.getTime()) / (1000 * 60 * 60 * 24))
  return diff >= 0 ? diff + 1 : 0
}

function RequestLeaveModal({
  leaveTypes,
  balances,
  onClose,
  onSubmitted,
}: {
  leaveTypes: LeaveType[]
  balances: LeaveBalance[]
  onClose: () => void
  onSubmitted: () => void
}) {
  const [leaveTypeId, setLeaveTypeId] = useState(leaveTypes[0]?.id ?? '')
  const [startDate, setStartDate] = useState('')
  const [endDate, setEndDate] = useState('')
  const [reason, setReason] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const days = startDate && endDate ? daysBetweenInclusive(startDate, endDate) : 0
  const chosenType = leaveTypes.find((t) => t.id === leaveTypeId)
  const remaining = balances.find((b) => b.leave_type_id === leaveTypeId)?.balance_days ?? 0

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (startDate && endDate && days <= 0) {
      setError('The end date must be the same as or after the start date.')
      return
    }
    if (!leaveTypeId || !startDate || !endDate || days <= 0) {
      setError('Choose a leave type and a valid date range.')
      return
    }
    setSubmitting(true)
    setError(null)
    // leave_requests_insert only allows this self-insert when
    // employee_id = my_employee_id(), status = 'pending', and
    // decided_by/decided_at are both null — an employee can propose a
    // request but can never submit one that's already decided.
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const { data: empRow, error: empError } = await supabase
      .from('employees')
      .select('id')
      .eq('auth_user_id', user?.id ?? '')
      .maybeSingle()
    if (empError || !empRow) {
      setSubmitting(false)
      setError(empError ? friendlyError(empError) : 'Your login isn’t connected to your staff profile yet. Please ask your manager to fix this.')
      return
    }
    const { error: insertError } = await supabase.from('leave_requests').insert({
      employee_id: empRow.id,
      leave_type_id: leaveTypeId,
      start_date: startDate,
      end_date: endDate,
      days_requested: days,
      status: 'pending',
      reason: reason.trim() || null,
    })
    setSubmitting(false)
    if (insertError) {
      setError(friendlyError(insertError))
      return
    }
    onSubmitted()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4">
      <div className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card">
        <h2 className="mb-4 text-base font-semibold text-ink">Request leave</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="leave-leave-type-1" className="mb-1 block text-sm font-medium text-ink">Leave type</label>
            <select id="leave-leave-type-1"
              value={leaveTypeId}
              onChange={(e) => setLeaveTypeId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {leaveTypes.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.name}
                </option>
              ))}
            </select>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label htmlFor="leave-start-date-2" className="mb-1 block text-sm font-medium text-ink">Start date</label>
              <input id="leave-start-date-2"
                type="date"
                value={startDate}
                onChange={(e) => setStartDate(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="leave-end-date-3" className="mb-1 block text-sm font-medium text-ink">End date</label>
              <input id="leave-end-date-3"
                type="date"
                value={endDate}
                onChange={(e) => setEndDate(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          {days > 0 && <p className="text-xs text-muted">{days} day{days === 1 ? '' : 's'} requested.</p>}
          {chosenType && (
            <p className="text-xs text-muted">
              You have {remaining} day{remaining === 1 ? '' : 's'} of {chosenType.name} left.
            </p>
          )}
          {chosenType && days > remaining && (
            <p className="text-xs font-medium text-brand-risk">This is more than your balance — your manager may refuse it.</p>
          )}
          <div>
            <label htmlFor="leave-reason-optional-4" className="mb-1 block text-sm font-medium text-ink">Reason (optional)</label>
            <textarea id="leave-reason-optional-4"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={2}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>

          {error && <p role="alert" className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="min-h-[44px] rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="min-h-[44px] rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Submitting…' : 'Submit request'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
