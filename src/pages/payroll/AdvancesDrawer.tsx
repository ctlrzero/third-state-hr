import { useEffect, useState } from 'react'
import { Alert, Drawer } from '../../components/ui'
import { supabase } from '../../lib/supabase'
import { cancelAdvance, createAdvance, reasonError, type Workspace } from '../../lib/api/payroll'
import { fmtMoney } from '../../lib/payroll'
import { fmtDate } from '../../lib/format'

interface AdvanceRow {
  id: string
  employee_id: string
  amount: number
  disbursed_on: string
  repayment_start: string
  instalments: number
  instalment_amount: number
  status: string
  reason: string
  employees: { full_name: string } | null
  advance_repayments: { amount: number; record_id: string }[]
}

// Salary advances: amount, how it was paid out, repayment start and
// instalments. The outstanding balance is the amount minus repayments
// locked into approved payroll; instalments never exceed it.
export default function AdvancesDrawer({
  entityId,
  workspace,
  onClose,
  onChanged,
}: {
  entityId: string
  workspace: Workspace | null
  onClose: () => void
  onChanged: () => void
}) {
  const cur = workspace?.entity.currency ?? 'AED'
  const [rows, setRows] = useState<AdvanceRow[] | null>(null)
  const [employees, setEmployees] = useState<{ id: string; full_name: string }[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [f, setF] = useState({
    employeeId: '',
    amount: '',
    disbursedOn: new Date().toISOString().slice(0, 10),
    method: 'cash',
    repaymentStart: (workspace?.period.period_start ?? new Date().toISOString().slice(0, 8) + '01').slice(0, 7),
    instalments: '1',
    reason: '',
  })

  async function load() {
    const [a, e] = await Promise.all([
      supabase
        .from('salary_advances')
        .select('id, employee_id, amount, disbursed_on, repayment_start, instalments, instalment_amount, status, reason, employees(full_name), advance_repayments(amount, record_id)')
        .eq('entity_id', entityId)
        .neq('status', 'cancelled')
        .order('created_at', { ascending: false }),
      supabase.from('employees').select('id, full_name').eq('entity_id', entityId).in('employment_status', ['active', 'pre_boarding']).order('full_name'),
    ])
    if (a.error) setErr(a.error.message)
    setRows((a.data ?? []) as unknown as AdvanceRow[])
    setEmployees((e.data ?? []) as { id: string; full_name: string }[])
  }
  useEffect(() => {
    load()
  }, [entityId]) // eslint-disable-line react-hooks/exhaustive-deps

  const amt = Number(f.amount)
  const n = Number(f.instalments)
  const instalment = amt > 0 && n > 0 ? Math.ceil((amt * 100) / n) / 100 : 0

  return (
    <Drawer open wide title="Salary advances" description="Repayments are deducted automatically from payroll." onClose={onClose}>
      <div className="space-y-5">
        {err && (
          <Alert tone="error" onDismiss={() => setErr(null)}>
            {err}
          </Alert>
        )}
        <section className="rounded-lg border border-border p-3">
          <h3 className="mb-2 text-sm font-semibold text-ink">New advance</h3>
          <div className="grid gap-2 sm:grid-cols-2">
            <label>
              <span className="label">Employee</span>
              <select className="input" value={f.employeeId} onChange={(e) => setF({ ...f, employeeId: e.target.value })}>
                <option value="">Choose…</option>
                {employees.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.full_name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              <span className="label">Amount ({cur})</span>
              <input className="input" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} />
            </label>
            <label>
              <span className="label">Paid out on</span>
              <input type="date" className="input" value={f.disbursedOn} onChange={(e) => setF({ ...f, disbursedOn: e.target.value })} />
            </label>
            <label>
              <span className="label">Paid out by</span>
              <select className="input" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>
                <option value="cash">Cash</option>
                <option value="bank_transfer">Bank transfer</option>
                <option value="cheque">Cheque</option>
                <option value="payroll">With this month’s payroll</option>
              </select>
            </label>
            <label>
              <span className="label">Repayments start</span>
              <input type="month" className="input" value={f.repaymentStart} onChange={(e) => setF({ ...f, repaymentStart: e.target.value })} />
            </label>
            <label>
              <span className="label">Number of instalments</span>
              <input className="input" inputMode="numeric" value={f.instalments} onChange={(e) => setF({ ...f, instalments: e.target.value })} />
            </label>
            <label className="sm:col-span-2">
              <span className="label">Reason</span>
              <input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} />
            </label>
          </div>
          {instalment > 0 && (
            <p className="mt-2 text-sm">
              {n} × {fmtMoney(instalment, cur)}
              {instalment * n > amt ? ' (the last one smaller, so the total is exact)' : ''}. Written consent is required and no interest may be charged
              (Decree-Law 33/2021 Art. 25).
            </p>
          )}
          <button
            className="btn-primary mt-3"
            disabled={!f.employeeId || !(amt > 0) || !(n >= 1) || !f.reason.trim()}
            onClick={async () => {
              const res = await createAdvance({
                employeeId: f.employeeId,
                amount: amt,
                disbursedOn: f.disbursedOn,
                method: f.method,
                repaymentStart: `${f.repaymentStart}-01`,
                instalments: n,
                reason: f.reason,
              })
              const e = reasonError(res)
              if (e) return setErr(e)
              setF({ ...f, amount: '', reason: '' })
              load()
              onChanged()
            }}
          >
            Save advance
          </button>
        </section>

        <section>
          <h3 className="mb-2 text-sm font-semibold text-ink">Advances</h3>
          {rows?.length === 0 && <p className="text-sm text-muted">No advances.</p>}
          <ul className="space-y-2">
            {rows?.map((a) => {
              const repaid = a.advance_repayments.reduce((s, x) => s + Number(x.amount), 0)
              const outstanding = Math.round((Number(a.amount) - repaid) * 100) / 100
              return (
                <li key={a.id} className="rounded-lg border border-border p-2 text-sm">
                  <p className="font-medium">
                    {a.employees?.full_name} · {fmtMoney(a.amount, cur)} · {a.status}
                  </p>
                  <p className="text-xs text-muted">
                    Paid {fmtDate(a.disbursed_on)} · {a.instalments} × {fmtMoney(a.instalment_amount, cur)} from {fmtDate(a.repayment_start)} · repaid{' '}
                    {fmtMoney(repaid, cur)} · <strong>{fmtMoney(outstanding, cur)} outstanding</strong> · {a.reason}
                  </p>
                  {a.advance_repayments.length === 0 && a.status === 'active' && (
                    <button
                      className="btn-ghost mt-1 text-xs"
                      onClick={async () => {
                        const res = await cancelAdvance(a.id, 'Cancelled before any repayment')
                        const e = reasonError(res)
                        if (e) return setErr(e)
                        load()
                        onChanged()
                      }}
                    >
                      Cancel advance
                    </button>
                  )}
                </li>
              )
            })}
          </ul>
        </section>
      </div>
    </Drawer>
  )
}
