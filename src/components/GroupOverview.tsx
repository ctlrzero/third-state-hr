import { useEffect, useState } from 'react'
import { Alert, Skeleton } from './ui'
import { getOwnerDashboardKpis, type OwnerDashboardKpis } from '../lib/api/dashboard'
import { fmtDateTime } from '../lib/format'

// Owner-only group totals across every entity (get_owner_dashboard_kpis with
// p_entity_id = null → scope 'all_entities'). The per-entity dashboard below
// stays scoped to the entity picked in the header switcher.
export function GroupOverview({ entityCount }: { entityCount: number }) {
  const [kpis, setKpis] = useState<OwnerDashboardKpis | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    getOwnerDashboardKpis(null).then((res) => {
      if (res.error) setError(res.error)
      else setKpis(res.data)
    })
  }, [])

  const tiles: [string, number | undefined, boolean?][] = kpis
    ? [
        ['Active employees', kpis.headcount?.active],
        ['Pre-boarding', kpis.headcount?.pre_boarding],
        ['Documents expired', kpis.document_expiry?.expired, (kpis.document_expiry?.expired ?? 0) > 0],
        ['Expiring in 30 days', kpis.document_expiry?.expiring_30_days, (kpis.document_expiry?.expiring_30_days ?? 0) > 0],
        ['Documents to review', kpis.document_review_queue],
        ['Pending leave', kpis.leave?.pending_requests],
        ['Open payroll runs', (kpis.payroll?.draft_runs ?? 0) + (kpis.payroll?.in_review_runs ?? 0) + (kpis.payroll?.approved_unpaid_runs ?? 0)],
        ['Open requisitions', kpis.recruitment?.open_requisitions],
      ]
    : []

  return (
    <section className="card space-y-3" aria-labelledby="group-overview-h">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 id="group-overview-h" className="text-base font-semibold text-ink">
          Group overview · all {entityCount} entities
        </h2>
        {kpis && <span className="text-xs text-muted">Updated {fmtDateTime(kpis.generated_at)}</span>}
      </div>
      {error ? (
        <Alert tone="error">{error}</Alert>
      ) : !kpis ? (
        <Skeleton rows={1} className="h-16" />
      ) : (
        <dl className="grid grid-cols-2 gap-2 sm:grid-cols-4">
          {tiles.map(([label, value, warn]) => (
            <div key={label} className={`rounded-lg p-3 ${warn ? 'bg-brand-warning-soft' : 'bg-surface-alt'}`}>
              <dt className="text-xs text-muted">{label}</dt>
              <dd className={`text-xl font-semibold ${warn ? 'text-brand-warning-solid' : 'text-ink'}`}>{value ?? 0}</dd>
            </div>
          ))}
        </dl>
      )}
    </section>
  )
}
