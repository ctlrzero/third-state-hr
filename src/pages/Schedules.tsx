import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { fmtDayShort, fmtTime } from '../lib/format'
import { Link } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import type {
  Employee,
  Location,
  Position,
  ScheduleTemplate,
  Shift,
  ShiftStatus,
  ShiftSwapRequest,
} from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'

const DOW_LABELS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}
function addDaysIso(iso: string, days: number) {
  const d = new Date(iso + 'T00:00:00')
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

const SHIFT_STATUS_TONE: Record<ShiftStatus, 'neutral' | 'info' | 'success'> = {
  open: 'info',
  assigned: 'success',
  cancelled: 'neutral',
}

const SWAP_STATUS_TONE: Record<string, 'neutral' | 'info' | 'warning' | 'success' | 'risk'> = {
  open: 'info',
  claimed: 'warning',
  approved: 'success',
  rejected: 'risk',
  cancelled: 'neutral',
}

// UAE-readable dates / 24h times (Asia/Dubai) shared across the app.
const fmtDate = (d: string) => fmtDayShort(d)

// Schedules: shifts + shift_swap_requests. Admin (owner/entity_admin/
// location_manager) get a roster: create/cancel shifts, resolve swap
// requests. Staff get "My Schedule": their own upcoming shifts, an open
// board scoped to their own home location (both open shifts to pick up and
// colleagues' open swaps to claim), and their own swap request history.
// Every staff write goes through a SECURITY DEFINER RPC
// (request_shift_swap / claim_shift_swap / claim_open_shift /
// cancel_shift_swap_request) — there is no direct table grant for staff to
// insert/update shifts or shift_swap_requests.
export default function Schedules() {
  const { profile } = useAuth()
  if (profile?.role === 'staff') return <MySchedule />
  return <ScheduleAdmin />
}

// ---------------------------------------------------------------------------
// Admin / manager roster
// ---------------------------------------------------------------------------

function ScheduleAdmin() {
  const { activeEntityId } = useAuth()
  const [shifts, setShifts] = useState<Shift[]>([])
  const [swaps, setSwaps] = useState<ShiftSwapRequest[]>([])
  const [locations, setLocations] = useState<Pick<Location, 'id' | 'name'>[]>([])
  const [positions, setPositions] = useState<Pick<Position, 'id' | 'title'>[]>([])
  const [employees, setEmployees] = useState<Pick<Employee, 'id' | 'full_name' | 'home_location_id'>[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [locationFilter, setLocationFilter] = useState<string>('all')
  const [templates, setTemplates] = useState<ScheduleTemplate[]>([])
  const [templateModalOpen, setTemplateModalOpen] = useState(false)

  const employeesById = useMemo(() => new Map(employees.map((e) => [e.id, e])), [employees])

  async function load() {
    if (!activeEntityId) return
    setLoading(true)
    setError(null)
    const from = new Date()
    from.setDate(from.getDate() - 3)
    const [shiftsRes, swapsRes, locRes, posRes, empRes, templatesRes] = await Promise.all([
      supabase
        .from('shifts')
        .select('*, locations(id, name), positions(id, title)')
        .eq('entity_id', activeEntityId)
        .gte('shift_date', from.toISOString().slice(0, 10))
        .order('shift_date', { ascending: true }),
      supabase
        .from('shift_swap_requests')
        .select('*, shifts!inner(id, shift_date, start_time, end_time, location_id, entity_id, locations(id, name))')
        .eq('shifts.entity_id', activeEntityId)
        .order('created_at', { ascending: false }),
      supabase.from('locations').select('id, name').eq('entity_id', activeEntityId).order('name'),
      supabase.from('positions').select('id, title').eq('entity_id', activeEntityId).order('title'),
      supabase.from('employees').select('id, full_name, home_location_id').eq('entity_id', activeEntityId).order('full_name'),
      supabase
        .from('schedule_templates')
        .select('*, employees(id, full_name), positions(id, title)')
        .eq('entity_id', activeEntityId)
        .eq('is_active', true)
        .order('day_of_week', { ascending: true }),
    ])
    if (shiftsRes.error) setError(shiftsRes.error.message)
    else setShifts((shiftsRes.data ?? []) as unknown as Shift[])
    setSwaps((swapsRes.data ?? []) as unknown as ShiftSwapRequest[])
    setLocations(locRes.data ?? [])
    setPositions(posRes.data ?? [])
    setEmployees(empRes.data ?? [])
    setTemplates((templatesRes.data ?? []) as unknown as ScheduleTemplate[])
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeEntityId])

  const visibleShifts = useMemo(
    () => (locationFilter === 'all' ? shifts : shifts.filter((s) => s.location_id === locationFilter)),
    [shifts, locationFilter]
  )

  async function handleCancelShift(id: string) {
    if (!confirm('Cancel this shift?')) return
    const { error: updateError } = await supabase.from('shifts').update({ status: 'cancelled' }).eq('id', id)
    if (updateError) {
      setError(updateError.message)
      return
    }
    load()
  }

  async function handleDeactivateTemplate(id: string) {
    if (!confirm('Deactivate this recurring template? Existing generated shifts are unaffected.')) return
    const { error: rpcError } = await supabase.rpc('deactivate_schedule_template', { p_template_id: id })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    load()
  }

  async function handleResolveSwap(id: string, action: 'approve' | 'reject') {
    const { error: rpcError } = await supabase.rpc('approve_shift_swap', { p_swap_id: id, p_action: action })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setNotice(action === 'approve' ? 'Swap approved — the shift has been reassigned.' : 'Swap rejected.')
    load()
  }

  const pendingSwaps = swaps.filter((s) => s.status === 'claimed')
  const otherSwaps = swaps.filter((s) => s.status !== 'claimed')

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Schedules</h1>
          <p className="text-xs text-muted">{loading ? 'Loading…' : `${visibleShifts.length} shifts`}</p>
        </div>
        <button
          onClick={() => setCreateOpen(true)}
          className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark"
        >
          New shift
        </button>
      </div>

      {error && (
        <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">
          {error}{' '}
          <button className="underline" onClick={() => setError(null)}>
            Dismiss
          </button>
        </p>
      )}
      {notice && (
        <p className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      {pendingSwaps.length > 0 && (
        <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Swap requests awaiting your decision</h2>
          <ul className="space-y-2">
            {pendingSwaps.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  {s.shifts && `${fmtDate(s.shifts.shift_date)} · ${fmtTime(s.shifts.start_time)}–${fmtTime(s.shifts.end_time)} · ${s.shifts.locations?.name ?? ''}`}
                  {' · '}
                  {employeesById.get(s.requested_by)?.full_name ?? 'Unknown'} → {employeesById.get(s.claimed_by ?? '')?.full_name ?? 'Unknown'}
                </span>
                <span className="flex gap-1">
                  <button onClick={() => handleResolveSwap(s.id, 'approve')} className="rounded-full bg-brand-action-soft px-2 py-1 font-medium text-brand-action-text">
                    Approve
                  </button>
                  <button onClick={() => handleResolveSwap(s.id, 'reject')} className="rounded-full bg-brand-risk-soft px-2 py-1 font-medium text-brand-risk-text">
                    Reject
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted w-full sm:w-56">
        Branch
        <select
          value={locationFilter}
          onChange={(e) => setLocationFilter(e.target.value)}
          className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          <option value="all">All branches</option>
          {locations.map((l) => (
            <option key={l.id} value={l.id}>
              {l.name}
            </option>
          ))}
        </select>
      </label>

      <RecurringTemplatesPanel
        templates={templates}
        locations={locations}
        onNewTemplate={() => setTemplateModalOpen(true)}
        onDeactivate={handleDeactivateTemplate}
        onGenerated={() => {
          setNotice('Draft shifts generated from your recurring templates. Review below, then publish when ready.')
          load()
        }}
        onPublished={() => {
          setNotice('Schedule published — those shifts are now visible to employees.')
          load()
        }}
        onError={setError}
      />

      <Link
        to="/attendance"
        className="card flex min-h-11 items-center justify-between gap-3 transition hover:border-brand-blue/40"
      >
        <span>
          <span className="block text-sm font-semibold text-ink">Attendance exceptions & corrections</span>
          <span className="block text-sm text-muted">Review missing clock-outs, late clock-ins and payable time in Attendance.</span>
        </span>
        <span className="btn-secondary">Open Attendance</span>
      </Link>

      {loading ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-14 animate-pulse rounded-[14px] bg-surface" />
          ))}
        </div>
      ) : visibleShifts.length === 0 ? (
        <EmptyState title="No shifts in this window" description="Create a shift to start building the roster." />
      ) : (
        <div className="overflow-hidden rounded-[14px] border border-border bg-surface shadow-card">
          <table className="table-stack w-full text-left text-sm">
            <thead className="border-b border-border bg-surface-alt text-xs uppercase tracking-wide text-muted">
              <tr>
                <th className="px-4 py-3 font-medium">Date</th>
                <th className="px-4 py-3 font-medium">Time</th>
                <th className="px-4 py-3 font-medium">Branch</th>
                <th className="px-4 py-3 font-medium">Role</th>
                <th className="px-4 py-3 font-medium">Assigned to</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {visibleShifts.map((s) => (
                <tr key={s.id}>
                  <td data-label="Date" className="px-4 py-3 text-ink">{fmtDate(s.shift_date)}</td>
                  <td data-label="Time" className="px-4 py-3 text-muted">
                    {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                  </td>
                  <td data-label="Branch" className="px-4 py-3 text-muted">{s.locations?.name ?? '—'}</td>
                  <td data-label="Role" className="px-4 py-3 text-muted">{s.positions?.title ?? '—'}</td>
                  <td data-label="Assigned to" className="px-4 py-3 text-muted">{s.employees?.full_name ?? '—'}</td>
                  <td data-label="Status" className="px-4 py-3">
                    <span className="flex items-center gap-1.5">
                      <StatusBadge status={s.status} tone={SHIFT_STATUS_TONE[s.status]} />
                      {!s.is_published && <StatusBadge status="draft" />}
                    </span>
                  </td>
                  <td data-label="Actions" className="px-4 py-3 text-right">
                    {s.status !== 'cancelled' && (
                      <button onClick={() => handleCancelShift(s.id)} className="text-xs font-medium text-brand-risk hover:underline">
                        Cancel
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {otherSwaps.length > 0 && (
        <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Swap history</h2>
          <ul className="space-y-1.5">
            {otherSwaps.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  {s.shifts && `${fmtDate(s.shifts.shift_date)} · ${s.shifts.locations?.name ?? ''}`}
                  {' · '}
                  {employeesById.get(s.requested_by)?.full_name ?? 'Unknown'}
                  {s.claimed_by && ` → ${employeesById.get(s.claimed_by)?.full_name ?? 'Unknown'}`}
                </span>
                <StatusBadge status={s.status} tone={SWAP_STATUS_TONE[s.status]} />
              </li>
            ))}
          </ul>
        </div>
      )}

      {createOpen && activeEntityId && (
        <NewShiftModal
          entityId={activeEntityId}
          locations={locations}
          positions={positions}
          employees={employees}
          onClose={() => setCreateOpen(false)}
          onCreated={() => {
            setCreateOpen(false)
            load()
          }}
        />
      )}

      {templateModalOpen && (
        <NewTemplateModal
          locations={locations}
          positions={positions}
          employees={employees}
          onClose={() => setTemplateModalOpen(false)}
          onCreated={() => {
            setTemplateModalOpen(false)
            load()
          }}
        />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Recurring schedule templates (Phase 2.6)
// ---------------------------------------------------------------------------

function RecurringTemplatesPanel({
  templates,
  locations,
  onNewTemplate,
  onDeactivate,
  onGenerated,
  onPublished,
  onError,
}: {
  templates: ScheduleTemplate[]
  locations: Pick<Location, 'id' | 'name'>[]
  onNewTemplate: () => void
  onDeactivate: (id: string) => void
  onGenerated: () => void
  onPublished: () => void
  onError: (message: string) => void
}) {
  const [genLocationId, setGenLocationId] = useState(locations[0]?.id ?? '')
  const [periodStart, setPeriodStart] = useState(todayIso())
  const [periodEnd, setPeriodEnd] = useState(addDaysIso(todayIso(), 13))
  const [busy, setBusy] = useState<'generate' | 'publish' | null>(null)

  useEffect(() => {
    if (!genLocationId && locations[0]) setGenLocationId(locations[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [locations])

  async function handleGenerate() {
    if (!genLocationId) return
    setBusy('generate')
    const { error } = await supabase.rpc('generate_shifts_from_templates', {
      p_location_id: genLocationId,
      p_period_start: periodStart,
      p_period_end: periodEnd,
    })
    setBusy(null)
    if (error) {
      onError(error.message)
      return
    }
    onGenerated()
  }

  async function handlePublish() {
    if (!genLocationId) return
    if (!confirm('Publish all draft shifts in this branch and period? They will become visible to employees.')) return
    setBusy('publish')
    const { error } = await supabase.rpc('publish_schedule_period', {
      p_location_id: genLocationId,
      p_period_start: periodStart,
      p_period_end: periodEnd,
    })
    setBusy(null)
    if (error) {
      onError(error.message)
      return
    }
    onPublished()
  }

  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-sm font-semibold text-ink">Recurring templates</h2>
          <p className="text-xs text-muted">Weekly assignments that generate draft shifts for a period, then publish.</p>
        </div>
        <button
          onClick={onNewTemplate}
          className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
        >
          New template
        </button>
      </div>

      {templates.length === 0 ? (
        <p className="mb-4 text-sm text-muted">No active recurring templates yet.</p>
      ) : (
        <ul className="mb-4 space-y-1.5">
          {templates.map((t) => (
            <li key={t.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
              <span className="text-ink">
                {t.employees?.full_name ?? '—'} · {DOW_LABELS[t.day_of_week]} · {fmtTime(t.start_time)}–{fmtTime(t.end_time)}
                {t.break_minutes > 0 ? ` · ${t.break_minutes}m break` : ''}
                {t.positions?.title ? ` · ${t.positions.title}` : ''}
                {' · from '}
                {t.effective_start_date}
                {t.effective_end_date ? ` to ${t.effective_end_date}` : ' (ongoing)'}
              </span>
              <button onClick={() => onDeactivate(t.id)} className="font-medium text-brand-risk hover:underline">
                Deactivate
              </button>
            </li>
          ))}
        </ul>
      )}

      <div className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
        <div>
          <label htmlFor="schedules-branch-1" className="mb-1 block text-xs font-medium text-ink">Branch</label>
          <select id="schedules-branch-1"
            value={genLocationId}
            onChange={(e) => setGenLocationId(e.target.value)}
            className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label htmlFor="schedules-period-start-2" className="mb-1 block text-xs font-medium text-ink">Period start</label>
          <input id="schedules-period-start-2"
            type="date"
            value={periodStart}
            onChange={(e) => setPeriodStart(e.target.value)}
            className="rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          />
        </div>
        <div>
          <label htmlFor="schedules-period-end-3" className="mb-1 block text-xs font-medium text-ink">Period end</label>
          <input id="schedules-period-end-3"
            type="date"
            value={periodEnd}
            onChange={(e) => setPeriodEnd(e.target.value)}
            className="rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          />
        </div>
        <button
          onClick={handleGenerate}
          disabled={busy !== null || !genLocationId}
          className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-ink hover:bg-surface-alt disabled:opacity-60"
        >
          {busy === 'generate' ? 'Generating…' : 'Generate drafts'}
        </button>
        <button
          onClick={handlePublish}
          disabled={busy !== null || !genLocationId}
          className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
        >
          {busy === 'publish' ? 'Publishing…' : 'Publish period'}
        </button>
      </div>
    </div>
  )
}

function NewTemplateModal({
  locations,
  positions,
  employees,
  onClose,
  onCreated,
}: {
  locations: Pick<Location, 'id' | 'name'>[]
  positions: Pick<Position, 'id' | 'title'>[]
  employees: Pick<Employee, 'id' | 'full_name' | 'home_location_id'>[]
  onClose: () => void
  onCreated: () => void
}) {
  const [locationId, setLocationId] = useState(locations[0]?.id ?? '')
  const [employeeId, setEmployeeId] = useState('')
  const [positionId, setPositionId] = useState('')
  const [dayOfWeek, setDayOfWeek] = useState(1)
  const [startTime, setStartTime] = useState('09:00')
  const [endTime, setEndTime] = useState('17:00')
  const [breakMinutes, setBreakMinutes] = useState(30)
  const [effectiveStart, setEffectiveStart] = useState(todayIso())
  const [effectiveEnd, setEffectiveEnd] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const eligibleEmployees = employees.filter((e) => !locationId || e.home_location_id === locationId)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!locationId || !employeeId) {
      setError('Choose a branch and an employee.')
      return
    }
    setSubmitting(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('create_schedule_template', {
      p_location_id: locationId,
      p_employee_id: employeeId,
      p_position_id: positionId || null,
      p_day_of_week: dayOfWeek,
      p_start_time: startTime,
      p_end_time: endTime,
      p_break_minutes: breakMinutes,
      p_effective_start_date: effectiveStart,
      p_effective_end_date: effectiveEnd || null,
    })
    setSubmitting(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    onCreated()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">New recurring template</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="schedules-branch-4" className="mb-1 block text-sm font-medium text-ink">Branch</label>
            <select id="schedules-branch-4"
              value={locationId}
              onChange={(e) => {
                setLocationId(e.target.value)
                setEmployeeId('')
              }}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="schedules-employee-5" className="mb-1 block text-sm font-medium text-ink">Employee</label>
            <select id="schedules-employee-5"
              value={employeeId}
              onChange={(e) => setEmployeeId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="">Choose an employee based at this branch</option>
              {eligibleEmployees.map((e) => (
                <option key={e.id} value={e.id}>
                  {e.full_name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="schedules-day-of-week-6" className="mb-1 block text-sm font-medium text-ink">Day of week</label>
            <select id="schedules-day-of-week-6"
              value={dayOfWeek}
              onChange={(e) => setDayOfWeek(Number(e.target.value))}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {DOW_LABELS.map((label, i) => (
                <option key={i} value={i}>
                  {label}
                </option>
              ))}
            </select>
          </div>
          <div className="grid grid-cols-3 gap-2">
            <div>
              <label htmlFor="schedules-start-7" className="mb-1 block text-sm font-medium text-ink">Start</label>
              <input id="schedules-start-7"
                type="time"
                value={startTime}
                onChange={(e) => setStartTime(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="schedules-end-8" className="mb-1 block text-sm font-medium text-ink">End</label>
              <input id="schedules-end-8"
                type="time"
                value={endTime}
                onChange={(e) => setEndTime(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="schedules-break-min-9" className="mb-1 block text-sm font-medium text-ink">Break (min)</label>
              <input id="schedules-break-min-9"
                type="number"
                min={0}
                value={breakMinutes}
                onChange={(e) => setBreakMinutes(Number(e.target.value))}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          <div>
            <label htmlFor="schedules-role-optional-10" className="mb-1 block text-sm font-medium text-ink">Role (optional)</label>
            <select id="schedules-role-optional-10"
              value={positionId}
              onChange={(e) => setPositionId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="">Not specified</option>
              {positions.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.title}
                </option>
              ))}
            </select>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label htmlFor="schedules-effective-from-11" className="mb-1 block text-sm font-medium text-ink">Effective from</label>
              <input id="schedules-effective-from-11"
                type="date"
                value={effectiveStart}
                onChange={(e) => setEffectiveStart(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="schedules-effective-to-optional-12" className="mb-1 block text-sm font-medium text-ink">Effective to (optional)</label>
              <input id="schedules-effective-to-optional-12"
                type="date"
                value={effectiveEnd}
                onChange={(e) => setEffectiveEnd(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>

          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Creating…' : 'Create template'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

function NewShiftModal({
  entityId,
  locations,
  positions,
  employees,
  onClose,
  onCreated,
}: {
  entityId: string
  locations: Pick<Location, 'id' | 'name'>[]
  positions: Pick<Position, 'id' | 'title'>[]
  employees: Pick<Employee, 'id' | 'full_name' | 'home_location_id'>[]
  onClose: () => void
  onCreated: () => void
}) {
  const [locationId, setLocationId] = useState(locations[0]?.id ?? '')
  const [positionId, setPositionId] = useState('')
  const [employeeId, setEmployeeId] = useState('')
  const [shiftDate, setShiftDate] = useState('')
  const [startTime, setStartTime] = useState('09:00')
  const [endTime, setEndTime] = useState('17:00')
  const [notes, setNotes] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const eligibleEmployees = employees.filter((e) => !locationId || e.home_location_id === locationId)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!locationId || !shiftDate || !startTime || !endTime) {
      setError('Choose a branch, date, and start/end time.')
      return
    }
    setSubmitting(true)
    setError(null)
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const { error: insertError } = await supabase.from('shifts').insert({
      entity_id: entityId,
      location_id: locationId,
      position_id: positionId || null,
      employee_id: employeeId || null,
      shift_date: shiftDate,
      start_time: startTime,
      end_time: endTime,
      status: employeeId ? 'assigned' : 'open',
      notes: notes || null,
      created_by: user?.id ?? null,
    })
    setSubmitting(false)
    if (insertError) {
      setError(insertError.message)
      return
    }
    onCreated()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">New shift</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="schedules-branch-13" className="mb-1 block text-sm font-medium text-ink">Branch</label>
            <select id="schedules-branch-13"
              value={locationId}
              onChange={(e) => {
                setLocationId(e.target.value)
                setEmployeeId('')
              }}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
          </div>
          <div className="grid grid-cols-3 gap-2">
            <div className="col-span-1">
              <label htmlFor="schedules-date-14" className="mb-1 block text-sm font-medium text-ink">Date</label>
              <input id="schedules-date-14"
                type="date"
                value={shiftDate}
                onChange={(e) => setShiftDate(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="schedules-start-15" className="mb-1 block text-sm font-medium text-ink">Start</label>
              <input id="schedules-start-15"
                type="time"
                value={startTime}
                onChange={(e) => setStartTime(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="schedules-end-16" className="mb-1 block text-sm font-medium text-ink">End</label>
              <input id="schedules-end-16"
                type="time"
                value={endTime}
                onChange={(e) => setEndTime(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          <div>
            <label htmlFor="schedules-role-optional-17" className="mb-1 block text-sm font-medium text-ink">Role (optional)</label>
            <select id="schedules-role-optional-17"
              value={positionId}
              onChange={(e) => setPositionId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="">Not specified</option>
              {positions.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.title}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="schedules-assign-to-optional-leave-18" className="mb-1 block text-sm font-medium text-ink">Assign to (optional — leave blank to post as open)</label>
            <select id="schedules-assign-to-optional-leave-18"
              value={employeeId}
              onChange={(e) => setEmployeeId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              <option value="">Leave open</option>
              {eligibleEmployees.map((e) => (
                <option key={e.id} value={e.id}>
                  {e.full_name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="schedules-notes-optional-19" className="mb-1 block text-sm font-medium text-ink">Notes (optional)</label>
            <input id="schedules-notes-optional-19"
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>

          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Creating…' : 'Create shift'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Staff self-service
// ---------------------------------------------------------------------------

function MySchedule() {
  const [myShifts, setMyShifts] = useState<Shift[]>([])
  const [openShifts, setOpenShifts] = useState<Shift[]>([])
  const [mySwaps, setMySwaps] = useState<ShiftSwapRequest[]>([])
  const [openSwapBoard, setOpenSwapBoard] = useState<ShiftSwapRequest[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [swapNoteFor, setSwapNoteFor] = useState<string | null>(null)
  const [swapNote, setSwapNote] = useState('')

  async function load() {
    setLoading(true)
    setError(null)
    const {
      data: { user },
    } = await supabase.auth.getUser()
    if (!user) {
      setLoading(false)
      return
    }

    const today = new Date().toISOString().slice(0, 10)

    // These three queries are each scoped by RLS to what this employee is
    // actually allowed to see (own shifts, open shifts at their own home
    // location, and swap requests they're party to or that are open at
    // their own home location) — the .gte()/.order() calls are just
    // presentation, not the security boundary.
    const [shiftsRes, openRes, swapsRes] = await Promise.all([
      supabase
        .from('shifts')
        .select('*, locations(id, name), positions(id, title)')
        .not('employee_id', 'is', null)
        .gte('shift_date', today)
        .order('shift_date', { ascending: true }),
      supabase
        .from('shifts')
        .select('*, locations(id, name), positions(id, title)')
        .eq('status', 'open')
        .gte('shift_date', today)
        .order('shift_date', { ascending: true }),
      supabase
        .from('shift_swap_requests')
        .select('*, shifts(id, shift_date, start_time, end_time, location_id, locations(id, name))')
        .order('created_at', { ascending: false }),
    ])

    if (shiftsRes.error) setError(shiftsRes.error.message)
    else setMyShifts((shiftsRes.data ?? []) as unknown as Shift[])
    setOpenShifts((openRes.data ?? []) as unknown as Shift[])

    const allSwaps = (swapsRes.data ?? []) as unknown as ShiftSwapRequest[]
    setMySwaps(allSwaps)
    setOpenSwapBoard(allSwaps.filter((s) => s.status === 'open'))
    setLoading(false)
  }

  useEffect(() => {
    load()
  }, [])

  async function handleRequestSwap(shiftId: string) {
    setBusyId(shiftId)
    setError(null)
    const { error: rpcError } = await supabase.rpc('request_shift_swap', {
      p_shift_id: shiftId,
      p_notes: swapNote || null,
    })
    setBusyId(null)
    setSwapNoteFor(null)
    setSwapNote('')
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setNotice('Swap request posted — a colleague can claim it, then a manager approves.')
    load()
  }

  async function handlePickUpShift(shiftId: string) {
    setBusyId(shiftId)
    setError(null)
    const { error: rpcError } = await supabase.rpc('claim_open_shift', { p_shift_id: shiftId })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setNotice('Shift picked up.')
    load()
  }

  async function handleClaimSwap(swapId: string) {
    setBusyId(swapId)
    setError(null)
    const { error: rpcError } = await supabase.rpc('claim_shift_swap', { p_swap_id: swapId })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setNotice('Swap claimed — a manager needs to approve it before it’s final.')
    load()
  }

  async function handleCancelSwap(swapId: string) {
    setBusyId(swapId)
    setError(null)
    const { error: rpcError } = await supabase.rpc('cancel_shift_swap_request', { p_swap_id: swapId })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    load()
  }

  const myShiftIds = useMemo(() => new Set(myShifts.map((s) => s.id)), [myShifts])

  // A swap on one of my own shifts (open or still-claimed, not yet
  // approved/rejected) — used to swap the "Request swap" button for a
  // status badge on that shift.
  const swapByShiftId = useMemo(() => {
    const map = new Map<string, ShiftSwapRequest>()
    for (const s of mySwaps) {
      if (myShiftIds.has(s.shift_id) && (s.status === 'open' || s.status === 'claimed')) map.set(s.shift_id, s)
    }
    return map
  }, [mySwaps, myShiftIds])

  // Board excludes my own posted requests — claiming your own swap is
  // rejected server-side by claim_shift_swap() anyway, but there's no
  // reason to show the button here.
  const claimableSwapBoard = useMemo(
    () => openSwapBoard.filter((s) => !myShiftIds.has(s.shift_id)),
    [openSwapBoard, myShiftIds]
  )

  const myOwnSwapHistory = useMemo(() => mySwaps.slice(0, 20), [mySwaps])

  if (loading) {
    return (
      <div className="space-y-3">
        <div className="h-16 animate-pulse rounded-[14px] bg-surface" />
        <div className="h-32 animate-pulse rounded-[14px] bg-surface" />
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div>
        <EntityEyebrow />
        <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">My schedule</h1>
      </div>

      {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
      {notice && (
        <p className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      <Link to="/clock" className="card flex items-center justify-between gap-3 transition hover:border-brand-blue/40">
        <span>
          <span className="block text-sm font-semibold text-ink">Clock in / out</span>
          <span className="block text-sm text-muted">Start and finish your shift on the Clock screen.</span>
        </span>
        <span className="btn-primary">Open Clock</span>
      </Link>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Upcoming shifts</h2>
        {myShifts.length === 0 ? (
          <p className="text-sm text-muted">No upcoming shifts assigned yet.</p>
        ) : (
          <ul className="space-y-2">
            {myShifts.map((s) => {
              const existingSwap = swapByShiftId.get(s.id)
              return (
                <li key={s.id} className="rounded-lg bg-surface-alt px-3 py-2 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="text-ink">
                      {fmtDate(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)} · {s.locations?.name ?? '—'}
                      {s.positions?.title ? ` · ${s.positions.title}` : ''}
                    </span>
                    {existingSwap ? (
                      <StatusBadge status={existingSwap.status} tone={SWAP_STATUS_TONE[existingSwap.status]} />
                    ) : (
                      <button
                        onClick={() => setSwapNoteFor(swapNoteFor === s.id ? null : s.id)}
                        className="rounded-full border border-border px-2.5 py-1 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                      >
                        Request swap
                      </button>
                    )}
                  </div>
                  {swapNoteFor === s.id && (
                    <div className="mt-2 flex flex-wrap items-center gap-2">
                      <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted flex-1">
                        Note for whoever picks this up (optional)
                        <input
                          value={swapNote}
                          onChange={(e) => setSwapNote(e.target.value)}
                          placeholder="Note for whoever picks this up (optional)"
                          className="flex-1 rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                        />
                      </label>
                      <button
                        onClick={() => handleRequestSwap(s.id)}
                        disabled={busyId === s.id}
                        className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white disabled:opacity-60"
                      >
                        {busyId === s.id ? 'Posting…' : 'Post swap'}
                      </button>
                    </div>
                  )}
                </li>
              )
            })}
          </ul>
        )}
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-1 text-sm font-semibold text-ink">Open shifts at your branch</h2>
        <p className="mb-3 text-xs text-muted">Unfilled shifts you can pick up.</p>
        {openShifts.length === 0 ? (
          <p className="text-sm text-muted">No open shifts right now.</p>
        ) : (
          <ul className="space-y-2">
            {openShifts.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span className="text-ink">
                  {fmtDate(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                  {s.positions?.title ? ` · ${s.positions.title}` : ''}
                </span>
                <button
                  onClick={() => handlePickUpShift(s.id)}
                  disabled={busyId === s.id}
                  className="rounded-full bg-brand-blue px-3 py-1 text-xs font-medium text-white disabled:opacity-60"
                >
                  {busyId === s.id ? 'Picking up…' : 'Pick up'}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-1 text-sm font-semibold text-ink">Open swap board</h2>
        <p className="mb-3 text-xs text-muted">Shifts colleagues at your branch want covered.</p>
        {claimableSwapBoard.length === 0 ? (
          <p className="text-sm text-muted">No open swap requests right now.</p>
        ) : (
          <ul className="space-y-2">
            {claimableSwapBoard.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span className="text-ink">
                  {s.shifts && `${fmtDate(s.shifts.shift_date)} · ${fmtTime(s.shifts.start_time)}–${fmtTime(s.shifts.end_time)}`}
                  {s.notes ? ` · “${s.notes}”` : ''}
                </span>
                <button
                  onClick={() => handleClaimSwap(s.id)}
                  disabled={busyId === s.id}
                  className="rounded-full bg-brand-blue px-3 py-1 text-xs font-medium text-white disabled:opacity-60"
                >
                  {busyId === s.id ? 'Claiming…' : 'Claim'}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      {myOwnSwapHistory.length > 0 && (
        <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Your swap requests</h2>
          <ul className="space-y-2">
            {myOwnSwapHistory.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  {s.shifts && `${fmtDate(s.shifts.shift_date)} · ${fmtTime(s.shifts.start_time)}–${fmtTime(s.shifts.end_time)}`}
                </span>
                <span className="flex items-center gap-2">
                  <StatusBadge status={s.status} tone={SWAP_STATUS_TONE[s.status]} />
                  {(s.status === 'open' || s.status === 'claimed') && (
                    <button onClick={() => handleCancelSwap(s.id)} className="text-muted hover:text-brand-risk">
                      Cancel
                    </button>
                  )}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
