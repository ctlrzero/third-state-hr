import { useEffect, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { StatusBadge } from './StatusBadge'
import type { LeaveAccrualPolicy, LeaveType } from '../types/db'

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
export function AccrualPolicyPanel({
  leaveTypes,
  isOwner,
  entityId,
}: {
  leaveTypes: LeaveType[]
  isOwner: boolean
  /** Owner sees every entity under RLS — pass the switcher's entity to scope the list. */
  entityId?: string | null
}) {
  const [policies, setPolicies] = useState<LeaveAccrualPolicy[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [runPeriodKey, setRunPeriodKey] = useState<Record<string, string>>({})

  async function load() {
    setLoading(true)
    let q = supabase.from('leave_accrual_policies').select('*, leave_types(id, name)').order('created_at', { ascending: false })
    if (entityId) q = q.eq('entity_id', entityId)
    const { data, error: fetchError } = await q
    if (fetchError) setError(fetchError.message)
    else setPolicies((data ?? []) as unknown as LeaveAccrualPolicy[])
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entityId])

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
          <p className="mt-1 inline-flex rounded-full bg-brand-warning-soft px-2 py-0.5 text-xs font-semibold text-brand-warning-solid">
            Seeded leave values are configurable — pending HR/legal approval
          </p>
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
