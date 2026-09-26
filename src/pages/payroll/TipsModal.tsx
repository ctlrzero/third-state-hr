import { useMemo, useState } from 'react'
import { Alert, Drawer } from '../../components/ui'
import { confirmTips, previewTips, reasonError, voidTips, type TipMethod, type TipSettlement, type TipSplit, type Workspace } from '../../lib/api/payroll'
import { fmtMoney } from '../../lib/payroll'
import { fmtDate } from '../../lib/format'

const METHODS: { value: TipMethod; label: string; hint: string }[] = [
  { value: 'equal', label: 'Equal shares', hint: 'Everyone chosen gets the same.' },
  { value: 'hours', label: 'By hours worked', hint: 'Hours at this branch in the pool dates.' },
  { value: 'role_points', label: 'By role points', hint: 'Points per position (set in Payroll Settings).' },
  { value: 'hours_points', label: 'Hours × role points', hint: 'Hours at the branch multiplied by role points.' },
]

// Distribute tips: branch + dates → pool amount → who and how → preview → confirm.
export default function TipsModal({ workspace, onClose, onDone }: { workspace: Workspace; onClose: () => void; onDone: () => void }) {
  const cur = workspace.entity.currency
  const people = useMemo(() => [...workspace.rows, ...workspace.not_prepared], [workspace])
  const branches = useMemo(() => {
    const m = new Map<string, string>()
    people.forEach((p) => p.location_id && m.set(p.location_id, p.branch ?? 'Branch'))
    return [...m.entries()]
  }, [people])
  const [location, setLocation] = useState(branches[0]?.[0] ?? '')
  const [start, setStart] = useState(workspace.period.period_start)
  const [end, setEnd] = useState(workspace.period.period_end)
  const [amount, setAmount] = useState('')
  const [settlement, setSettlement] = useState<TipSettlement>('payroll')
  const [method, setMethod] = useState<TipMethod>('equal')
  const branchPeople = people.filter((p) => p.location_id === location)
  const [chosen, setChosen] = useState<Set<string>>(() => new Set(branchPeople.map((p) => p.employee_id)))
  const [preview, setPreview] = useState<TipSplit | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<string | null>(null)

  const input = () => ({
    periodId: workspace.period.id,
    locationId: location,
    start,
    end,
    amount: Number(amount),
    settlement,
    method,
    employeeIds: [...chosen],
  })
  const reset = () => setPreview(null)
  const pools = workspace.tip_pools

  return (
    <Drawer open wide title="Distribute tips" description="Branch pools, split exactly to the fils." onClose={onClose}>
      <div className="space-y-4">
        {err && (
          <Alert tone="error" onDismiss={() => setErr(null)}>
            {err}
          </Alert>
        )}
        {done && <Alert tone="success">{done}</Alert>}

        <ol className="space-y-4">
          <li>
            <p className="label">1. Branch and period</p>
            <div className="grid gap-2 sm:grid-cols-3">
              <select
                className="input"
                aria-label="Branch"
                value={location}
                onChange={(e) => {
                  setLocation(e.target.value)
                  setChosen(new Set(people.filter((p) => p.location_id === e.target.value).map((p) => p.employee_id)))
                  reset()
                }}
              >
                {branches.map(([id, name]) => (
                  <option key={id} value={id}>
                    {name}
                  </option>
                ))}
              </select>
              <input type="date" className="input" aria-label="From" value={start} onChange={(e) => (setStart(e.target.value), reset())} />
              <input type="date" className="input" aria-label="To" value={end} onChange={(e) => (setEnd(e.target.value), reset())} />
            </div>
          </li>
          <li>
            <p className="label">2. Pool</p>
            <div className="grid gap-2 sm:grid-cols-2">
              <input className="input" aria-label={`Pool amount (${cur})`} placeholder={`Pool amount (${cur})`} inputMode="decimal" value={amount} onChange={(e) => (setAmount(e.target.value), reset())} />
              <select className="input" aria-label="How tips reach staff" value={settlement} onChange={(e) => (setSettlement(e.target.value as TipSettlement), reset())}>
                <option value="payroll">Pay through payroll (added to net pay)</option>
                <option value="cash_paid">Already paid in cash (shown on payslip only)</option>
              </select>
            </div>
          </li>
          <li>
            <p className="label">3. Who and how</p>
            <div className="grid gap-1 sm:grid-cols-2">
              {METHODS.map((m) => (
                <label key={m.value} className="flex items-start gap-2 rounded-lg border border-border p-2 text-sm">
                  <input type="radio" checked={method === m.value} onChange={() => (setMethod(m.value), reset())} className="mt-1" />
                  <span>
                    <span className="font-medium">{m.label}</span>
                    <span className="block text-xs text-muted">{m.hint}</span>
                  </span>
                </label>
              ))}
            </div>
            <ul className="mt-2 grid gap-1 sm:grid-cols-2">
              {branchPeople.map((p) => (
                <li key={p.employee_id}>
                  <label className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={chosen.has(p.employee_id)}
                      onChange={() => {
                        const n = new Set(chosen)
                        if (n.has(p.employee_id)) n.delete(p.employee_id)
                        else n.add(p.employee_id)
                        setChosen(n)
                        reset()
                      }}
                    />
                    {p.name}
                  </label>
                </li>
              ))}
              {branchPeople.length === 0 && <li className="text-sm text-muted">No employees at this branch in this month.</li>}
            </ul>
          </li>
          <li>
            <p className="label">4. Preview and confirm</p>
            <button
              className="btn-secondary"
              disabled={busy || !Number(amount) || chosen.size === 0}
              onClick={async () => {
                setErr(null)
                const res = await previewTips(input())
                if (res.error) return setErr(res.error)
                setPreview(res.data)
              }}
            >
              Preview split
            </button>
            {preview && (
              <div className="mt-2 rounded-lg border border-border p-3 text-sm">
                {!preview.ok && <p className="text-brand-risk-text">{preview.reason}</p>}
                {preview.items.length > 0 && (
                  <table className="w-full text-left">
                    <thead className="text-xs text-muted">
                      <tr>
                        <th className="py-1">Employee</th>
                        <th className="py-1 text-right">Hours</th>
                        <th className="py-1 text-right">Points</th>
                        <th className="py-1 text-right">Share</th>
                      </tr>
                    </thead>
                    <tbody>
                      {preview.items.map((i) => (
                        <tr key={i.id}>
                          <td className="py-0.5">{i.name}</td>
                          <td className="py-0.5 text-right tabular-nums">{i.hours}</td>
                          <td className="py-0.5 text-right tabular-nums">{i.points}</td>
                          <td className="py-0.5 text-right font-medium tabular-nums">{fmtMoney(i.amount, cur)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
                <p className="mt-2 font-semibold">
                  Allocated {fmtMoney(preview.allocated ?? 0, cur)} of {fmtMoney(preview.total, cur)}
                </p>
                {preview.default_points_used && <p className="text-xs text-brand-warning-solid">Some positions have no role points; 1 point was used.</p>}
                {preview.skipped.length > 0 && (
                  <ul className="mt-1 text-xs text-muted">
                    {preview.skipped.map((s) => (
                      <li key={s.id}>
                        {s.name}: {s.reason}
                      </li>
                    ))}
                  </ul>
                )}
                {preview.ok && (
                  <button
                    className="btn-primary mt-3"
                    disabled={busy}
                    onClick={async () => {
                      setBusy(true)
                      const res = await confirmTips(input(), null)
                      setBusy(false)
                      const e = reasonError(res)
                      if (e) return setErr(e)
                      setDone(`Tips confirmed for ${res.data?.items.length ?? 0} employees.`)
                      setPreview(null)
                      setAmount('')
                      onDone()
                    }}
                  >
                    Confirm distribution
                  </button>
                )}
              </div>
            )}
          </li>
        </ol>

        {pools.length > 0 && (
          <section>
            <h3 className="mb-2 text-sm font-semibold text-ink">Pools this month</h3>
            <ul className="space-y-1 text-sm">
              {pools.map((p) => (
                <li key={p.id} className="flex items-center justify-between gap-2">
                  <span>
                    {p.location} · {fmtDate(p.pool_start)}–{fmtDate(p.pool_end)} · {fmtMoney(p.total_amount, cur)} ·{' '}
                    {p.settlement === 'cash_paid' ? 'paid in cash' : 'through payroll'} · {p.employees} staff
                  </span>
                  <button
                    className="btn-ghost text-xs"
                    onClick={async () => {
                      const res = await voidTips(p.id, 'Removed to redo the split')
                      const e = reasonError(res)
                      if (e) return setErr(e)
                      onDone()
                    }}
                  >
                    Remove
                  </button>
                </li>
              ))}
            </ul>
          </section>
        )}
      </div>
    </Drawer>
  )
}
