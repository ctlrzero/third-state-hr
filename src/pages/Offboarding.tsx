import { useCallback, useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { Alert, PageHeader, ResponsiveTable, Skeleton, TabPanel, Tabs } from '../components/ui'
import { EmptyState } from '../components/EmptyState'
import { EntityEyebrow } from '../components/EntityEyebrow'
import { listOffboarding, type OffboardingRow } from '../lib/api/offboarding'
import { SEPARATION_LABEL } from '../lib/offboarding'
import { fmtDate, todayDubai } from '../lib/format'
import CaseDrawer from './offboarding/CaseDrawer'
import StartOffboarding from './offboarding/StartOffboarding'

type Tab = 'open' | 'completed' | 'cancelled'

// People leaving: notice, last day, the leaving checklist and final
// settlement. Branch managers see their branch's checklist only.
export default function Offboarding() {
  const { profile, activeEntityId } = useAuth()
  const isAdmin = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const [params, setParams] = useSearchParams()
  const [tab, setTab] = useState<Tab>('open')
  const [rows, setRows] = useState<OffboardingRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [starting, setStarting] = useState(false)
  const openId = params.get('open')
  const today = todayDubai()

  const load = useCallback(async () => {
    if (!activeEntityId) return
    const r = await listOffboarding(activeEntityId, tab)
    if (r.error) setError(r.error)
    setRows(r.data ?? [])
  }, [activeEntityId, tab])
  useEffect(() => {
    setRows(null)
    load()
  }, [load])

  function openCase(id: string | null) {
    const next = new URLSearchParams(params)
    if (id) next.set('open', id)
    else next.delete('open')
    setParams(next, { replace: true })
  }

  if (!activeEntityId) return <EmptyState title="Choose a company" />

  return (
    <div className="space-y-5">
      <EntityEyebrow />
      <PageHeader
        title="Offboarding"
        description="Notice, last working day, the leaving checklist and the final settlement."
        actions={
          isAdmin && (
            <button className="btn-primary" onClick={() => setStarting(true)}>
              Start offboarding
            </button>
          )
        }
      />
      {error && (
        <Alert tone="error" onDismiss={() => setError(null)}>
          {error}
        </Alert>
      )}
      <Tabs<Tab>
        label="Offboarding status"
        active={tab}
        onChange={setTab}
        tabs={[
          { key: 'open', label: 'Leaving' },
          { key: 'completed', label: 'Left' },
          { key: 'cancelled', label: 'Cancelled' },
        ]}
      />
      <TabPanel id={tab}>
        <div className="pt-2">
          {rows === null ? (
            <Skeleton rows={3} className="h-14" />
          ) : rows.length === 0 ? (
            <EmptyState title={tab === 'open' ? 'Nobody is leaving' : 'Nothing here'} description={tab === 'open' && isAdmin ? 'Start offboarding from here or from the employee profile.' : undefined} />
          ) : (
            <ResponsiveTable
              caption="Leavers"
              rows={rows}
              rowKey={(r) => r.case_id}
              columns={[
                {
                  key: 'n',
                  header: 'Employee',
                  render: (r) => (
                    <button className="text-left font-medium text-brand-blue hover:underline" onClick={() => openCase(r.case_id)}>
                      {r.name}
                      <span className="block text-xs font-normal text-muted">{r.branch ?? ''}</span>
                    </button>
                  ),
                },
                { key: 't', header: 'Type', render: (r) => SEPARATION_LABEL[r.separation_type] },
                { key: 'l', header: 'Last day', render: (r) => fmtDate(r.last_working_date) },
                {
                  key: 's',
                  header: 'Settlement by',
                  render: (r) => <span className={r.status === 'open' && r.settlement_due_date < today ? 'text-brand-risk-text' : ''}>{fmtDate(r.settlement_due_date)}</span>,
                },
                {
                  key: 'o',
                  header: 'Checklist',
                  render: (r) =>
                    r.status !== 'open' ? '—' : r.open_tasks === 0 ? <span className="text-brand-action-text">Ready to finish</span> : (
                      <span>
                        {r.open_tasks} left{r.overdue_tasks > 0 && <span className="block text-xs text-brand-risk-text">{r.overdue_tasks} overdue</span>}
                      </span>
                    ),
                },
              ]}
            />
          )}
        </div>
      </TabPanel>
      {starting && (
        <StartOffboarding
          entityId={activeEntityId}
          onClose={() => setStarting(false)}
          onStarted={(id) => {
            setStarting(false)
            load()
            openCase(id)
          }}
        />
      )}
      <CaseDrawer caseId={openId} onClose={() => openCase(null)} onChanged={load} />
    </div>
  )
}
