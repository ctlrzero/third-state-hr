import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import MyPayslips from './MyPayslips'
import { buildPayslipPdf, payslipFilename } from '../lib/payslipPdf'
import { getPayrollPayslip } from '../lib/api/payslips'
import { addEmployeesToPayrollRun, listPayRates } from '../lib/api/compensation'
import { employeesMissingPay } from '../lib/compensation'
import { Alert } from '../components/ui'
import { downloadBytes } from '../lib/pdf'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import type {
  Employee,
  Location,
  Payslip,
  PayslipDeduction,
  PayrollRun,
  PayrollRunStatus,
  PayrollRunTotals,
  TimesheetEntry,
  TipDistributionRule,
  TipsPool,
} from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'
import { confirmDialog } from '../lib/confirm'

const TIP_RULES: { value: TipDistributionRule; label: string }[] = [
  { value: 'equal', label: 'Split equally' },
  { value: 'hours_weighted', label: 'Weighted by hours' },
  { value: 'role_weighted', label: 'Weighted by role' },
]

// Mirrors payslip_deductions_deduction_type_check — the DB only accepts
// these four values, so the form uses a dropdown rather than free text.
const DEDUCTION_TYPES: { value: string; label: string }[] = [
  { value: 'uniform', label: 'Uniform' },
  { value: 'cash_shortage', label: 'Cash shortage' },
  { value: 'advance', label: 'Advance repayment' },
  { value: 'other', label: 'Other' },
]

// Forward-only status progression, matching the DB trigger
// (prevent_payroll_run_status_regression): once a run is approved or paid
// it can never move back to draft/in_review. This UI never offers a
// backwards transition in the first place.
const NEXT_STATUS: Record<PayrollRunStatus, PayrollRunStatus | null> = {
  draft: 'in_review',
  in_review: 'approved',
  approved: 'paid',
  paid: null,
}

const NEXT_STATUS_LABEL: Record<PayrollRunStatus, string> = {
  draft: 'Send to review',
  in_review: 'Approve run',
  approved: 'Mark as paid',
  paid: '',
}

// Shape returned by every payroll mutation RPC (record_timesheet_entry,
// delete_timesheet_entry, record_tips_pool, delete_tips_pool,
// record_payslip_deduction, delete_payslip_deduction). The RPC always
// completes successfully at the transport level -- ok=false means the
// action was rejected (e.g. the run is locked), not that the call failed.
// The client must check `ok` explicitly rather than only checking for a
// Supabase/PostgREST-level error.
interface PayrollRpcResult {
  ok: boolean
  code?: string
  message?: string
  request_id?: string
  id?: string
}

function rpcErrorMessage(result: PayrollRpcResult | null | undefined, fallback: string): string {
  if (!result) return fallback
  if (result.ok) return ''
  return result.message || fallback
}

function deductionTypeLabel(value: string) {
  return DEDUCTION_TYPES.find((t) => t.value === value)?.label ?? value
}

function money(n: number | null | undefined, currency: string) {
  const value = n ?? 0
  try {
    return new Intl.NumberFormat('en-AE', { style: 'currency', currency }).format(value)
  } catch {
    return value.toFixed(2)
  }
}

// UX Payroll module. Owner/Entity Admin get the full run-management screen
// (create runs, enter timesheets and tips, confirm OT/holiday and tip
// distribution, calculate, progress status, review payslips). Staff get a
// read-only "My Pay" history of their own payslips. Location Manager has no
// Payroll nav entry at all — their timesheet-entry RLS access is meant to be
// exercised from the future Schedules module, not here.
export default function Payroll() {
  const { profile, activeEntityId, entities } = useAuth()
  const isManager = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const currency = entities.find((e) => e.id === activeEntityId)?.default_currency || 'AED'

  if (isManager) {
    return <PayrollManager activeEntityId={activeEntityId} currency={currency} />
  }
  // Staff: own published payslips with PDF download (get_my_payslips).
  return <MyPayslips />
}

// ---------------------------------------------------------------------------
// Owner / Entity Admin: payroll run management
// ---------------------------------------------------------------------------

function PayrollManager({ activeEntityId, currency }: { activeEntityId: string | null; currency: string }) {
  const [runs, setRuns] = useState<PayrollRunTotals[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [selectedRunId, setSelectedRunId] = useState<string | null>(null)

  async function load() {
    if (!activeEntityId) return
    setLoading(true)
    setError(null)
    const { data, error: fetchError } = await supabase
      .from('payroll_run_totals')
      .select('*')
      .eq('entity_id', activeEntityId)
      .order('period_start', { ascending: false })
    if (fetchError) setError(fetchError.message)
    else setRuns((data ?? []) as PayrollRunTotals[])
    setLoading(false)
  }

  useEffect(() => {
    load()
    setSelectedRunId(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeEntityId])

  const selectedRun = runs.find((r) => r.payroll_run_id === selectedRunId) ?? null

  if (selectedRun) {
    return (
      <PayrollRunDetail
        summary={selectedRun}
        currency={currency}
        onBack={() => {
          setSelectedRunId(null)
          load()
        }}
        onNotice={setNotice}
      />
    )
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Payroll</h1>
          <p className="text-xs text-muted">{loading ? 'Loading…' : `${runs.length} payroll run${runs.length === 1 ? '' : 's'}`}</p>
        </div>
        <button
          onClick={() => setCreateOpen(true)}
          className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark"
        >
          New payroll run
        </button>
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
      ) : runs.length === 0 ? (
        <EmptyState title="No payroll runs yet" description="Start a new payroll run for a pay period to begin." />
      ) : (
        <>
          <div className="hidden overflow-hidden rounded-[14px] border border-border bg-surface shadow-card md:block">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-surface-alt text-xs uppercase tracking-wide text-muted">
                <tr>
                  <th className="px-4 py-3 font-medium">Period</th>
                  <th className="px-4 py-3 font-medium">Status</th>
                  <th className="px-4 py-3 font-medium">Employees</th>
                  <th className="px-4 py-3 font-medium">Net pay</th>
                  <th className="px-4 py-3 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {runs.map((run) => (
                  <tr key={run.payroll_run_id} className="hover:bg-surface-alt/60">
                    <td className="px-4 py-3 font-medium text-ink">
                      {run.period_start} – {run.period_end}
                    </td>
                    <td className="px-4 py-3">
                      <StatusBadge status={run.status} />
                    </td>
                    <td className="px-4 py-3 text-muted">{run.employee_count}</td>
                    <td className="px-4 py-3 text-muted">{money(run.total_net_pay, currency)}</td>
                    <td className="px-4 py-3 text-right">
                      <button
                        onClick={() => setSelectedRunId(run.payroll_run_id)}
                        className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                      >
                        Open
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <ul className="space-y-3 md:hidden">
            {runs.map((run) => (
              <li key={run.payroll_run_id} className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
                <div className="flex items-start justify-between gap-2">
                  <p className="font-medium text-ink">
                    {run.period_start} – {run.period_end}
                  </p>
                  <StatusBadge status={run.status} />
                </div>
                <p className="mt-1 text-xs text-muted">
                  {run.employee_count} employees · {money(run.total_net_pay, currency)} net
                </p>
                <button
                  onClick={() => setSelectedRunId(run.payroll_run_id)}
                  className="mt-3 w-full rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue"
                >
                  Open
                </button>
              </li>
            ))}
          </ul>
        </>
      )}

      {createOpen && activeEntityId && (
        <NewRunModal
          entityId={activeEntityId}
          onClose={() => setCreateOpen(false)}
          onCreated={() => {
            setCreateOpen(false)
            load()
          }}
        />
      )}
    </div>
  )
}

function NewRunModal({
  entityId,
  onClose,
  onCreated,
}: {
  entityId: string
  onClose: () => void
  onCreated: () => void
}) {
  const [periodStart, setPeriodStart] = useState('')
  const [periodEnd, setPeriodEnd] = useState('')
  const [tipRule, setTipRule] = useState<TipDistributionRule>('equal')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!periodStart || !periodEnd) {
      setError('Choose a start and end date.')
      return
    }
    if (periodEnd < periodStart) {
      setError('End date must be on or after the start date.')
      return
    }
    setSubmitting(true)
    setError(null)
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const { error: insertError } = await supabase.from('payroll_runs').insert({
      entity_id: entityId,
      period_start: periodStart,
      period_end: periodEnd,
      tip_distribution_rule: tipRule,
      created_by: user?.id ?? null,
    })
    setSubmitting(false)
    if (insertError) {
      setError(insertError.message)
      return
    }
    onCreated()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">New payroll run</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label htmlFor="payroll-period-start-1" className="mb-1 block text-sm font-medium text-ink">Period start</label>
              <input id="payroll-period-start-1"
                type="date"
                required
                value={periodStart}
                onChange={(e) => setPeriodStart(e.target.value)}
                className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="payroll-period-end-2" className="mb-1 block text-sm font-medium text-ink">Period end</label>
              <input id="payroll-period-end-2"
                type="date"
                required
                value={periodEnd}
                onChange={(e) => setPeriodEnd(e.target.value)}
                className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          <div>
            <label htmlFor="payroll-tip-distribution-rule-3" className="mb-1 block text-sm font-medium text-ink">Tip distribution rule</label>
            <select id="payroll-tip-distribution-rule-3"
              value={tipRule}
              onChange={(e) => setTipRule(e.target.value as TipDistributionRule)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {TIP_RULES.map((r) => (
                <option key={r.value} value={r.value}>
                  {r.label}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-muted">
              Currently only "Split equally" is applied by the calculation engine; the others are recorded for
              future use.
            </p>
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
              {submitting ? 'Creating…' : 'Create run'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Payroll run detail
// ---------------------------------------------------------------------------

function PayrollRunDetail({
  summary,
  currency,
  onBack,
  onNotice,
}: {
  summary: PayrollRunTotals
  currency: string
  onBack: () => void
  onNotice: (msg: string) => void
}) {
  const [run, setRun] = useState<PayrollRun | null>(null)
  const [employees, setEmployees] = useState<Pick<Employee, 'id' | 'full_name'>[]>([])
  const [locations, setLocations] = useState<Pick<Location, 'id' | 'name'>[]>([])
  const [timesheets, setTimesheets] = useState<TimesheetEntry[]>([])
  const [tipsPools, setTipsPools] = useState<TipsPool[]>([])
  const [payslips, setPayslips] = useState<Payslip[]>([])
  const [deductions, setDeductions] = useState<PayslipDeduction[]>([])
  const [payRates, setPayRates] = useState<{ employee_id: string; pay_rate: number | null }[] | null>(null)
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const runId = summary.payroll_run_id
  // Draft-only editable, per the payroll immutability model: timesheets, tips and
  // deductions can only be entered/changed while the run is Draft. In-review runs
  // are read-only (a deliberate tightening from the earlier draft/in_review-editable
  // behavior -- see README). Corrections to an approved/paid run go through
  // create_payroll_revision(), which opens a brand-new linked Draft run.
  const editable = run ? run.status === 'draft' : false
  const canCreateRevision = run ? run.status === 'approved' || run.status === 'paid' : false
  const [revisionBusy, setRevisionBusy] = useState(false)

  async function handleCreateRevision() {
    if (!run) return
    if (!(await confirmDialog('Create a new draft revision of this run for corrections? The original run and its payslips stay unchanged.'))) {
      return
    }
    setRevisionBusy(true)
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('create_payroll_revision', { p_source_run_id: runId })
    setRevisionBusy(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    onNotice('Revision run created — open it from the payroll runs list to make corrections.')
    void data
    onBack()
  }

  async function downloadAdminPayslip(p: Payslip) {
    // Same document as the staff PDF: get_payroll_payslip returns the
    // get_my_payslip shape (real version, position, branch, pay basis) and
    // audits the view. Owner: any entity; Entity Admin: own entity only.
    setError(null)
    const res = await getPayrollPayslip(p.id)
    if (res.error || !res.data) {
      setError(res.error ?? 'Could not load the payslip.')
      return
    }
    downloadBytes(buildPayslipPdf(res.data), payslipFilename(res.data))
  }

  async function load() {
    setLoading(true)
    setError(null)
    const [runRes, empRes, locRes, tsRes, tipsRes, payslipRes, dedRes] = await Promise.all([
      supabase.from('payroll_runs').select('*').eq('id', runId).single(),
      supabase.from('employees').select('id, full_name').eq('entity_id', summary.entity_id).order('full_name'),
      supabase.from('locations').select('id, name').eq('entity_id', summary.entity_id).order('name'),
      supabase
        .from('timesheet_entries')
        .select('id, payroll_run_id, employee_id, regular_hours, overtime_hours, holiday_hours, notes, employees(id, full_name)')
        .eq('payroll_run_id', runId),
      supabase
        .from('tips_pools')
        .select('id, payroll_run_id, location_id, total_amount, notes, updated_at, locations(id, name)')
        .eq('payroll_run_id', runId),
      supabase
        .from('payslips')
        .select('id, payroll_run_id, employee_id, base_pay, overtime_pay, holiday_pay, tips_share, total_deductions, net_pay, generated_at, employees(id, full_name)')
        .eq('payroll_run_id', runId),
      supabase
        .from('payslip_deductions')
        .select('id, payroll_run_id, employee_id, deduction_type, amount, notes, created_at, employees(id, full_name)')
        .eq('payroll_run_id', runId),
    ])

    if (runRes.error) setError(runRes.error.message)
    else setRun(runRes.data as PayrollRun)
    setEmployees(empRes.data ?? [])
    setLocations(locRes.data ?? [])
    setTimesheets((tsRes.data ?? []) as unknown as TimesheetEntry[])
    setTipsPools((tipsRes.data ?? []) as unknown as TipsPool[])
    setPayslips((payslipRes.data ?? []) as unknown as Payslip[])
    setDeductions((dedRes.data ?? []) as unknown as PayslipDeduction[])
    setLoading(false)
    // Pay rates of everyone in the run, to warn about AED 0 payslips.
    const ids = ((tsRes.data ?? []) as { employee_id: string }[]).map((t) => t.employee_id)
    const rates = await listPayRates(ids)
    setPayRates(rates.error ? null : rates.data)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runId])

  async function handleAdvanceStatus() {
    if (!run) return
    const next = run.status === 'draft' ? 'in_review' : run.status === 'in_review' ? 'approved' : 'paid'
    if (
      next === 'approved' &&
      !(await confirmDialog(
        'Approving locks this run: timesheets, tips and the calculation can no longer be changed. Continue?'
      ))
    ) {
      return
    }
    setBusy(true)
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const patch: Record<string, unknown> = { status: next }
    if (next === 'approved') {
      patch.approved_by = user?.id ?? null
      patch.approved_at = new Date().toISOString()
    }
    const { error: updateError } = await supabase.from('payroll_runs').update(patch).eq('id', runId)
    setBusy(false)
    if (updateError) {
      setError(updateError.message)
      return
    }
    onNotice(`Run moved to ${next.replace('_', ' ')}.`)
    load()
  }

  async function handleToggleConfirm(field: 'overtime_holiday_pay_confirmed' | 'tips_distribution_confirmed') {
    if (!run) return
    const { error: updateError } = await supabase
      .from('payroll_runs')
      .update({ [field]: !run[field] })
      .eq('id', runId)
    if (updateError) {
      setError(updateError.message)
      return
    }
    load()
  }

  async function handleCalculate() {
    setBusy(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('run_payroll_calculation', { p_payroll_run_id: runId })
    setBusy(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    onNotice('Payroll calculated.')
    load()
  }

  if (loading || !run) {
    return (
      <div className="space-y-3">
        <button onClick={onBack} className="text-sm text-brand-blue hover:underline">
          ← Back to payroll runs
        </button>
        <div className="h-40 animate-pulse rounded-[14px] bg-surface" />
      </div>
    )
  }

  const totalNet = payslips.reduce((sum, p) => sum + Number(p.net_pay), 0)
  const missingPay = payRates
    ? employeesMissingPay(
        timesheets.map((t) => ({ employee_id: t.employee_id, name: t.employees?.full_name ?? 'Unknown employee' })),
        payRates
      )
    : []

  return (
    <div className="space-y-5">
      <button onClick={onBack} className="text-sm text-brand-blue hover:underline">
        ← Back to payroll runs
      </button>

      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-normal text-ink">
            {run.period_start} – {run.period_end}
          </h1>
          <div className="mt-1 flex items-center gap-2">
            <StatusBadge status={run.status} />
            <span className="text-xs text-muted">{TIP_RULES.find((r) => r.value === run.tip_distribution_rule)?.label}</span>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {canCreateRevision && (
            <button
              onClick={handleCreateRevision}
              disabled={revisionBusy}
              className="rounded-lg border border-brand-blue px-4 py-2 text-sm font-medium text-brand-blue hover:bg-brand-blue/5 disabled:opacity-60"
            >
              {revisionBusy ? 'Creating…' : 'Create revision for corrections'}
            </button>
          )}
          {NEXT_STATUS[run.status] && (
            <button
              onClick={handleAdvanceStatus}
              disabled={busy}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {NEXT_STATUS_LABEL[run.status]}
            </button>
          )}
        </div>
      </div>

      {error && (
        <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">
          {error}{' '}
          <button className="underline" onClick={() => setError(null)}>
            Dismiss
          </button>
        </p>
      )}

      {!editable && (
        <p className="rounded-lg bg-surface-alt px-3 py-2 text-xs text-muted">
          {run.status === 'in_review'
            ? 'This run is in review — timesheets, tips and deductions are locked while it awaits approval.'
            : `This run is ${run.status} — timesheets, tips and deductions are permanently locked.`}{' '}
          {canCreateRevision
            ? 'Use "Create revision for corrections" above to open a new draft run seeded from this one.'
            : 'Corrections require a new payroll run.'}
        </p>
      )}

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="flex items-center gap-2 rounded-[14px] border border-border bg-surface p-4 text-sm shadow-card">
          <input
            type="checkbox"
            checked={run.overtime_holiday_pay_confirmed}
            disabled={!editable}
            onChange={() => handleToggleConfirm('overtime_holiday_pay_confirmed')}
            className="h-4 w-4 rounded border-border"
          />
          <span>
            <span className="font-medium text-ink">Overtime & holiday pay confirmed</span>
            <br />
            <span className="text-xs text-muted">Required before overtime/holiday multipliers apply in the calculation.</span>
          </span>
        </label>
        <label className="flex items-center gap-2 rounded-[14px] border border-border bg-surface p-4 text-sm shadow-card">
          <input
            type="checkbox"
            checked={run.tips_distribution_confirmed}
            disabled={!editable}
            onChange={() => handleToggleConfirm('tips_distribution_confirmed')}
            className="h-4 w-4 rounded border-border"
          />
          <span>
            <span className="font-medium text-ink">Tips distribution confirmed</span>
            <br />
            <span className="text-xs text-muted">Required before pooled tips are shared out in the calculation.</span>
          </span>
        </label>
      </div>

      <TimesheetSection
        entries={timesheets}
        employees={employees}
        runId={runId}
        editable={editable}
        onChange={load}
        onNotice={onNotice}
      />

      <TipsPoolSection
        pools={tipsPools}
        locations={locations}
        runId={runId}
        editable={editable}
        currency={currency}
        onChange={load}
      />

      <DeductionsSection
        deductions={deductions}
        employees={employees}
        runId={runId}
        editable={editable}
        currency={currency}
        onChange={load}
      />

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm font-semibold text-ink">Payslips</h2>
          {editable && (
            <button
              onClick={handleCalculate}
              disabled={busy || timesheets.length === 0}
              className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {busy ? 'Calculating…' : payslips.length > 0 ? 'Recalculate' : 'Run calculation'}
            </button>
          )}
        </div>
        {missingPay.length > 0 && (
          <div className="mb-3">
            <Alert tone="warning">
              <span className="font-semibold">Pay not set for {missingPay.length === 1 ? '1 employee' : `${missingPay.length} employees`}</span> — they will
              get AED 0 base pay: {missingPay.join(', ')}. Set pay on each employee's profile (Employment tab), then recalculate.
            </Alert>
          </div>
        )}
        {payslips.length === 0 ? (
          <p className="text-sm text-muted">
            {timesheets.length === 0
              ? 'Add timesheet entries, then run the calculation.'
              : 'No payslips yet — run the calculation to generate them.'}
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="table-stack w-full text-left text-sm">
              <thead className="border-b border-border text-xs uppercase tracking-wide text-muted">
                <tr>
                  <th className="py-2 pr-3 font-medium">Employee</th>
                  <th className="py-2 pr-3 font-medium">Base</th>
                  <th className="py-2 pr-3 font-medium">Overtime</th>
                  <th className="py-2 pr-3 font-medium">Holiday</th>
                  <th className="py-2 pr-3 font-medium">Tips</th>
                  <th className="py-2 pr-3 font-medium">Deductions</th>
                  <th className="py-2 pr-3 font-medium">Net pay</th>
                  <th className="py-2 pr-3 font-medium">
                    <span className="sr-only">Payslip PDF</span>
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {payslips.map((p) => (
                  <tr key={p.id}>
                    <td data-label="Employee" className="py-2 pr-3 font-medium text-ink">{p.employees?.full_name ?? '—'}</td>
                    <td data-label="Base" className="py-2 pr-3 text-muted">{money(p.base_pay, currency)}</td>
                    <td data-label="Overtime" className="py-2 pr-3 text-muted">{money(p.overtime_pay, currency)}</td>
                    <td data-label="Holiday" className="py-2 pr-3 text-muted">{money(p.holiday_pay, currency)}</td>
                    <td data-label="Tips" className="py-2 pr-3 text-muted">{money(p.tips_share, currency)}</td>
                    <td data-label="Deductions" className="py-2 pr-3 text-muted">{money(p.total_deductions, currency)}</td>
                    <td data-label="Net pay" className="py-2 pr-3 font-semibold text-ink">{money(p.net_pay, currency)}</td>
                    <td data-label="" className="py-2 pr-3 text-right">
                      <button
                        type="button"
                        onClick={() => void downloadAdminPayslip(p)}
                        disabled={!run || (run.status !== 'approved' && run.status !== 'paid')}
                        title={run && run.status !== 'approved' && run.status !== 'paid' ? 'Available once the run is approved' : undefined}
                        aria-label={`Download payslip PDF for ${p.employees?.full_name ?? 'employee'}`}
                        className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30 disabled:opacity-60"
                      >
                        PDF
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="border-t border-border font-semibold text-ink">
                  <td data-label="" className="py-2 pr-3 max-md:hidden" colSpan={6}>
                    Total net pay
                  </td>
                  <td data-label="Total net pay" className="py-2 pr-3">{money(totalNet, currency)}</td>
                  <td data-label="" className="max-md:hidden" />
                </tr>
              </tfoot>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Timesheet entries
// ---------------------------------------------------------------------------

function TimesheetSection({
  entries,
  employees,
  runId,
  editable,
  onChange,
  onNotice,
}: {
  entries: TimesheetEntry[]
  employees: Pick<Employee, 'id' | 'full_name'>[]
  runId: string
  editable: boolean
  onChange: () => void
  onNotice: (msg: string) => void
}) {
  const [adding, setAdding] = useState(false)
  const [employeeId, setEmployeeId] = useState('')
  const [regular, setRegular] = useState('')
  const [overtime, setOvertime] = useState('')
  const [holiday, setHoliday] = useState('')
  const [error, setError] = useState<string | null>(null)

  const availableEmployees = useMemo(
    () => employees.filter((e) => !entries.some((t) => t.employee_id === e.id)),
    [employees, entries]
  )

  async function handleAdd(e: FormEvent) {
    e.preventDefault()
    if (!employeeId) {
      setError('Choose an employee.')
      return
    }
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('record_timesheet_entry', {
      p_payroll_run_id: runId,
      p_employee_id: employeeId,
      p_regular_hours: Number(regular) || 0,
      p_overtime_hours: Number(overtime) || 0,
      p_holiday_hours: Number(holiday) || 0,
    })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const result = data as PayrollRpcResult
    if (!result.ok) {
      setError(rpcErrorMessage(result, 'Could not add this timesheet entry.'))
      return
    }
    setEmployeeId('')
    setRegular('')
    setOvertime('')
    setHoliday('')
    onChange()
  }

  // Monthly-salaried staff have no hours but still need a row in the run to
  // get a payslip; add_employees_to_payroll_run adds every active employee
  // of the entity who is missing (0 hours, audited like a manual entry).
  async function handleAddAll() {
    setAdding(true)
    setError(null)
    const res = await addEmployeesToPayrollRun(runId)
    setAdding(false)
    if (res.error) {
      setError(res.error)
      return
    }
    const n = res.data ?? 0
    onNotice(n === 0 ? 'All active employees are already in this run.' : `Added ${n} employee${n === 1 ? '' : 's'}.`)
    onChange()
  }

  async function handleDelete(id: string) {
    const { data, error: rpcError } = await supabase.rpc('delete_timesheet_entry', { p_entry_id: id })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const result = data as PayrollRpcResult
    if (!result.ok) {
      setError(rpcErrorMessage(result, 'Could not remove this timesheet entry.'))
      return
    }
    onChange()
  }

  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-ink">Timesheets</h2>
        {editable && (
          <button
            type="button"
            onClick={handleAddAll}
            disabled={adding}
            className="rounded-lg border border-brand-blue px-3 py-1.5 text-xs font-medium text-brand-blue hover:bg-brand-blue/5 disabled:opacity-60"
          >
            {adding ? 'Adding…' : 'Add all active employees'}
          </button>
        )}
      </div>
      {entries.length === 0 ? (
        <p className="mb-3 text-sm text-muted">No hours recorded for this run yet.</p>
      ) : (
        <div className="mb-3 overflow-x-auto">
          <table className="table-stack w-full text-left text-sm">
            <thead className="border-b border-border text-xs uppercase tracking-wide text-muted">
              <tr>
                <th className="py-2 pr-3 font-medium">Employee</th>
                <th className="py-2 pr-3 font-medium">Regular</th>
                <th className="py-2 pr-3 font-medium">Overtime</th>
                <th className="py-2 pr-3 font-medium">Holiday</th>
                {editable && <th className="py-2 pr-3 font-medium text-right">Actions</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {entries.map((t) => (
                <tr key={t.id}>
                  <td data-label="Employee" className="py-2 pr-3 font-medium text-ink">{t.employees?.full_name ?? '—'}</td>
                  <td data-label="Regular" className="py-2 pr-3 text-muted">{t.regular_hours}</td>
                  <td data-label="Overtime" className="py-2 pr-3 text-muted">{t.overtime_hours}</td>
                  <td data-label="Holiday" className="py-2 pr-3 text-muted">{t.holiday_hours}</td>
                  {editable && (
                    <td data-label="Actions" className="py-2 pr-3 text-right">
                      <button onClick={() => handleDelete(t.id)} className="text-xs font-medium text-brand-risk-text hover:underline">
                        Remove
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {editable && availableEmployees.length > 0 && (
        <form onSubmit={handleAdd} className="flex flex-wrap items-end gap-2">
          <div>
            <label htmlFor="payroll-employee-4" className="mb-1 block text-xs font-medium text-ink">Employee</label>
            <select id="payroll-employee-4"
              value={employeeId}
              onChange={(e) => setEmployeeId(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="">Select…</option>
              {availableEmployees.map((emp) => (
                <option key={emp.id} value={emp.id}>
                  {emp.full_name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="payroll-regular-hrs-5" className="mb-1 block text-xs font-medium text-ink">Regular hrs</label>
            <input id="payroll-regular-hrs-5"
              type="number"
              min="0"
              step="0.25"
              value={regular}
              onChange={(e) => setRegular(e.target.value)}
              className="w-24 rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <div>
            <label htmlFor="payroll-overtime-hrs-6" className="mb-1 block text-xs font-medium text-ink">Overtime hrs</label>
            <input id="payroll-overtime-hrs-6"
              type="number"
              min="0"
              step="0.25"
              value={overtime}
              onChange={(e) => setOvertime(e.target.value)}
              className="w-24 rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <div>
            <label htmlFor="payroll-holiday-hrs-7" className="mb-1 block text-xs font-medium text-ink">Holiday hrs</label>
            <input id="payroll-holiday-hrs-7"
              type="number"
              min="0"
              step="0.25"
              value={holiday}
              onChange={(e) => setHoliday(e.target.value)}
              className="w-24 rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <button
            type="submit"
            className="rounded-lg bg-brand-blue px-3 py-2 text-xs font-medium text-white hover:bg-brand-blue-dark"
          >
            Add
          </button>
        </form>
      )}
      {error && <p className="mt-2 text-xs text-brand-risk-text">{error}</p>}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Tips pools
// ---------------------------------------------------------------------------

function TipsPoolSection({
  pools,
  locations,
  runId,
  editable,
  currency,
  onChange,
}: {
  pools: TipsPool[]
  locations: Pick<Location, 'id' | 'name'>[]
  runId: string
  editable: boolean
  currency: string
  onChange: () => void
}) {
  const [locationId, setLocationId] = useState('')
  const [amount, setAmount] = useState('')
  const [error, setError] = useState<string | null>(null)

  const availableLocations = useMemo(
    () => locations.filter((l) => !pools.some((p) => p.location_id === l.id)),
    [locations, pools]
  )

  async function handleAdd(e: FormEvent) {
    e.preventDefault()
    if (!locationId) {
      setError('Choose a location.')
      return
    }
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('record_tips_pool', {
      p_payroll_run_id: runId,
      p_location_id: locationId,
      p_total_amount: Number(amount) || 0,
    })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const result = data as PayrollRpcResult
    if (!result.ok) {
      setError(rpcErrorMessage(result, 'Could not add this tips pool.'))
      return
    }
    setLocationId('')
    setAmount('')
    onChange()
  }

  async function handleDelete(id: string) {
    const { data, error: rpcError } = await supabase.rpc('delete_tips_pool', { p_pool_id: id })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const result = data as PayrollRpcResult
    if (!result.ok) {
      setError(rpcErrorMessage(result, 'Could not remove this tips pool.'))
      return
    }
    onChange()
  }

  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <h2 className="mb-3 text-sm font-semibold text-ink">Tips pools</h2>
      {pools.length === 0 ? (
        <p className="mb-3 text-sm text-muted">No pooled tips recorded for this run yet.</p>
      ) : (
        <ul className="mb-3 space-y-1.5">
          {pools.map((p) => (
            <li key={p.id} className="flex items-center justify-between rounded-lg bg-surface-alt px-3 py-2 text-sm">
              <span className="text-ink">{p.locations?.name ?? '—'}</span>
              <span className="flex items-center gap-3">
                <span className="text-muted">{money(p.total_amount, currency)}</span>
                {editable && (
                  <button onClick={() => handleDelete(p.id)} className="text-xs font-medium text-brand-risk-text hover:underline">
                    Remove
                  </button>
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
      {editable && availableLocations.length > 0 && (
        <form onSubmit={handleAdd} className="flex flex-wrap items-end gap-2">
          <div>
            <label htmlFor="payroll-location-8" className="mb-1 block text-xs font-medium text-ink">Location</label>
            <select id="payroll-location-8"
              value={locationId}
              onChange={(e) => setLocationId(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="">Select…</option>
              {availableLocations.map((loc) => (
                <option key={loc.id} value={loc.id}>
                  {loc.name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="payroll-pool-total-9" className="mb-1 block text-xs font-medium text-ink">Pool total</label>
            <input id="payroll-pool-total-9"
              type="number"
              min="0"
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="w-32 rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <button
            type="submit"
            className="rounded-lg bg-brand-blue px-3 py-2 text-xs font-medium text-white hover:bg-brand-blue-dark"
          >
            Add
          </button>
        </form>
      )}
      {error && <p className="mt-2 text-xs text-brand-risk-text">{error}</p>}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Ad-hoc deductions
// ---------------------------------------------------------------------------

function DeductionsSection({
  deductions,
  employees,
  runId,
  editable,
  currency,
  onChange,
}: {
  deductions: PayslipDeduction[]
  employees: Pick<Employee, 'id' | 'full_name'>[]
  runId: string
  editable: boolean
  currency: string
  onChange: () => void
}) {
  const [employeeId, setEmployeeId] = useState('')
  const [deductionType, setDeductionType] = useState(DEDUCTION_TYPES[0].value)
  const [amount, setAmount] = useState('')
  const [error, setError] = useState<string | null>(null)

  async function handleAdd(e: FormEvent) {
    e.preventDefault()
    if (!employeeId || !deductionType || !amount) {
      setError('Choose an employee, a type, and an amount.')
      return
    }
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('record_payslip_deduction', {
      p_payroll_run_id: runId,
      p_employee_id: employeeId,
      p_deduction_type: deductionType,
      p_amount: Number(amount),
    })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const result = data as PayrollRpcResult
    if (!result.ok) {
      setError(rpcErrorMessage(result, 'Could not add this deduction.'))
      return
    }
    setEmployeeId('')
    setDeductionType(DEDUCTION_TYPES[0].value)
    setAmount('')
    onChange()
  }

  async function handleDelete(id: string) {
    const { data, error: rpcError } = await supabase.rpc('delete_payslip_deduction', { p_deduction_id: id })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const result = data as PayrollRpcResult
    if (!result.ok) {
      setError(rpcErrorMessage(result, 'Could not remove this deduction.'))
      return
    }
    onChange()
  }

  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <h2 className="mb-3 text-sm font-semibold text-ink">Deductions</h2>
      <p className="mb-3 text-xs text-muted">
        Add before running the calculation — deductions here are applied automatically to the resulting payslip.
      </p>
      {deductions.length === 0 ? (
        <p className="mb-3 text-sm text-muted">No deductions recorded for this run.</p>
      ) : (
        <ul className="mb-3 space-y-1.5">
          {deductions.map((d) => (
            <li key={d.id} className="flex items-center justify-between rounded-lg bg-surface-alt px-3 py-2 text-sm">
              <span className="text-ink">
                {d.employees?.full_name ?? '—'} · <span className="text-muted">{deductionTypeLabel(d.deduction_type)}</span>
              </span>
              <span className="flex items-center gap-3">
                <span className="text-muted">{money(d.amount, currency)}</span>
                {editable && (
                  <button onClick={() => handleDelete(d.id)} className="text-xs font-medium text-brand-risk-text hover:underline">
                    Remove
                  </button>
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
      {editable && (
        <form onSubmit={handleAdd} className="flex flex-wrap items-end gap-2">
          <div>
            <label htmlFor="payroll-employee-10" className="mb-1 block text-xs font-medium text-ink">Employee</label>
            <select id="payroll-employee-10"
              value={employeeId}
              onChange={(e) => setEmployeeId(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="">Select…</option>
              {employees.map((emp) => (
                <option key={emp.id} value={emp.id}>
                  {emp.full_name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="payroll-type-11" className="mb-1 block text-xs font-medium text-ink">Type</label>
            <select id="payroll-type-11"
              value={deductionType}
              onChange={(e) => setDeductionType(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {DEDUCTION_TYPES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="payroll-amount-12" className="mb-1 block text-xs font-medium text-ink">Amount</label>
            <input id="payroll-amount-12"
              type="number"
              min="0"
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="w-32 rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <button
            type="submit"
            className="rounded-lg bg-brand-blue px-3 py-2 text-xs font-medium text-white hover:bg-brand-blue-dark"
          >
            Add
          </button>
        </form>
      )}
      {error && <p className="mt-2 text-xs text-brand-risk-text">{error}</p>}
    </div>
  )
}
