import { useCallback, useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAuth } from '../../auth/AuthContext'
import { Alert, PageHeader, ResponsiveTable, Skeleton, TabPanel, Tabs, type Column } from '../../components/ui'
import { EmptyState } from '../../components/EmptyState'
import { EntityEyebrow } from '../../components/EntityEyebrow'
import { KpiCard } from '../../components/KpiCard'
import { dashboardSummary, listOnboarding, listTemplates, type DashboardSummary, type ListTab, type OnboardingRow } from '../../lib/api/onboarding'
import { startsInLabel } from '../../lib/onboarding'
import { fmtDate, todayDubai } from '../../lib/format'
import { OnboardingStatusBadge } from './shared'
import StartModal from './StartModal'
import WorkspaceDrawer from './WorkspaceDrawer'
import ProbationTab from './ProbationTab'
import ReportsTab from './ReportsTab'
import SetupTab from './SetupTab'
import VisasTab from './VisasTab'

type Top = 'pipeline' | 'probation' | 'visas' | 'reports' | 'setup'

const LIST_TABS: { key: ListTab; label: string }[] = [
  { key: 'all', label: 'All open' },
  { key: 'starting_soon', label: 'Starting soon' },
  { key: 'awaiting_employee', label: 'Waiting for employee' },
  { key: 'under_review', label: 'To review' },
  { key: 'blocked', label: 'Blocked' },
  { key: 'ready', label: 'Ready to activate' },
  { key: 'in_progress', label: 'Started' },
  { key: 'incomplete', label: 'Working, onboarding not finished' },
  { key: 'completed', label: 'Completed' },
  { key: 'cancelled', label: 'Cancelled' },
]

export default function OnboardingDashboard({ payrollOnly = false }: { payrollOnly?: boolean }) {
  const { profile, activeEntityId } = useAuth()
  const isAdmin = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const [params, setParams] = useSearchParams()
  const [top, setTop] = useState<Top>('pipeline')
  const [tab, setTab] = useState<ListTab>('all')
  const [rows, setRows] = useState<OnboardingRow[] | null>(null)
  const [summary, setSummary] = useState<DashboardSummary | null>(null)
  const [hasTemplate, setHasTemplate] = useState<boolean | null>(null)
  const [templateTick, setTemplateTick] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [starting, setStarting] = useState(false)
  const open = params.get('open')
  const today = todayDubai()

  const load = useCallback(async () => {
    if (!activeEntityId) return
    const [l, s] = await Promise.all([listOnboarding(activeEntityId, tab), dashboardSummary(activeEntityId)])
    if (l.error) setError(l.error)
    // "All open" hides closed ones; the Completed / Cancelled tabs show them.
    setRows((l.data ?? []).filter((r) => tab !== 'all' || !['completed', 'cancelled', 'withdrawn'].includes(r.status)))
    if (s.data) setSummary(s.data)
  }, [activeEntityId, tab])

  useEffect(() => {
    setRows(null)
    load()
  }, [load])

  useEffect(() => {
    if (!activeEntityId || !isAdmin) return
    listTemplates(activeEntityId).then((r) => setHasTemplate((r.data ?? []).some((t) => t.is_active)))
  }, [activeEntityId, isAdmin, templateTick])

  function openInstance(id: string | null) {
    const next = new URLSearchParams(params)
    if (id) next.set('open', id)
    else next.delete('open')
    setParams(next, { replace: true })
  }

  const columns: Column<OnboardingRow>[] = useMemo(
    () => [
      {
        key: 'name',
        header: 'New starter',
        render: (r) => (
          <button className="text-left font-medium text-brand-blue hover:underline" onClick={() => openInstance(r.onboarding_instance_id)}>
            {r.name}
            <span className="block text-xs font-normal text-muted">
              {[r.position, r.branch].filter(Boolean).join(' · ') || 'Setup incomplete'}
            </span>
          </button>
        ),
      },
      { key: 'status', header: 'Status', render: (r) => <OnboardingStatusBadge status={r.status} /> },
      {
        key: 'start',
        header: 'Start',
        render: (r) => (
          <span>
            {fmtDate(r.proposed_start_date)}
            <span className="block text-xs text-muted">{startsInLabel(r.proposed_start_date, today)}</span>
          </span>
        ),
      },
      {
        key: 'blocking',
        header: 'Outstanding',
        render: (r) =>
          r.activated_with_open_items && (r.open_items ?? 0) > 0 ? (
            <span className="text-brand-warning-solid">
              Working · {r.open_items} onboarding item{r.open_items === 1 ? '' : 's'} open
            </span>
          ) : r.blocking_count === 0 ? (
            <span className="text-brand-action-text">Nothing blocking</span>
          ) : (
            <span>
              {r.blocking_count} item{r.blocking_count === 1 ? '' : 's'}
              {r.overdue_tasks > 0 && <span className="block text-xs text-brand-risk-text">{r.overdue_tasks} overdue</span>}
            </span>
          ),
      },
      { key: 'stage', header: 'In this stage', render: (r) => `${r.days_in_stage} day${r.days_in_stage === 1 ? '' : 's'}` },
    ],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [today, params]
  )

  if (!activeEntityId) return <EmptyState title="Choose a company" description="Select a company in the header to see its onboarding." />

  const topTabs = [
    { key: 'pipeline' as const, label: 'New starters', badge: summary?.open },
    ...(payrollOnly
      ? []
      : [
          { key: 'probation' as const, label: 'Probation', badge: summary?.probation_reviews_due || undefined },
          ...(isAdmin ? [{ key: 'visas' as const, label: 'Visas & permits' }] : []),
          { key: 'reports' as const, label: 'Reports' },
        ]),
    ...(isAdmin ? [{ key: 'setup' as const, label: 'Setup' }] : []),
  ]

  return (
    <div className="space-y-5">
      <EntityEyebrow />
      <PageHeader
        title="Onboarding"
        description={payrollOnly ? 'New starters whose pay or bank details need payroll review.' : 'Everyone joining, what each person still needs, and who must act.'}
        actions={
          isAdmin && (
            <button className="btn-primary" onClick={() => setStarting(true)} disabled={hasTemplate === false}>
              Start onboarding
            </button>
          )
        }
      />
      {error && (
        <Alert tone="error" onDismiss={() => setError(null)}>
          {error}
        </Alert>
      )}
      {isAdmin && hasTemplate === false && (
        <Alert tone="warning">
          No onboarding template yet. Open <strong>Setup</strong> and add the standard template before starting onboarding.
        </Alert>
      )}

      {(summary?.activated_incomplete ?? 0) > 0 && (
        <Alert tone="warning">
          {summary!.activated_incomplete} staff {summary!.activated_incomplete === 1 ? 'is' : 'are'} working with onboarding not finished (activated
          before documents or tasks were complete).{' '}
          <button className="font-semibold underline" onClick={() => (setTop('pipeline'), setTab('incomplete'))}>
            Show them
          </button>
        </Alert>
      )}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <KpiCard label="Starting in 7 days" value={summary?.starting_7_days ?? '–'} loading={!summary} onClick={() => (setTop('pipeline'), setTab('starting_soon'))} />
        <KpiCard label="Start at risk" value={summary?.start_at_risk ?? '–'} tone={summary?.start_at_risk ? 'risk' : 'default'} loading={!summary} hint="Starts within 3 days, not ready" />
        <KpiCard label="Waiting for review" value={summary?.awaiting_review ?? '–'} tone={summary?.awaiting_review ? 'warning' : 'default'} loading={!summary} onClick={() => (setTop('pipeline'), setTab('under_review'))} />
        <KpiCard label="Ready to activate" value={summary?.ready_for_activation ?? '–'} loading={!summary} onClick={() => (setTop('pipeline'), setTab('ready'))} />
        <KpiCard label="Overdue tasks" value={summary?.overdue_tasks ?? '–'} tone={summary?.overdue_tasks ? 'risk' : 'default'} loading={!summary} />
        <KpiCard label="Open problems" value={summary?.open_exceptions ?? '–'} tone={summary?.open_exceptions ? 'warning' : 'default'} loading={!summary} />
        {summary?.pay_awaiting_review != null && <KpiCard label="Pay to review" value={summary.pay_awaiting_review} tone={summary.pay_awaiting_review ? 'warning' : 'default'} />}
        {summary?.bank_awaiting_verification != null && (
          <KpiCard label="Bank details to verify" value={summary.bank_awaiting_verification} tone={summary.bank_awaiting_verification ? 'warning' : 'default'} />
        )}
      </div>

      <Tabs tabs={topTabs} active={top} onChange={setTop} label="Onboarding views" />

      {top === 'pipeline' && (
        <TabPanel id="pipeline">
          <div className="space-y-3 pt-2">
            <label className="block max-w-xs">
              <span className="sr-only">Filter</span>
              <select className="input" value={tab} onChange={(e) => setTab(e.target.value as ListTab)}>
                {LIST_TABS.map((t) => (
                  <option key={t.key} value={t.key}>
                    {t.label}
                  </option>
                ))}
              </select>
            </label>
            {rows === null ? (
              <Skeleton rows={4} className="h-14" />
            ) : rows.length === 0 ? (
              <EmptyState
                title={tab === 'all' ? 'No one is onboarding' : 'Nothing here'}
                description={tab === 'all' ? 'Start onboarding from an accepted offer in Recruiting, or use “Start onboarding” for a direct hire.' : undefined}
              />
            ) : (
              <ResponsiveTable caption="New starters" columns={columns} rows={rows} rowKey={(r) => r.onboarding_instance_id} />
            )}
          </div>
        </TabPanel>
      )}
      {top === 'probation' && (
        <TabPanel id="probation">
          <ProbationTab entityId={activeEntityId} canDecide={isAdmin} />
        </TabPanel>
      )}
      {top === 'visas' && isAdmin && (
        <TabPanel id="visas">
          <VisasTab entityId={activeEntityId} onOpen={(id) => openInstance(id)} />
        </TabPanel>
      )}
      {top === 'reports' && (
        <TabPanel id="reports">
          <ReportsTab entityId={activeEntityId} />
        </TabPanel>
      )}
      {top === 'setup' && isAdmin && (
        <TabPanel id="setup">
          <SetupTab entityId={activeEntityId} onChanged={() => setTemplateTick((t) => t + 1)} />
        </TabPanel>
      )}

      <StartModal
        open={starting}
        entityId={activeEntityId}
        onClose={() => setStarting(false)}
        onStarted={(id) => {
          setStarting(false)
          load()
          openInstance(id)
        }}
      />
      <WorkspaceDrawer instanceId={open} onClose={() => openInstance(null)} onChanged={load} />
    </div>
  )
}
