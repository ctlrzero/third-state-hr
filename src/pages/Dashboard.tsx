import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { KpiCard } from '../components/KpiCard'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { GroupOverview } from '../components/GroupOverview'
import { fmtDate } from '../lib/format'
import { EntityEyebrow } from '../components/EntityEyebrow'

type ActionKind = 'leave' | 'document' | 'change_request' | 'shift_swap'

interface ActionItem {
  id: string
  kind: ActionKind
  title: string
  subtitle: string
  status: string
  href: string
  urgent: boolean
}

interface Kpis {
  activeEmployees: number | null
  expiringDocuments: number | null
  pendingLeave: number | null
  openPayrollRuns: number | null
}

const KIND_LABEL: Record<ActionKind, string> = {
  leave: 'Leave request',
  document: 'Document renewal',
  change_request: 'Profile change request',
  shift_swap: 'Shift swap',
}

export default function Dashboard() {
  const { profile, activeEntityId, entities } = useAuth()
  const [kpis, setKpis] = useState<Kpis>({
    activeEmployees: null,
    expiringDocuments: null,
    pendingLeave: null,
    openPayrollRuns: null,
  })
  const [coverage, setCoverage] = useState<{ location: string; active: number }[]>([])
  const [actions, setActions] = useState<ActionItem[]>([])
  const [loading, setLoading] = useState(true)

  const canSeePayroll = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const activeEntity = entities.find((e) => e.id === activeEntityId)

  useEffect(() => {
    if (!activeEntityId) return
    let cancelled = false
    setLoading(true)
    // Switching entity: never show the previous entity's rows while loading.
    setActions([])
    setCoverage([])

    async function load() {
      const today = new Date()
      const in30 = new Date(today)
      in30.setDate(in30.getDate() + 30)
      const todayStr = today.toISOString().slice(0, 10)
      const in30Str = in30.toISOString().slice(0, 10)

      const [employeesRes, docsRes, leaveRes, payrollRes, locationsRes] = await Promise.all([
        supabase
          .from('employees')
          .select('id, home_location_id, locations(name)', { count: 'exact' })
          .eq('entity_id', activeEntityId)
          .eq('employment_status', 'active'),
        supabase
          .from('employee_documents')
          .select('id, doc_type, expiry_date, employees!inner(id, full_name, entity_id)')
          .eq('employees.entity_id', activeEntityId)
          .lte('expiry_date', in30Str)
          .order('expiry_date', { ascending: true }),
        supabase
          .from('leave_requests')
          .select('id, start_date, end_date, status, requested_at, employees!inner(id, full_name, entity_id)')
          .eq('employees.entity_id', activeEntityId)
          .eq('status', 'pending')
          .order('requested_at', { ascending: true }),
        canSeePayroll
          ? supabase
              .from('payroll_runs')
              .select('id, status', { count: 'exact' })
              .eq('entity_id', activeEntityId)
              .in('status', ['draft', 'in_review', 'approved'])
          : Promise.resolve({ data: [], count: 0, error: null } as const),
        supabase.from('locations').select('id, name').eq('entity_id', activeEntityId),
      ])

      if (cancelled) return

      const employees = employeesRes.data ?? []
      const byLocation = new Map<string, number>()
      for (const emp of employees) {
        const locName =
          (emp as unknown as { locations?: { name: string } | null }).locations?.name ?? 'Unassigned'
        byLocation.set(locName, (byLocation.get(locName) ?? 0) + 1)
      }
      const locationNames = (locationsRes.data ?? []).map((l) => l.name)
      const coverageRows = locationNames.map((name) => ({ location: name, active: byLocation.get(name) ?? 0 }))
      if (byLocation.has('Unassigned')) {
        coverageRows.push({ location: 'Unassigned', active: byLocation.get('Unassigned') ?? 0 })
      }
      setCoverage(coverageRows)

      setKpis({
        activeEmployees: employeesRes.count ?? employees.length,
        expiringDocuments: docsRes.data?.length ?? 0,
        pendingLeave: leaveRes.data?.length ?? 0,
        openPayrollRuns: canSeePayroll ? (payrollRes.count ?? 0) : null,
      })

      const documentActions: ActionItem[] = (docsRes.data ?? []).map((doc) => {
        const employeeName =
          (doc as unknown as { employees?: { full_name: string } }).employees?.full_name ?? 'Employee'
        const isExpired = doc.expiry_date ? doc.expiry_date < todayStr : false
        return {
          id: `doc-${doc.id}`,
          kind: 'document',
          title: `${employeeName} — ${doc.doc_type.replace('_', ' ')}`,
          subtitle: doc.expiry_date
            ? isExpired
              ? `Expired ${fmtDate(doc.expiry_date)}`
              : `Expires ${fmtDate(doc.expiry_date)}`
            : 'Expiry date missing',
          status: isExpired ? 'expired' : 'expiring',
          href: '/documents',
          urgent: isExpired,
        }
      })

      const leaveActions: ActionItem[] = (leaveRes.data ?? []).map((req) => {
        const employeeName =
          (req as unknown as { employees?: { full_name: string } }).employees?.full_name ?? 'Employee'
        return {
          id: `leave-${req.id}`,
          kind: 'leave',
          title: `${employeeName} — leave request`,
          subtitle: `${fmtDate(req.start_date)} → ${fmtDate(req.end_date)}`,
          status: req.status,
          href: '/leave',
          urgent: false,
        }
      })

      const combined = [...documentActions, ...leaveActions].sort((a, b) =>
        a.urgent === b.urgent ? 0 : a.urgent ? -1 : 1
      )
      setActions(combined)
      setLoading(false)
    }

    load()
    return () => {
      cancelled = true
    }
  }, [activeEntityId, canSeePayroll])

  const greeting = useMemo(() => {
    const hour = new Date().getHours()
    if (hour < 12) return 'Good morning'
    if (hour < 17) return 'Good afternoon'
    return 'Good evening'
  }, [])

  const firstName = profile?.full_name?.split(' ')[0]

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">
            {profile?.role === 'staff' ? 'Home' : `${greeting}${firstName ? `, ${firstName}` : ''}`}
          </h1>
          <p className="text-xs text-muted">Entity-level workforce, compliance and payroll status</p>
        </div>
      </div>

      {profile?.role === 'owner' && entities.length > 1 && <GroupOverview entityCount={entities.length} />}

      <div className="flex items-center justify-between gap-3 rounded-[14px] border border-border bg-surface p-[18px] shadow-card">
        <div className="flex min-w-0 items-center gap-3">
          <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-brand-blue-soft text-xs font-bold text-brand-blue-text">
            {activeEntity?.name?.slice(0, 3).toUpperCase() ?? '—'}
          </span>
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold text-ink">{activeEntity?.name ?? 'No entity selected'}</p>
            <p className="truncate text-xs text-muted">All records below are isolated to this legal entity</p>
          </div>
        </div>
        <div className="hidden shrink-0 items-center gap-4 text-xs text-muted sm:flex">
          <span>{coverage.length} branch{coverage.length === 1 ? '' : 'es'}</span>
          <span>{kpis.activeEmployees ?? 0} employees</span>
          <StatusBadge status="active" />
        </div>
      </div>

      <section className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <KpiCard
          label="Employees"
          value={kpis.activeEmployees ?? '—'}
          hint="Across this entity"
          loading={loading}
          icon={<Icon d="M16 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9.5 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z" />}
        />
        <KpiCard
          label="Documents expiring (30d)"
          value={kpis.expiringDocuments ?? '—'}
          hint="Documents tracked"
          tone={kpis.expiringDocuments ? 'warning' : 'default'}
          loading={loading}
          icon={<Icon d="M12 7v5l3 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z" />}
        />
        <KpiCard
          label="Pending leave requests"
          value={kpis.pendingLeave ?? '—'}
          hint="Awaiting decision"
          tone={kpis.pendingLeave ? 'warning' : 'default'}
          loading={loading}
          icon={<Icon d="M8 3v4M16 3v4M4 10h16M5 5h14a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Z" />}
        />
        {canSeePayroll && (
          <KpiCard
            label="Current payroll"
            value={kpis.openPayrollRuns ? `${kpis.openPayrollRuns} open` : 'Not started'}
            hint="Entity-specific pay run"
            loading={loading}
            icon={<Icon d="M4 6h16v12H4zM4 10h16M8 15h4" />}
          />
        )}
      </section>

      <section className="grid gap-4 lg:grid-cols-3">
        <div className="rounded-[14px] border border-border bg-surface p-[18px] shadow-card lg:col-span-2">
          <div className="mb-3 flex items-center justify-between">
            <h2 className="text-base font-semibold text-ink">Action centre</h2>
            <span className="text-xs text-muted">{actions.length} item{actions.length === 1 ? '' : 's'}</span>
          </div>

          {loading ? (
            <div className="space-y-2">
              {[0, 1, 2].map((i) => (
                <div key={i} className="h-14 animate-pulse rounded-lg bg-surface-alt" />
              ))}
            </div>
          ) : actions.length === 0 ? (
            <EmptyState
              title="Nothing needs attention right now"
              description="Leave requests, expiring documents and other exceptions for this entity will appear here as they come up."
            />
          ) : (
            <ul className="divide-y divide-border">
              {actions.slice(0, 8).map((item) => (
                <li key={item.id} className="flex items-center justify-between gap-3 py-3">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-ink">{item.title}</p>
                    <p className="text-xs text-muted">
                      {KIND_LABEL[item.kind]} · {item.subtitle}
                    </p>
                  </div>
                  <div className="flex shrink-0 items-center gap-3">
                    <StatusBadge status={item.status} />
                    <Link to={item.href} className="btn-secondary" aria-label={`Open ${item.title}`}>
                      Open
                    </Link>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="rounded-[14px] border border-border bg-surface p-[18px] shadow-card">
          <div className="mb-3 flex items-center justify-between">
            <h2 className="text-base font-semibold text-ink">Operational coverage</h2>
            <Link to="/schedules" className="text-xs font-medium text-brand-blue">
              Open schedule →
            </Link>
          </div>
          {loading ? (
            <div className="space-y-2">
              {[0, 1].map((i) => (
                <div key={i} className="h-10 animate-pulse rounded-lg bg-surface-alt" />
              ))}
            </div>
          ) : coverage.length === 0 ? (
            <EmptyState title="No branches configured for this entity yet" />
          ) : (
            <ul className="space-y-2">
              {coverage.map((row) => (
                <li
                  key={row.location}
                  className="flex items-center justify-between rounded-lg bg-surface-alt px-3 py-2 text-sm"
                >
                  <span className="text-ink">{row.location}</span>
                  <span className="font-medium text-muted">{row.active} active</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  )
}

function Icon({ d }: { d: string }) {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth={1.75}>
      <path d={d} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}
