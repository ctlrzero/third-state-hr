import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { fmtDate } from '../lib/format'
import { getMyEmployeeRequests, requestActionLabel, requestActionRoute, type MyEmployeeRequest } from '../lib/api/employeeRequests'

// Employee Home: things a manager has asked this employee for. One big button
// each, straight to the place where it gets done. Hidden when there is nothing.
export default function MyRequestsCard() {
  const [rows, setRows] = useState<MyEmployeeRequest[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    getMyEmployeeRequests().then((res) => {
      if (res.error) setError(res.error)
      else setRows(res.data ?? [])
    })
  }, [])

  if (error) {
    return (
      <p role="alert" className="card text-sm text-brand-risk-text">
        We couldn’t load what your manager asked for. {error}
      </p>
    )
  }
  if (rows.length === 0) return null

  return (
    <section className="card space-y-3 border-brand-warning/50" aria-labelledby="my-requests-h">
      <div>
        <h2 id="my-requests-h" className="text-lg font-semibold text-ink">
          Your manager needs something
        </h2>
        <p className="text-sm text-muted">
          {rows.length === 1 ? 'Please do this soon.' : `Please do these ${rows.length} things soon.`}
        </p>
      </div>
      <ul className="space-y-3">
        {rows.map((r) => (
          <li key={r.id} className="rounded-lg bg-surface-alt p-3">
            <p className="font-medium text-ink">{r.label}</p>
            <p className={`text-xs ${r.is_overdue ? 'font-semibold text-brand-risk-text' : 'text-muted'}`}>
              {r.requested_by_name ? `From ${r.requested_by_name}` : 'From your manager'}
              {r.due_date ? ` · ${r.is_overdue ? 'was due' : 'by'} ${fmtDate(r.due_date)}` : ''}
            </p>
            {r.note && <p className="mt-1 text-sm text-ink">“{r.note}”</p>}
            <Link to={requestActionRoute(r)} className="btn-primary mt-2 inline-flex min-h-11 w-full items-center justify-center sm:w-auto">
              {requestActionLabel(r)}
            </Link>
          </li>
        ))}
      </ul>
    </section>
  )
}
