import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import type { LeaveAccrualPolicy, LeaveBalance, LeaveRequest, LeaveType } from '../types/db'

const LEAVE_STATUS_TONE: Record<string, 'neutral' | 'info' | 'warning' | 'success' | 'risk'> = {
  pending: 'warning',
  approved: 'success',
  rejected: 'risk',
  cancelled: 'neutral',
}

function fmtDate(d: string) {
  return new Date(d + 'T00:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
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
  if (profile?.role === 'staff') return <MyLeave />
  return <LeaveAdmin />
}

const ACCRUAL_FREQUENCY_LABEL: Record<string, string> = { monthly: 'Monthly', annual: 'Annual' }
const ACCRUAL_ROUNDING_LABEL: Record<string, string> = {
  none: 'No rounding',
  nearest_half_day: 'Nearest half day',
  nearest_day: 'Nearest day',
}

// Phase 2.9: accrual policy config, owner/entity_admin only (matches the
// leave_accrual_policies RLS scope, which deliberately excludes
// location_manager). Configuring a policy never activates it — is_approved
// always resets to false — and only an Owner can approve one via
// approve_leave_accrual_policy(). Running accrual for a period is always a
// separate, deliberate action (run_leave_accrual()); there's no scheduler.
function AccrualPolicyPanel({ leaveTypes, isOwner }: { leaveTypes: LeaveType[]; isOwner: boolean }) {
  const [policies, setPolicies] = useState<LeaveAccrualPolicy[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [runPeriodKey, setRunPeriodKey] = useState<Record<string, string>>({})

  async function load() {
    setLoading(true)
    const { data, error: fetchError } = await supabase
      .from('leave_accrual_policies')
      .select('*, leave_types(id, name)')
      .order('created_at', { ascending: false })
    if (fetchError) setError(fetchError.message)
    else setPolicies((data ?? []) as unknown as LeaveAccrualPolicy[])
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function handleApprove(policyId: string) {
    setBusyId(policyId)
    const { error: rpcError } = await supabase.rpc('approve_leave_accrual_policy', { p_policy_id: policyId })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setNotice('Accrual policy approved.')
    load()
  }

  async function handleRun(policy: LeaveAccrualPolicy) {
    const periodKey = runPeriodKey[policy.id]
    if (!periodKey || !periodKey.trim()) {
      setError('Enter a period key (e.g. 2026-08 for monthly, 2026 for annual) before running accrual.')
      return
    }
    setBusyId(policy.id)
    const { data, error: rpcError } = await supabase.rpc('run_leave_accrual', {
      p_leave_type_id: policy.leave_type_id,
      p_period_key: periodKey.trim(),
    })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setNotice(`Accrual run complete — ${data ?? 0} employee(s) credited for ${periodKey.trim()}.`)
  }

  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-sm font-semibold text-ink">Leave accrual policies</h2>
          <p className="text-xs text-muted">Configure once, approve, then run for a period — never automatic.</p>
        </div>
        <button
          onClick={() => setFormOpen(true)}
          className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
        >
          Configure policy
        </button>
      </div>

      {error && (
        <p className="mb-3 rounded-lg bg-brand-risk-soft px-3 py-2 text-xs text-brand-risk-text">
          {error}{' '}
          <button className="underline" onClick={() => setError(null)}>
            Dismiss
          </button>
        </p>
      )}
      {notice && (
        <p className="mb-3 rounded-lg bg-brand-action-soft px-3 py-2 text-xs text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      {loading ? (
        <div className="h-16 animate-pulse rounded-lg bg-surface-alt" />
      ) : policies.length === 0 ? (
        <p className="text-sm text-muted">No accrual policies configured yet.</p>
      ) : (
        <ul className="space-y-2">
          {policies.map((p) => (
            <li key={p.id} className="rounded-lg bg-surface-alt px-3 py-2 text-xs">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="text-ink">
                  {p.leave_types?.name ?? 'Leave'} · {ACCRUAL_FREQUENCY_LABEL[p.frequency]} · {p.days_per_period} day(s)/period ·{' '}
                  {ACCRUAL_ROUNDING_LABEL[p.rounding]}
                  {p.max_balance_days ? ` · cap ${p.max_balance_days}d` : ''}
                  {p.probation_days ? ` · ${p.probation_days}d probation` : ''}
                </span>
                <StatusBadge status={p.is_approved ? 'approved' : 'pending'} tone={p.is_approved ? 'success' : 'warning'} />
              </div>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                {!p.is_approved && isOwner && (
                  <button
                    onClick={() => handleApprove(p.id)}
                    disabled={busyId === p.id}
                    className="rounded-full bg-brand-action-soft px-2.5 py-1 font-medium text-brand-action-text disabled:opacity-60"
                  >
                    {busyId === p.id ? 'Approving…' : 'Approve'}
                  </button>
                )}
                {!p.is_approved && !isOwner && <span className="text-muted">Awaiting Owner approval.</span>}
                {p.is_approved && (
                  <>
                    <input
                      value={runPeriodKey[p.id] ?? ''}
                      onChange={(e) => setRunPeriodKey((prev) => ({ ...prev, [p.id]: e.target.value }))}
                      placeholder={p.frequency === 'monthly' ? 'e.g. 2026-08' : 'e.g. 2026'}
                      className="w-28 rounded-lg border border-border px-2 py-1 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                    />
                    <button
                      onClick={() => handleRun(p)}
                      disabled={busyId === p.id}
                      className="rounded-lg bg-brand-blue px-3 py-1 font-medium text-white disabled:opacity-60"
                    >
                      {busyId === p.id ? 'Running…' : 'Run accrual'}
                    </button>
                  </>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}

      {formOpen && (
        <ConfigureAccrualPolicyModal
          leaveTypes={leaveTypes}
          onClose={() => setFormOpen(false)}
          onSaved={() => {
            setFormOpen(false)
            setNotice('Policy saved — it requires Owner approval before it can be run.')
            load()
          }}
        />
      )}
    </div>
  )
}

function ConfigureAccrualPolicyModal({
  leaveTypes,
  onClose,
  onSaved,
}: {
  leaveTypes: LeaveType[]
  onClose: () => void
  onSaved: () => void
}) {
  const [leaveTypeId, setLeaveTypeId] = useState(leaveTypes[0]?.id ?? '')
  const [frequency, setFrequency] = useState<'monthly' | 'annual'>('monthly')
  const [daysPerPeriod, setDaysPerPeriod] = useState(1)
  const [rounding, setRounding] = useState<'none' | 'nearest_half_day' | 'nearest_day'>('none')
  const [maxBalanceDays, setMaxBalanceDays] = useState('')
  const [carryForwardCapDays, setCarryForwardCapDays] = useState('')
  const [probationDays, setProbationDays] = useState(0)
  const [policyStartDate, setPolicyStartDate] = useState(new Date().toISOString().slice(0, 10))
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!leaveTypeId || daysPerPeriod <= 0) {
      setError('Choose a leave type and a positive accrual rate.')
      return
    }
    setSubmitting(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('configure_leave_accrual_policy', {
      p_leave_type_id: leaveTypeId,
      p_frequency: frequency,
      p_days_per_period: daysPerPeriod,
      p_rounding: rounding,
      p_max_balance_days: maxBalanceDays ? Number(maxBalanceDays) : null,
      p_carry_forward_cap_days: carryForwardCapDays ? Number(carryForwardCapDays) : null,
      p_probation_days: probationDays,
      p_policy_start_date: policyStartDate,
    })
    setSubmitting(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    onSaved()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">Configure accrual policy</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label className="mb-1 block text-sm font-medium text-ink">Leave type</label>
            <select
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
              <label className="mb-1 block text-sm font-medium text-ink">Frequency</label>
              <select
                value={frequency}
                onChange={(e) => setFrequency(e.target.value as 'monthly' | 'annual')}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              >
                <option value="monthly">Monthly</option>
                <option value="annual">Annual</option>
              </select>
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-ink">Days per period</label>
              <input
                type="number"
                step="0.01"
                min={0.01}
                value={daysPerPeriod}
                onChange={(e) => setDaysPerPeriod(Number(e.target.value))}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium text-ink">Rounding</label>
            <select
              value={rounding}
              onChange={(e) => setRounding(e.target.value as 'none' | 'nearest_half_day' | 'nearest_day')}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="none">No rounding</option>
              <option value="nearest_half_day">Nearest half day</option>
              <option value="nearest_day">Nearest day</option>
            </select>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="mb-1 block text-sm font-medium text-ink">Max balance (optional)</label>
              <input
                type="number"
                value={maxBalanceDays}
                onChange={(e) => setMaxBalanceDays(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-ink">Carry-forward cap (optional)</label>
              <input
                type="number"
                value={carryForwardCapDays}
                onChange={(e) => setCarryForwardCapDays(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="mb-1 block text-sm font-medium text-ink">Probation (days)</label>
              <input
                type="number"
                min={0}
                value={probationDays}
                onChange={(e) => setProbationDays(Number(e.target.value))}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-ink">Effective from</label>
              <input
                type="date"
                value={policyStartDate}
                onChange={(e) => setPolicyStartDate(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>

          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <p className="text-xs text-muted">Saving requires a separate Owner approval before it can be run — this never activates automatically.</p>

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Saving…' : 'Save policy'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Admin / manager decision queue
// ---------------------------------------------------------------------------

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
    if (fetchError) setError(fetchError.message)
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
    setBusyId(id)
    setError(null)
    const { error: rpcError } = await supabase.rpc('approve_leave_request', {
      p_request_id: id,
      p_action: action,
      p_override: override,
      p_override_reason: reason ?? null,
    })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
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
        <p className="text-xs font-semibold uppercase tracking-wider text-muted">Third State Café</p>
        <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Leave</h1>
        <p className="text-xs text-muted">{loading ? 'Loading…' : `${pending.length} pending`}</p>
      </div>

      {error && (
        <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">
          {error}{' '}
          <button className="underline" onClick={() => setError(null)}>
            Dismiss
          </button>
        </p>
      )}
      {notice && (
        <p className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
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
                            Insufficient balance — approving is blocked{canOverride ? ' unless you use an authorised override' : ' until the balance is adjusted or the request is reduced'}.
                          </p>
                        )}
                        {r.reason && <p className="mt-1 text-xs text-muted">“{r.reason}”</p>}
                      </div>
                      <span className="flex gap-1">
                        {!insufficient && (
                          <button
                            onClick={() => handleDecide(r.id, 'approve')}
                            disabled={busyId === r.id}
                            className="rounded-full bg-brand-action-soft px-2.5 py-1 text-xs font-medium text-brand-action-text disabled:opacity-60"
                          >
                            {busyId === r.id ? 'Working…' : 'Approve'}
                          </button>
                        )}
                        {insufficient && canOverride && (
                          <button
                            onClick={() => setOverridingId(overridingId === r.id ? null : r.id)}
                            disabled={busyId === r.id}
                            className="rounded-full bg-brand-risk-soft px-2.5 py-1 text-xs font-medium text-brand-risk-text disabled:opacity-60"
                          >
                            Override & approve…
                          </button>
                        )}
                        <button
                          onClick={() => handleDecide(r.id, 'reject')}
                          disabled={busyId === r.id}
                          className="rounded-full bg-brand-risk-soft px-2.5 py-1 text-xs font-medium text-brand-risk-text disabled:opacity-60"
                        >
                          Reject
                        </button>
                      </span>
                    </div>
                    {overridingId === r.id && (
                      <div className="mt-2 flex flex-wrap items-center gap-2 rounded-lg bg-surface px-3 py-2">
                        <input
                          type="text"
                          value={overrideReason}
                          onChange={(e) => setOverrideReason(e.target.value)}
                          placeholder="Reason for overriding the balance check (required)"
                          className="min-w-[220px] flex-1 rounded-lg border border-border px-2.5 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                        />
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
    if (balRes.error) setError(balRes.error.message)
    else setBalances((balRes.data ?? []) as unknown as LeaveBalance[])
    setLeaveTypes((typesRes.data ?? []) as LeaveType[])
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
    if (!confirm('Cancel this leave request? Any balance held for it will be released.')) return
    setBusyId(id)
    setError(null)
    const { error: rpcError } = await supabase.rpc('cancel_leave_request', { p_request_id: id, p_reason: null })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
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
          <p className="text-xs font-semibold uppercase tracking-wider text-muted">Third State Café</p>
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">My leave</h1>
        </div>
        <button
          onClick={() => setFormOpen(true)}
          disabled={leaveTypes.length === 0}
          className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
        >
          Request leave
        </button>
      </div>

      {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
      {notice && (
        <p className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Balances</h2>
        {leaveTypes.length === 0 ? (
          <p className="text-sm text-muted">No leave types configured for your entity yet.</p>
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
                        className="font-medium text-brand-risk hover:underline disabled:opacity-60"
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
  onClose,
  onSubmitted,
}: {
  leaveTypes: LeaveType[]
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

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
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
      setError(empError?.message ?? 'No employee record linked to your account.')
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
      setError(insertError.message)
      return
    }
    onSubmitted()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">Request leave</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label className="mb-1 block text-sm font-medium text-ink">Leave type</label>
            <select
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
              <label className="mb-1 block text-sm font-medium text-ink">Start date</label>
              <input
                type="date"
                value={startDate}
                onChange={(e) => setStartDate(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-ink">End date</label>
              <input
                type="date"
                value={endDate}
                onChange={(e) => setEndDate(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          {days > 0 && <p className="text-xs text-muted">{days} day{days === 1 ? '' : 's'} requested.</p>}
          <div>
            <label className="mb-1 block text-sm font-medium text-ink">Reason (optional)</label>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={2}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>

          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Submitting…' : 'Submit request'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
