import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { Alert, PageHeader, Skeleton } from '../components/ui'
import { EmptyState } from '../components/EmptyState'
import { fmtDayShort, fmtMinutes, fmtTime } from '../lib/format'

// Manager "Today" board (P1-3). One read — get_branch_today — scoped on the
// server exactly like attendance exceptions; it never returns pay data.

type PersonStatus = 'upcoming' | 'not_in' | 'in' | 'in_late' | 'done' | 'no_show'

interface TodayPerson {
  shift_id: string
  employee_id: string
  name: string
  phone: string | null
  position: string | null
  start_time: string
  end_time: string
  clock_in_at: string | null
  clock_out_at: string | null
  late_minutes: number
  status: PersonStatus
}

interface BranchToday {
  location_name: string
  date: string
  generated_at: string
  people: TodayPerson[]
  unscheduled: { attendance_id: string; employee_id: string; name: string; clock_in_at: string; clock_out_at: string | null }[]
  missing_clock_outs: { attendance_id: string; employee_id: string; name: string; business_date: string; clock_in_at: string }[]
  open_gaps: { shift_id: string; position: string | null; start_time: string; end_time: string; is_published: boolean }[]
  on_leave: { employee_id: string; name: string; leave_type: string | null; end_date: string }[]
  draft_shifts: number
  approvals: { leave: number; swaps: number; documents: number }
}

const REFRESH_MS = 60_000

export default function Today() {
  const { profile, activeEntityId } = useAuth()
  const [locations, setLocations] = useState<{ id: string; name: string }[]>([])
  const [locationId, setLocationId] = useState<string | null>(null)
  const [data, setData] = useState<BranchToday | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let q = supabase.from('locations').select('id, name').order('name')
    if (activeEntityId) q = q.eq('entity_id', activeEntityId)
    if (profile?.role === 'location_manager' && profile.location_id) q = q.eq('id', profile.location_id)
    q.then(({ data: rows, error: e }) => {
      if (e) return setError(e.message)
      const list = (rows ?? []) as { id: string; name: string }[]
      setLocations(list)
      setLocationId((cur) => (cur && list.some((l) => l.id === cur) ? cur : (list[0]?.id ?? null)))
      if (list.length === 0) setLoading(false)
    })
  }, [activeEntityId, profile?.role, profile?.location_id])

  const load = useCallback(
    async (quiet = false) => {
      if (!locationId) return
      if (!quiet) setLoading(true)
      const { data: res, error: e } = await supabase.rpc('get_branch_today', { p_location_id: locationId })
      if (e) setError(e.message)
      else {
        setError(null)
        setData(res as BranchToday)
      }
      setLoading(false)
    },
    [locationId]
  )

  useEffect(() => {
    load()
    const t = window.setInterval(() => {
      if (document.visibilityState === 'visible') load(true)
    }, REFRESH_MS)
    return () => window.clearInterval(t)
  }, [load])

  const needsAction = data ? data.people.filter((p) => p.status === 'not_in' || p.status === 'no_show') : []
  const inNow = data ? data.people.filter((p) => p.status === 'in' || p.status === 'in_late') : []
  const later = data ? data.people.filter((p) => p.status === 'upcoming') : []
  const done = data ? data.people.filter((p) => p.status === 'done') : []
  const approvalsTotal = data ? data.approvals.leave + data.approvals.swaps + data.approvals.documents : 0

  return (
    <div className="mx-auto max-w-2xl space-y-5">
      <PageHeader
        title="Today"
        description={data ? `${data.location_name} · ${fmtDayShort(data.date)} · updated ${fmtTime(data.generated_at)}` : 'Your branch right now'}
        actions={
          <div className="flex items-center gap-2">
            {locations.length > 1 && (
              <select
                aria-label="Branch"
                value={locationId ?? ''}
                onChange={(e) => setLocationId(e.target.value)}
                className="rounded-lg border border-border bg-surface px-3 py-2 text-sm"
              >
                {locations.map((l) => (
                  <option key={l.id} value={l.id}>
                    {l.name}
                  </option>
                ))}
              </select>
            )}
            <button onClick={() => load()} className="press rounded-lg border border-border bg-surface px-3 py-2 text-sm font-medium text-ink">
              Refresh
            </button>
          </div>
        }
      />

      {error && <Alert tone="error">{error}</Alert>}

      {loading && !data ? (
        <Skeleton rows={4} className="h-20" />
      ) : !locationId ? (
        <EmptyState title="No branch to show" description="You're not assigned to a branch yet." />
      ) : data ? (
        <>
          <div className="grid grid-cols-4 gap-2 text-center">
            <Stat label="Scheduled" value={data.people.length} />
            <Stat label="In now" value={inNow.length} />
            <Stat label="Not in" value={needsAction.length} tone={needsAction.length ? 'risk' : 'default'} />
            <Stat label="Approvals" value={approvalsTotal} tone={approvalsTotal ? 'warning' : 'default'} />
          </div>

          {data.draft_shifts > 0 && (
            <Alert tone="warning">
              {data.draft_shifts} shift{data.draft_shifts === 1 ? ' is' : 's are'} still a draft for today — staff can't see{' '}
              {data.draft_shifts === 1 ? 'it' : 'them'}. <Link to="/schedules" className="font-medium underline">Publish in Schedules</Link>
            </Alert>
          )}

          <Section title="Needs you now" count={needsAction.length + data.missing_clock_outs.length + data.open_gaps.length + data.unscheduled.length}>
            {needsAction.map((p) => (
              <Card
                key={p.shift_id}
                tone="risk"
                title={p.name}
                subtitle={`${fmtTime(p.start_time)}–${fmtTime(p.end_time)}${p.position ? ` · ${p.position}` : ''}`}
                badge={p.status === 'no_show' ? 'No show' : `Not in · ${fmtMinutes(p.late_minutes)} late`}
                action={p.phone ? <ActionLink href={`tel:${p.phone}`}>Call</ActionLink> : <ActionLink to={`/employees/${p.employee_id}`}>Profile</ActionLink>}
              />
            ))}
            {data.open_gaps.map((g) => (
              <Card
                key={g.shift_id}
                tone="warning"
                title={`Open shift ${fmtTime(g.start_time)}–${fmtTime(g.end_time)}`}
                subtitle={g.position ?? 'No one assigned'}
                badge={g.is_published ? 'Unfilled' : 'Draft · unfilled'}
                action={<ActionLink to={`/schedules?shift=${g.shift_id}`}>Find cover</ActionLink>}
              />
            ))}
            {data.missing_clock_outs.map((m) => (
              <Card
                key={m.attendance_id}
                tone="warning"
                title={m.name}
                subtitle={`Clocked in ${fmtDayShort(m.business_date)} at ${fmtTime(m.clock_in_at)} — never clocked out`}
                badge="Missing clock-out"
                action={<ActionLink to="/attendance">Fix</ActionLink>}
              />
            ))}
            {data.unscheduled.map((u) => (
              <Card
                key={u.attendance_id}
                tone="warning"
                title={u.name}
                subtitle={`Clocked in ${fmtTime(u.clock_in_at)}${u.clock_out_at ? `, out ${fmtTime(u.clock_out_at)}` : ''} with no shift today`}
                badge="No shift"
                action={<ActionLink to="/attendance">Review</ActionLink>}
              />
            ))}
          </Section>

          {approvalsTotal > 0 && (
            <Section title="Waiting for your approval" count={approvalsTotal}>
              {data.approvals.leave > 0 && (
                <Card title={`${data.approvals.leave} leave request${data.approvals.leave === 1 ? '' : 's'}`} action={<ActionLink to="/leave">Review</ActionLink>} />
              )}
              {data.approvals.swaps > 0 && (
                <Card title={`${data.approvals.swaps} shift swap${data.approvals.swaps === 1 ? '' : 's'}`} action={<ActionLink to="/schedules">Review</ActionLink>} />
              )}
              {data.approvals.documents > 0 && (
                <Card title={`${data.approvals.documents} document${data.approvals.documents === 1 ? '' : 's'} to check`} action={<ActionLink to="/documents">Review</ActionLink>} />
              )}
            </Section>
          )}

          <Section title="Working now" count={inNow.length}>
            {inNow.map((p) => (
              <Card
                key={p.shift_id}
                tone={p.status === 'in_late' ? 'warning' : 'good'}
                title={p.name}
                subtitle={`${fmtTime(p.start_time)}–${fmtTime(p.end_time)} · in at ${fmtTime(p.clock_in_at)}`}
                badge={p.status === 'in_late' ? `${fmtMinutes(p.late_minutes)} late` : 'In'}
              />
            ))}
          </Section>

          <Section title="Later today" count={later.length}>
            {later.map((p) => (
              <Card key={p.shift_id} title={p.name} subtitle={`${fmtTime(p.start_time)}–${fmtTime(p.end_time)}${p.position ? ` · ${p.position}` : ''}`} />
            ))}
          </Section>

          {done.length > 0 && (
            <Section title="Finished" count={done.length}>
              {done.map((p) => (
                <Card key={p.shift_id} title={p.name} subtitle={`${fmtTime(p.clock_in_at)}–${fmtTime(p.clock_out_at)}`} badge="Done" />
              ))}
            </Section>
          )}

          {data.on_leave.length > 0 && (
            <Section title="On leave" count={data.on_leave.length}>
              {data.on_leave.map((l) => (
                <Card key={l.employee_id} title={l.name} subtitle={`${l.leave_type ?? 'Leave'} · until ${fmtDayShort(l.end_date)}`} />
              ))}
            </Section>
          )}
        </>
      ) : null}
    </div>
  )
}

type Tone = 'default' | 'good' | 'warning' | 'risk'

const BADGE_TONE: Record<Tone, string> = {
  default: 'bg-surface-alt text-muted-strong',
  good: 'bg-brand-action-soft text-brand-action-text',
  warning: 'bg-brand-warning-soft text-brand-warning-solid',
  risk: 'bg-brand-risk-soft text-brand-risk-text',
}

function Stat({ label, value, tone = 'default' }: { label: string; value: number; tone?: Tone }) {
  const color = tone === 'risk' ? 'text-brand-risk-text' : tone === 'warning' ? 'text-brand-warning-solid' : 'text-ink'
  return (
    <div className="rounded-[14px] border border-border bg-surface px-2 py-3 shadow-card">
      <div className={`text-2xl font-semibold tabular-nums ${color}`}>{value}</div>
      <div className="mt-0.5 text-[11px] font-medium uppercase tracking-wide text-muted">{label}</div>
    </div>
  )
}

function Section({ title, count, children }: { title: string; count: number; children: ReactNode }) {
  return (
    <section className="space-y-2">
      <h2 className="text-sm font-semibold text-ink">
        {title} <span className="font-normal text-muted">· {count}</span>
      </h2>
      {count === 0 ? <p className="text-sm text-muted">Nothing here.</p> : <div className="space-y-2">{children}</div>}
    </section>
  )
}

function Card({ title, subtitle, badge, tone = 'default', action }: { title: string; subtitle?: string; badge?: string; tone?: Tone; action?: ReactNode }) {
  return (
    <div className="flex items-center gap-3 rounded-[14px] border border-border bg-surface px-4 py-3 shadow-card">
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="truncate font-medium text-ink">{title}</span>
          {badge && <span className={`rounded-full px-2 py-px text-[11px] font-semibold ${BADGE_TONE[tone]}`}>{badge}</span>}
        </div>
        {subtitle && <p className="mt-0.5 text-sm text-muted">{subtitle}</p>}
      </div>
      {action}
    </div>
  )
}

function ActionLink({ to, href, children }: { to?: string; href?: string; children: ReactNode }) {
  const cls = 'press shrink-0 rounded-full bg-brand-primary px-4 py-2 text-sm font-semibold text-white'
  return href ? (
    <a href={href} className={cls}>
      {children}
    </a>
  ) : (
    <Link to={to ?? '/'} className={cls}>
      {children}
    </Link>
  )
}
