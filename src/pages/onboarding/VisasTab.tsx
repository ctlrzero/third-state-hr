import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, ResponsiveTable, Skeleton } from '../../components/ui'
import { EmptyState } from '../../components/EmptyState'
import { listImmigrationCases, type ImmigrationCaseRow } from '../../lib/api/onboarding'
import { TRACK_LABEL } from '../../lib/onboarding'
import { fmtDate } from '../../lib/format'
import { ProgressBar } from './shared'

/** Everyone with work permit / visa processing in progress. Owner / entity admin. */
export default function VisasTab({ entityId, onOpen }: { entityId: string; onOpen: (instanceId: string) => void }) {
  const [status, setStatus] = useState<'open' | 'completed' | 'cancelled'>('open')
  const [rows, setRows] = useState<ImmigrationCaseRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    setRows(null)
    listImmigrationCases(entityId, status).then((r) => {
      if (r.error) setError(r.error)
      setRows(r.data ?? [])
    })
  }, [entityId, status])
  return (
    <div className="space-y-3 pt-2">
      {error && <Alert tone="error">{error}</Alert>}
      <label className="block max-w-xs">
        <span className="sr-only">Status</span>
        <select className="input" value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
          <option value="open">In progress</option>
          <option value="completed">Completed</option>
          <option value="cancelled">Cancelled</option>
        </select>
      </label>
      {rows === null ? (
        <Skeleton rows={3} />
      ) : rows.length === 0 ? (
        <EmptyState title="No visa or work permit tracking" description="Start it from a new starter's onboarding (Work permit and visa)." />
      ) : (
        <ResponsiveTable
          caption="Visa and work permit cases"
          rows={rows}
          rowKey={(r) => r.case_id}
          columns={[
            {
              key: 'n',
              header: 'Employee',
              render: (r) =>
                r.onboarding_instance_id ? (
                  <button className="text-left font-medium text-brand-blue hover:underline" onClick={() => onOpen(r.onboarding_instance_id!)}>
                    {r.name}
                  </button>
                ) : (
                  <Link to={`/employees/${r.employee_id}`} className="font-medium text-brand-blue hover:underline">
                    {r.name}
                  </Link>
                ),
            },
            { key: 't', header: 'Situation', render: (r) => <span className="text-xs">{TRACK_LABEL[r.track]}</span> },
            { key: 'p', header: 'Progress', render: (r) => <ProgressBar percent={r.total ? (100 * r.done) / r.total : 0} label={`${r.done}/${r.total}`} /> },
            {
              key: 'x',
              header: 'Next',
              render: (r) => (
                <span>
                  {r.next_step ?? '—'}
                  {r.next_due && <span className="block text-xs text-muted">by {fmtDate(r.next_due)}</span>}
                  {r.overdue > 0 && <span className="block text-xs text-brand-risk-text">{r.overdue} overdue</span>}
                  {r.blocking_open > 0 && <span className="block text-xs text-brand-risk-text">blocks activation</span>}
                </span>
              ),
            },
          ]}
        />
      )}
    </div>
  )
}
