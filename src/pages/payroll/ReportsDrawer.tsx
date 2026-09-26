import { useEffect, useState } from 'react'
import { Alert, Drawer, Skeleton } from '../../components/ui'
import { getReport, type ReportKind, type Workspace } from '../../lib/api/payroll'
import { fmtMoney, periodLabel, toCsv } from '../../lib/payroll'
import { downloadBytes } from '../../lib/pdf'
import { humanize } from '../../lib/format'

const REPORTS: { key: ReportKind; label: string }[] = [
  { key: 'register', label: 'Monthly payroll register' },
  { key: 'branch_cost', label: 'Branch payroll cost' },
  { key: 'payments', label: 'Payments and outstanding' },
  { key: 'breakdown', label: 'Tips, advances and deductions' },
]

type Row = Record<string, unknown>
const MONEY = new Set([
  'basic', 'allowances', 'overtime', 'tips', 'other_earnings', 'gross', 'unpaid_leave', 'advance_repayment', 'other_deductions',
  'deductions', 'net', 'paid', 'outstanding', 'amount', 'allocated', 'repaid_this_month',
])

export default function ReportsDrawer({ workspace, onClose }: { workspace: Workspace; onClose: () => void }) {
  const [kind, setKind] = useState<ReportKind>('register')
  const [data, setData] = useState<unknown>(null)
  const [err, setErr] = useState<string | null>(null)
  const cur = workspace.entity.currency

  useEffect(() => {
    setData(null)
    getReport(workspace.period.id, kind).then((res) => {
      if (res.error) setErr(res.error)
      else setData(res.data)
    })
  }, [kind, workspace.period.id])

  const tables: { title: string; rows: Row[] }[] =
    data == null
      ? []
      : kind === 'breakdown'
        ? Object.entries(data as Record<string, Row[]>).map(([k, v]) => ({ title: humanize(k), rows: v }))
        : [{ title: REPORTS.find((r) => r.key === kind)!.label, rows: data as Row[] }]

  function download() {
    const parts = tables.map((t) => {
      const cols = t.rows[0] ? Object.keys(t.rows[0]).filter((c) => typeof t.rows[0][c] !== 'object' || t.rows[0][c] === null) : []
      return `${t.title}\r\n${toCsv(cols.map(humanize), t.rows.map((r) => cols.map((c) => r[c] as string | number | null)))}`
    })
    downloadBytes(new TextEncoder().encode(parts.join('\r\n\r\n')), `${kind}-${workspace.period.period_start}.csv`, 'text/csv')
  }

  return (
    <Drawer
      open
      wide
      title="Payroll reports"
      description={`${workspace.entity.name} · ${periodLabel(workspace.period)}`}
      onClose={onClose}
      footer={
        <button className="btn-secondary" onClick={download} disabled={!tables.length}>
          Download CSV
        </button>
      }
    >
      <div className="space-y-4">
        <select className="input" aria-label="Report" value={kind} onChange={(e) => setKind(e.target.value as ReportKind)}>
          {REPORTS.map((r) => (
            <option key={r.key} value={r.key}>
              {r.label}
            </option>
          ))}
        </select>
        {err && <Alert tone="error">{err}</Alert>}
        {data == null && !err && <Skeleton rows={4} className="h-8" />}
        {tables.map((t) => (
          <section key={t.title}>
            <h3 className="mb-2 text-sm font-semibold text-ink">{t.title}</h3>
            {t.rows.length === 0 ? (
              <p className="text-sm text-muted">Nothing to show.</p>
            ) : (
              <div className="overflow-x-auto rounded-lg border border-border">
                <table className="w-full text-left text-xs">
                  <thead className="bg-surface-alt text-muted">
                    <tr>
                      {Object.keys(t.rows[0])
                        .filter((c) => typeof t.rows[0][c] !== 'object' || t.rows[0][c] === null)
                        .map((c) => (
                          <th key={c} className={`px-2 py-1.5 ${MONEY.has(c) ? 'text-right' : ''}`}>
                            {humanize(c)}
                          </th>
                        ))}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-border">
                    {t.rows.map((r, i) => (
                      <tr key={i}>
                        {Object.keys(t.rows[0])
                          .filter((c) => typeof t.rows[0][c] !== 'object' || t.rows[0][c] === null)
                          .map((c) => (
                            <td key={c} className={`px-2 py-1 ${MONEY.has(c) ? 'text-right tabular-nums' : ''}`}>
                              {MONEY.has(c) && r[c] != null ? fmtMoney(Number(r[c]), cur) : String(r[c] ?? '—')}
                            </td>
                          ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        ))}
      </div>
    </Drawer>
  )
}
