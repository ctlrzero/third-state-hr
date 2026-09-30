import { useCallback, useEffect, useMemo, useState } from 'react'
import { Alert, Modal, PageHeader, Skeleton } from '../../components/ui'
import { supabase } from '../../lib/supabase'
import { StatusBadge } from '../../components/StatusBadge'
import { EmptyState } from '../../components/EmptyState'
import { EntityEyebrow } from '../../components/EntityEyebrow'
import {
  getWorkspace,
  listPeriods,
  openOffCycle,
  openPeriod,
  preparePayroll,
  type BulkResult,
  type PeriodListItem,
  type Workspace,
} from '../../lib/api/payroll'
import {
  filterRows,
  fmtMoney,
  isPrepared,
  monthStart,
  PAYMENT_STATUS_LABEL,
  periodLabel,
  RECORD_STATUS_LABEL,
  worstSeverity,
  type AnyRow,
  type BulkAction,
  type StatusFilter,
} from '../../lib/payroll'
import RecordDrawer from './RecordDrawer'
import BulkActionModal, { ResultSummary } from './BulkActionModal'
import TipsModal from './TipsModal'
import AdvancesDrawer from './AdvancesDrawer'
import ReportsDrawer from './ReportsDrawer'
import SettingsDrawer from './SettingsDrawer'
import LegacyRuns from './LegacyRuns'
import ReadinessPanel from './ReadinessPanel'
import ChangesPanel from './ChangesPanel'

const thisMonth = () => new Date().toISOString().slice(0, 7)

export default function PayrollWorkspace({ entityId }: { entityId: string }) {
  const [periods, setPeriods] = useState<PeriodListItem[] | null>(null)
  const [periodId, setPeriodId] = useState<string | null>(null)
  const [ws, setWs] = useState<Workspace | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [month, setMonth] = useState(thisMonth())
  const [search, setSearch] = useState('')
  const [branch, setBranch] = useState('')
  const [status, setStatus] = useState<StatusFilter>('all')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [openRecord, setOpenRecord] = useState<string | null>(null)
  const [bulk, setBulk] = useState<BulkAction | null>(null)
  const [panel, setPanel] = useState<'tips' | 'advances' | 'reports' | 'settings' | 'offcycle' | null>(null)
  const [result, setResult] = useState<{ title: string; res: BulkResult } | null>(null)
  const [loads, setLoads] = useState(0)

  const loadPeriods = useCallback(async () => {
    const res = await listPeriods(entityId)
    if (res.error) setError(res.error)
    const list = res.data ?? []
    setPeriods(list)
    return list
  }, [entityId])

  const loadWorkspace = useCallback(async (id: string) => {
    const res = await getWorkspace(id)
    if (res.error) setError(res.error)
    else setWs(res.data)
    setLoads((n) => n + 1)
  }, [])

  useEffect(() => {
    setWs(null)
    setPeriodId(null)
    setSelected(new Set())
    loadPeriods().then((list) => {
      const current = list.find((p) => p.kind === 'regular' && p.period_start.startsWith(thisMonth())) ?? list[0]
      if (current) setPeriodId(current.id)
    })
  }, [loadPeriods])

  useEffect(() => {
    if (periodId) loadWorkspace(periodId)
  }, [periodId, loadWorkspace])

  const refresh = useCallback(async () => {
    if (periodId) await loadWorkspace(periodId)
    await loadPeriods()
  }, [periodId, loadWorkspace, loadPeriods])

  async function startMonth() {
    setBusy(true)
    setError(null)
    const opened = await openPeriod(entityId, monthStart(month))
    if (opened.error || !opened.data) {
      setBusy(false)
      return setError(opened.error ?? 'Could not open the month')
    }
    const prep = await preparePayroll(opened.data, null)
    setBusy(false)
    if (prep.error) setError(prep.error)
    else if (prep.data) setResult({ title: `Prepared ${periodLabel({ period_start: monthStart(month) })}`, res: prep.data })
    await loadPeriods()
    setPeriodId(opened.data)
    await loadWorkspace(opened.data)
  }

  const allRows: AnyRow[] = useMemo(() => (ws ? [...ws.rows, ...ws.not_prepared] : []), [ws])
  const branches = useMemo(() => {
    const m = new Map<string, string>()
    allRows.forEach((r) => r.location_id && m.set(r.location_id, r.branch ?? 'Branch'))
    return [...m.entries()]
  }, [allRows])
  const visible = useMemo(() => filterRows(allRows, { search, branch, status }), [allRows, search, branch, status])
  const selectedRows = useMemo(() => allRows.filter((r) => selected.has(r.employee_id)), [allRows, selected])
  const currency = ws?.entity.currency ?? 'AED'
  const perms = ws?.permissions
  const reviewMode = ws?.settings.approval_mode === 'review_then_approve'

  function toggle(id: string) {
    setSelected((s) => {
      const n = new Set(s)
      if (n.has(id)) n.delete(id)
      else n.add(id)
      return n
    })
  }
  const allVisibleSelected = visible.length > 0 && visible.every((r) => selected.has(r.employee_id))
  function toggleAll() {
    setSelected((s) => {
      const n = new Set(s)
      if (allVisibleSelected) visible.forEach((r) => n.delete(r.employee_id))
      else visible.forEach((r) => n.add(r.employee_id))
      return n
    })
  }

  const noPeriods = periods !== null && periods.length === 0

  return (
    <div className="space-y-5">
      <EntityEyebrow />
      <PageHeader
        title="Payroll"
        description="Prepare, approve and record payments for the month. Every amount opens to show how it was calculated."
        actions={
          <>
            {perms?.prepare && (
              <button className="btn-secondary" onClick={() => setPanel('tips')} disabled={!ws}>
                Distribute tips
              </button>
            )}
            {perms?.prepare && (
              <button className="btn-secondary" onClick={() => setPanel('advances')}>
                Advances
              </button>
            )}
            <button className="btn-secondary" onClick={() => setPanel('reports')} disabled={!ws}>
              Reports
            </button>
            <button className="btn-secondary" onClick={() => setPanel('settings')}>
              Settings
            </button>
          </>
        }
      />

      {error && (
        <Alert tone="error" onDismiss={() => setError(null)}>
          {error}
        </Alert>
      )}
      {result && <ResultSummary title={result.title} res={result.res} currency={currency} onClose={() => setResult(null)} />}

      {/* ---------------------------------------------------- month picker */}
      <section className="card flex flex-wrap items-end gap-3">
        <label className="min-w-48 flex-1">
          <span className="label">Payroll month</span>
          <select className="input" value={periodId ?? ''} onChange={(e) => setPeriodId(e.target.value || null)} disabled={!periods?.length}>
            {!periods?.length && <option value="">No payroll yet</option>}
            {periods?.map((p) => (
              <option key={p.id} value={p.id}>
                {periodLabel(p)} {p.kind === 'off_cycle' ? '(off-cycle)' : ''} · {p.approved}/{p.employees} approved
              </option>
            ))}
          </select>
        </label>
        {perms?.prepare !== false && (
          <div className="flex flex-wrap items-end gap-2">
            <label>
              <span className="label">Start another month</span>
              <input type="month" className="input" value={month} onChange={(e) => setMonth(e.target.value)} />
            </label>
            <button className="btn-primary" onClick={startMonth} disabled={busy || !month}>
              {busy ? 'Preparing…' : 'Prepare payroll'}
            </button>
            <button className="btn-ghost" onClick={() => setPanel('offcycle')}>
              Off-cycle / final settlement
            </button>
          </div>
        )}
      </section>

      {noPeriods && (
        <EmptyState
          title="No payroll yet"
          description="Choose a month and press Prepare payroll. Every eligible employee is added with their salary, allowances, leave, overtime, tips and advances."
        />
      )}
      {periodId && !ws && <Skeleton rows={5} className="h-12" />}

      {ws && (
        <>
          {!ws.settings.confirmed && (
            <Alert tone="info">
              Payroll is using the standard settings: part-month pay is counted by calendar days, a second person must approve, and overtime uses the UAE legal minimum. Check these once before your first payroll.{' '}
              <button className="font-semibold underline" onClick={() => setPanel('settings')}>
                Review settings
              </button>
            </Alert>
          )}

          <ReadinessPanel periodId={ws.period.id} refreshKey={loads} />
          <ChangesPanel periodId={ws.period.id} refreshKey={loads} />

          {ws.period.kind === 'off_cycle' && perms?.prepare && (
            <OffCycleAdd
              entityId={entityId}
              existing={ws.rows.map((r) => r.employee_id)}
              onAdd={async (id) => {
                const res = await preparePayroll(ws.period.id, [id])
                if (res.error) setError(res.error)
                else if (res.data) setResult({ title: 'Added to off-cycle payroll', res: res.data })
                refresh()
              }}
            />
          )}

          {/* ------------------------------------------------ summary */}
          <section aria-label="Summary" className="grid grid-cols-2 gap-3 md:grid-cols-5">
            <Stat label={ws.entity.name} value={periodLabel(ws.period)} />
            <Stat label="Employees" value={String(ws.summary.employees)} sub={ws.summary.not_prepared ? `${ws.summary.not_prepared} not prepared` : undefined} />
            <Stat label="Total net payroll" value={fmtMoney(ws.summary.total_net, currency)} sub={`${ws.summary.approved} approved`} />
            <Stat label="Paid · outstanding" value={fmtMoney(ws.summary.paid, currency)} sub={`${fmtMoney(ws.summary.outstanding, currency)} outstanding`} />
            <Stat
              label="Needs a look"
              value={String(ws.summary.needs_attention)}
              tone={ws.summary.needs_attention ? 'warning' : undefined}
              onClick={ws.summary.needs_attention ? () => setStatus('attention') : undefined}
            />
          </section>

          {/* ------------------------------------------------- filters */}
          <section className="flex flex-wrap items-end gap-2">
            <label className="min-w-48 flex-1">
              <span className="label">Search</span>
              <input className="input" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Employee name" />
            </label>
            <label>
              <span className="label">Branch</span>
              <select className="input" value={branch} onChange={(e) => setBranch(e.target.value)}>
                <option value="">All branches</option>
                {branches.map(([id, name]) => (
                  <option key={id} value={id}>
                    {name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              <span className="label">Status</span>
              <select className="input" value={status} onChange={(e) => setStatus(e.target.value as StatusFilter)}>
                <option value="all">All</option>
                <option value="attention">Needs a look</option>
                <option value="not_prepared">Not prepared</option>
                <option value="draft">Draft</option>
                {reviewMode && <option value="in_review">In review</option>}
                <option value="approved">Approved</option>
                <option value="unpaid">Approved, not fully paid</option>
                <option value="paid">Paid</option>
              </select>
            </label>
          </section>

          {/* ---------------------------------------------- bulk bar */}
          {selected.size > 0 && (
            <section aria-label="Bulk actions" className="sticky top-2 z-10 flex flex-wrap items-center gap-2 rounded-[14px] border border-brand-blue/30 bg-surface p-3 shadow-card">
              <span className="text-sm font-semibold text-ink">{selected.size} selected</span>
              {perms?.prepare && <BulkBtn onClick={() => setBulk('prepare')}>Prepare / recalculate</BulkBtn>}
              {perms?.prepare && <BulkBtn onClick={() => setBulk('adjust')}>Adjust</BulkBtn>}
              {perms?.prepare && reviewMode && <BulkBtn onClick={() => setBulk('review')}>Send for review</BulkBtn>}
              {perms?.approve && <BulkBtn onClick={() => setBulk('approve')}>Approve</BulkBtn>}
              {perms?.pay && <BulkBtn onClick={() => setBulk('export')}>Export payment list</BulkBtn>}
              {perms?.pay && <BulkBtn onClick={() => setBulk('pay')}>Record payment</BulkBtn>}
              {perms?.approve && <BulkBtn onClick={() => setBulk('publish')}>Publish payslips</BulkBtn>}
              <BulkBtn onClick={() => setBulk('download')}>Download payslips</BulkBtn>
              {perms?.prepare && <BulkBtn onClick={() => setBulk('return')}>Return to draft</BulkBtn>}
              <button className="btn-ghost ml-auto" onClick={() => setSelected(new Set())}>
                Clear
              </button>
            </section>
          )}

          {/* --------------------------------------------------- table */}
          {visible.length === 0 ? (
            <EmptyState title="No employees match" description="Change the search or filters." />
          ) : (
            <div className="overflow-x-auto rounded-[14px] border border-border bg-surface shadow-card">
              <table className="w-full min-w-[760px] text-left text-sm">
                <caption className="sr-only">Employees in this payroll month</caption>
                <thead className="border-b border-border bg-surface-alt text-xs uppercase tracking-wide text-muted">
                  <tr>
                    <th scope="col" className="w-10 px-3 py-2.5">
                      <input type="checkbox" aria-label="Select all shown" checked={allVisibleSelected} onChange={toggleAll} className="h-4 w-4" />
                    </th>
                    <th scope="col" className="px-3 py-2.5">Employee</th>
                    <th scope="col" className="px-3 py-2.5 text-right">Fixed pay</th>
                    <th scope="col" className="px-3 py-2.5 text-right">Extra earnings</th>
                    <th scope="col" className="px-3 py-2.5 text-right">Deductions</th>
                    <th scope="col" className="px-3 py-2.5 text-right">Net pay</th>
                    <th scope="col" className="px-3 py-2.5">Status</th>
                    <th scope="col" className="px-3 py-2.5 text-right">
                      <span className="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {visible.map((r) => (
                    <tr key={r.employee_id} className={selected.has(r.employee_id) ? 'bg-brand-info-soft/40' : undefined}>
                      <td className="px-3 py-2.5">
                        <input
                          type="checkbox"
                          aria-label={`Select ${r.name}`}
                          checked={selected.has(r.employee_id)}
                          onChange={() => toggle(r.employee_id)}
                          className="h-4 w-4"
                        />
                      </td>
                      <td className="px-3 py-2.5">
                        <span className="block font-medium text-ink">{r.name}</span>
                        <span className="text-xs text-muted">
                          {r.branch ?? 'No branch'}
                          {isPrepared(r) && r.pay_type === 'hourly' ? ' · hourly' : ''}
                          {isPrepared(r) && r.is_correction ? ' · correction' : ''}
                        </span>
                      </td>
                      {isPrepared(r) ? (
                        <>
                          <td className="px-3 py-2.5 text-right tabular-nums">{fmtMoney(r.fixed_pay, currency)}</td>
                          <td className="px-3 py-2.5 text-right tabular-nums">{fmtMoney(r.extra_earnings, currency)}</td>
                          <td className="px-3 py-2.5 text-right tabular-nums">{r.deductions ? `− ${fmtMoney(r.deductions, currency)}` : '—'}</td>
                          <td className="px-3 py-2.5 text-right font-semibold tabular-nums">{fmtMoney(r.net, currency)}</td>
                          <td className="px-3 py-2.5">
                            <RowStatus row={r} />
                          </td>
                          <td className="px-3 py-2 text-right">
                            <button className="btn-ghost" onClick={() => setOpenRecord(r.record_id)}>
                              Open
                            </button>
                          </td>
                        </>
                      ) : (
                        <>
                          <td colSpan={4} className="px-3 py-2.5 text-muted">
                            Not prepared yet
                          </td>
                          <td className="px-3 py-2.5">
                            <StatusBadge status="Not prepared" tone="neutral" />
                          </td>
                          <td className="px-3 py-2 text-right">
                            {perms?.prepare && (
                              <button
                                className="btn-ghost"
                                onClick={async () => {
                                  const res = await preparePayroll(ws.period.id, [r.employee_id])
                                  if (res.error) setError(res.error)
                                  else if (res.data) setResult({ title: `Prepared ${r.name}`, res: res.data })
                                  refresh()
                                }}
                              >
                                Prepare
                              </button>
                            )}
                          </td>
                        </>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {ws.exports.length > 0 && (
            <section className="card">
              <h2 className="mb-2 text-sm font-semibold text-ink">Payment lists exported</h2>
              <ul className="space-y-1 text-sm">
                {ws.exports.map((x) => (
                  <li key={x.id} className={x.invalidated_at ? 'text-muted line-through' : ''}>
                    {new Date(x.created_at).toLocaleString('en-GB')} · {x.employees} employees · {fmtMoney(x.total, currency)}
                    {x.invalidated_at && <span className="ml-2 no-underline">(void: {x.invalidated_reason})</span>}
                  </li>
                ))}
              </ul>
              <p className="mt-2 text-xs text-muted">Exporting never marks anyone paid. Use “Record payment” once the bank confirms.</p>
            </section>
          )}
        </>
      )}

      <LegacyRuns entityId={entityId} />

      {openRecord && ws && (
        <RecordDrawer
          recordId={openRecord}
          workspace={ws}
          onClose={() => setOpenRecord(null)}
          onChanged={refresh}
          onOpenRecord={setOpenRecord}
        />
      )}
      {bulk && ws && (
        <BulkActionModal
          action={bulk}
          workspace={ws}
          rows={selectedRows}
          onClose={() => setBulk(null)}
          onDone={(title, res) => {
            setBulk(null)
            if (res) setResult({ title, res })
            refresh()
          }}
        />
      )}
      {panel === 'tips' && ws && <TipsModal workspace={ws} onClose={() => setPanel(null)} onDone={refresh} />}
      {panel === 'advances' && <AdvancesDrawer entityId={entityId} workspace={ws} onClose={() => setPanel(null)} onChanged={refresh} />}
      {panel === 'reports' && ws && <ReportsDrawer workspace={ws} onClose={() => setPanel(null)} />}
      {panel === 'settings' && <SettingsDrawer entityId={entityId} onClose={() => setPanel(null)} onChanged={refresh} />}
      {panel === 'offcycle' && (
        <OffCycleModal
          entityId={entityId}
          onClose={() => setPanel(null)}
          onCreated={async (id) => {
            setPanel(null)
            await loadPeriods()
            setPeriodId(id)
          }}
        />
      )}
    </div>
  )
}

function Stat({ label, value, sub, tone, onClick }: { label: string; value: string; sub?: string; tone?: 'warning'; onClick?: () => void }) {
  const body = (
    <>
      <span className="block text-xs text-muted">{label}</span>
      <span className={`mt-1 block text-lg font-semibold tabular-nums ${tone === 'warning' ? 'text-brand-warning-solid' : 'text-ink'}`}>{value}</span>
      {sub && <span className="block text-xs text-muted">{sub}</span>}
    </>
  )
  return onClick ? (
    <button type="button" onClick={onClick} className="card text-left transition hover:border-brand-blue/40">
      {body}
    </button>
  ) : (
    <div className="card">{body}</div>
  )
}

function BulkBtn({ onClick, children }: { onClick: () => void; children: React.ReactNode }) {
  return (
    <button type="button" className="btn-secondary" onClick={onClick}>
      {children}
    </button>
  )
}

function RowStatus({ row }: { row: Extract<AnyRow, { record_id: string }> }) {
  const sev = worstSeverity(row.attention)
  return (
    <span className="flex flex-wrap items-center gap-1">
      <StatusBadge status={RECORD_STATUS_LABEL[row.record_status]} tone={row.record_status === 'approved' ? 'success' : row.record_status === 'in_review' ? 'warning' : 'neutral'} />
      {row.record_status === 'approved' && PAYMENT_STATUS_LABEL[row.payment_status] && (
        <StatusBadge
          status={PAYMENT_STATUS_LABEL[row.payment_status]}
          tone={row.payment_status === 'paid' ? 'success' : row.payment_status === 'failed' || row.payment_status === 'overpaid' ? 'risk' : row.payment_status === 'partial' ? 'info' : 'warning'}
        />
      )}
      {row.published_at && <StatusBadge status="Published" tone="info" />}
      {sev === 'blocking' && <StatusBadge status="Fix needed" tone="risk" />}
      {sev === 'warning' && <StatusBadge status="Check" tone="warning" />}
    </span>
  )
}

function OffCycleAdd({ entityId, existing, onAdd }: { entityId: string; existing: string[]; onAdd: (id: string) => void }) {
  const [list, setList] = useState<{ id: string; full_name: string }[]>([])
  const [pick, setPick] = useState('')
  useEffect(() => {
    supabase
      .from('employees')
      .select('id, full_name')
      .eq('entity_id', entityId)
      .in('employment_status', ['active', 'inactive'])
      .order('full_name')
      .then(({ data }) => setList((data ?? []) as { id: string; full_name: string }[]))
  }, [entityId])
  const options = list.filter((e) => !existing.includes(e.id))
  return (
    <section className="card flex flex-wrap items-end gap-2">
      <label className="min-w-56 flex-1">
        <span className="label">Add an employee to this off-cycle payroll</span>
        <select className="input" value={pick} onChange={(e) => setPick(e.target.value)}>
          <option value="">Choose…</option>
          {options.map((e) => (
            <option key={e.id} value={e.id}>
              {e.full_name}
            </option>
          ))}
        </select>
      </label>
      <button className="btn-primary" disabled={!pick} onClick={() => (onAdd(pick), setPick(''))}>
        Add
      </button>
      <p className="w-full text-xs text-muted">
        Only items you add are paid here (e.g. gratuity, leave encashment, notice pay). Regular salary for the month stays in the monthly payroll.
      </p>
    </section>
  )
}

function OffCycleModal({ entityId, onClose, onCreated }: { entityId: string; onClose: () => void; onCreated: (id: string) => void }) {
  const [label, setLabel] = useState('')
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10))
  const [err, setErr] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  return (
    <Modal
      open
      title="Off-cycle payroll"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            disabled={saving || !label.trim()}
            onClick={async () => {
              setSaving(true)
              const res = await openOffCycle(entityId, date, label)
              setSaving(false)
              if (res.error || !res.data) return setErr(res.error ?? 'Could not create it')
              onCreated(res.data)
            }}
          >
            Create
          </button>
        </>
      }
    >
      <p className="text-muted">For a final settlement or a one-off payment outside the monthly run.</p>
      {err && <Alert tone="error">{err}</Alert>}
      <label className="block">
        <span className="label">Label</span>
        <input className="input" value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Final settlement – name" />
      </label>
      <label className="block">
        <span className="label">Pay date</span>
        <input type="date" className="input" value={date} onChange={(e) => setDate(e.target.value)} />
      </label>
    </Modal>
  )
}
