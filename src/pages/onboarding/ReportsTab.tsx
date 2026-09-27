import { useEffect, useState } from 'react'
import { Alert, Skeleton } from '../../components/ui'
import { onboardingReport, type ReportKind } from '../../lib/api/onboarding'
import { STATUS_LABEL } from '../../lib/onboarding'
import { docTypeLabel } from '../../lib/documents'
import { fmtDate, todayDubai } from '../../lib/format'

const REPORTS: { kind: ReportKind; label: string; ranged: boolean }[] = [
  { kind: 'funnel', label: 'Onboardings by status', ranged: true },
  { kind: 'time_to_activate', label: 'Time to activate', ranged: true },
  { kind: 'starting_soon', label: 'Starting in the next 14 days', ranged: false },
  { kind: 'ageing', label: 'How long each open onboarding has taken', ranged: false },
  { kind: 'blocked_reasons', label: 'Most common blockers', ranged: false },
  { kind: 'overdue_tasks', label: 'Overdue tasks', ranged: false },
  { kind: 'invitations', label: 'Portal invitations', ranged: true },
  { kind: 'document_rejections', label: 'Rejected documents', ranged: true },
  { kind: 'day_one', label: 'Day-one outcomes', ranged: true },
]

function humanKey(k: string) {
  return (STATUS_LABEL as Record<string, string>)[k] ?? k.replace(/_/g, ' ')
}

/** Renders any report payload: an object of counts, or an array of rows. */
function ReportBody({ data }: { data: unknown }) {
  if (Array.isArray(data)) {
    if (data.length === 0) return <p className="text-sm text-muted">Nothing to show.</p>
    const cols = Object.keys(data[0] as object).filter((c) => !c.endsWith('_id'))
    return (
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="text-xs uppercase tracking-wide text-muted">
            <tr>
              {cols.map((c) => (
                <th key={c} className="px-2 py-1.5 font-semibold">
                  {c.replace(/_/g, ' ')}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {data.map((r, i) => (
              <tr key={i}>
                {cols.map((c) => {
                  const v = (r as Record<string, unknown>)[c]
                  const s =
                    c === 'doc_type' ? docTypeLabel(String(v)) : c === 'status' ? humanKey(String(v)) : /date$/.test(c) ? fmtDate(v as string) : v === null ? '—' : String(v)
                  return (
                    <td key={c} className="px-2 py-1.5 text-ink">
                      {s}
                    </td>
                  )
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    )
  }
  if (data && typeof data === 'object') {
    const entries = Object.entries(data as Record<string, unknown>)
    if (entries.length === 0) return <p className="text-sm text-muted">Nothing to show.</p>
    return (
      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {entries.map(([k, v]) => (
          <div key={k} className="rounded-lg bg-surface-alt p-3">
            <dt className="text-xs text-muted">{humanKey(k)}</dt>
            <dd className="text-lg font-semibold text-ink">{v === null ? '—' : String(v)}</dd>
          </div>
        ))}
      </dl>
    )
  }
  return <p className="text-sm text-muted">Nothing to show.</p>
}

export default function ReportsTab({ entityId }: { entityId: string }) {
  const [kind, setKind] = useState<ReportKind>('funnel')
  const today = todayDubai()
  const [from, setFrom] = useState(() => {
    const d = new Date(today + 'T12:00:00Z')
    d.setUTCDate(d.getUTCDate() - 90)
    return d.toISOString().slice(0, 10)
  })
  const [to, setTo] = useState(today)
  const [data, setData] = useState<unknown>(undefined)
  const [error, setError] = useState<string | null>(null)
  const def = REPORTS.find((r) => r.kind === kind)!

  useEffect(() => {
    setData(undefined)
    setError(null)
    onboardingReport(entityId, kind, def.ranged ? from : undefined, def.ranged ? to : undefined).then((r) => {
      if (r.error) setError(r.error)
      setData(r.data?.data ?? null)
    })
  }, [entityId, kind, from, to, def.ranged])

  return (
    <div className="space-y-3 pt-2">
      <div className="flex flex-wrap items-end gap-3">
        <label className="min-w-60 flex-1">
          <span className="label">Report</span>
          <select className="input" value={kind} onChange={(e) => setKind(e.target.value as ReportKind)}>
            {REPORTS.map((r) => (
              <option key={r.kind} value={r.kind}>
                {r.label}
              </option>
            ))}
          </select>
        </label>
        {def.ranged && (
          <>
            <label>
              <span className="label">From</span>
              <input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} />
            </label>
            <label>
              <span className="label">To</span>
              <input type="date" className="input" value={to} onChange={(e) => setTo(e.target.value)} />
            </label>
          </>
        )}
      </div>
      {error && <Alert tone="error">{error}</Alert>}
      <section className="card">{data === undefined ? <Skeleton rows={2} /> : <ReportBody data={data} />}</section>
      <p className="text-xs text-muted">Branch managers see their own branch only. Sensitive document types are hidden from branch managers.</p>
    </div>
  )
}
