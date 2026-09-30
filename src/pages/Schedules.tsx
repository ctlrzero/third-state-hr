import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { fmtDateTime, fmtDayShort, fmtTime } from '../lib/format'
import { Link, useSearchParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import type { ShiftAdjustment, ShiftChangeType,
  Employee,
  Location,
  Position,
  ScheduleTemplate,
  Shift,
  ShiftSwapRequest,
} from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'
import { confirmDialog } from '../lib/confirm'
import {
  AutoSchedulePanel,
  DeletedShiftsSheet,
  DeleteShiftsModal,
  WorkPatternWarnings,
  FindCoverSheet,
  CrossBranchClaimsToggle,
  ShiftSwapsToggle,
  BranchSetupSheet,
  type DeletableShift,
  type CoverShift,
  type SetupBranch,
} from './schedules/SchedulingTools'
import { ShiftActionsSheet, StatusLegend, WeekBoard, type BoardPerson } from './schedules/WeekBoard'
import { isoAddDays, mondayOf, shiftKind, thisMonday, weekLabel } from './schedules/week'
import { useWorkPatternWarnings } from './schedules/useWorkPatternWarnings'

const DOW_LABELS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

// Strip any "ERROR: " prefix Postgres sometimes prepends; display the
// human-readable part the trigger raised.
function friendlyError(err: { message: string; code?: string }): string {
  return err.message.replace(/^ERROR:\s*/i, '')
}

const CHANGE_TYPE_LABEL: Record<ShiftChangeType, string> = {
  cancelled: 'Cancelled',
  unpublished: 'Unpublished',
  reassigned: 'Reassigned',
  date_changed: 'Date changed',
  location_changed: 'Branch changed',
  time_changed: 'Time changed',
  break_changed: 'Break changed',
  deleted: 'Deleted',
}

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}
function addDaysIso(iso: string, days: number) {
  // UTC on both sides: local midnight read back via toISOString drifts a day in UTC+ zones (Dubai).
  const d = new Date(iso + 'T00:00:00Z')
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
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

type AdminTab = 'week' | 'auto' | 'setup'
type AdminEmployee = Pick<Employee, 'id' | 'full_name' | 'home_location_id' | 'employment_status'>

function ScheduleAdmin() {
  const { activeEntityId, profile } = useAuth()
  const isAdmin = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const [shifts, setShifts] = useState<Shift[]>([])
  const [swaps, setSwaps] = useState<ShiftSwapRequest[]>([])
  const [locations, setLocations] = useState<Pick<Location, 'id' | 'name'>[]>([])
  const [positions, setPositions] = useState<Pick<Position, 'id' | 'title'>[]>([])
  const [employees, setEmployees] = useState<AdminEmployee[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [locationFilter, setLocationFilter] = useState<string>('all')
  const [templates, setTemplates] = useState<ScheduleTemplate[]>([])
  const [templateModalOpen, setTemplateModalOpen] = useState(false)
  const [adjustShift, setAdjustShift] = useState<Shift | null>(null)
  const [cancelPublishedShift, setCancelPublishedShift] = useState<Shift | null>(null)
  const [historyShift, setHistoryShift] = useState<Shift | null>(null)
  const [actionShift, setActionShift] = useState<Shift | null>(null)
  const [toDelete, setToDelete] = useState<Shift[] | null>(null)
  const [showDeleted, setShowDeleted] = useState(false)
  const [onLeave, setOnLeave] = useState<Set<string>>(new Set())
  const [adjustedIds, setAdjustedIds] = useState<Set<string>>(new Set())
  const [coverShift, setCoverShift] = useState<CoverShift | null>(null)
  const [swapsEnabled, setSwapsEnabled] = useState(true)
  const [weekStart, setWeekStart] = useState(thisMonday())
  const [publishing, setPublishing] = useState(false)
  const [branchSetup, setBranchSetup] = useState<SetupBranch[] | null>(null)
  const [branchSetupOpen, setBranchSetupOpen] = useState(false)
  const [params, setParams] = useSearchParams()
  const focusShiftId = params.get('shift')
  const rawTab = params.get('tab') ?? (params.get('mode') === 'auto' ? 'auto' : 'week')
  const tab: AdminTab = rawTab === 'setup' ? 'setup' : rawTab === 'auto' && isAdmin ? 'auto' : 'week'
  const setTab = (t: AdminTab) => {
    const next = new URLSearchParams(params)
    next.delete('mode')
    if (t === 'week') next.delete('tab')
    else next.set('tab', t)
    setParams(next, { replace: true })
  }
  const weekEnd = isoAddDays(weekStart, 6)

  const employeesById = useMemo(() => new Map(employees.map((e) => [e.id, e])), [employees])
  const locationNames = useMemo(() => new Map(locations.map((l) => [l.id, l.name])), [locations])

  async function load() {
    if (!activeEntityId) return
    setLoading(true)
    setError(null)
    const [shiftsRes, swapsRes, locRes, posRes, empRes, templatesRes, leaveRes] = await Promise.all([
      supabase
        .from('shifts')
        .select('*, locations(id, name), positions(id, title)')
        .eq('entity_id', activeEntityId)
        .gte('shift_date', weekStart)
        .lte('shift_date', weekEnd)
        .order('shift_date', { ascending: true })
        .order('start_time', { ascending: true }),
      supabase
        .from('shift_swap_requests')
        .select('*, shifts!inner(id, shift_date, start_time, end_time, location_id, entity_id, locations(id, name))')
        .eq('shifts.entity_id', activeEntityId)
        .order('created_at', { ascending: false }),
      supabase.from('locations').select('id, name').eq('entity_id', activeEntityId).order('name'),
      supabase.from('positions').select('id, title').eq('entity_id', activeEntityId).order('title'),
      supabase.from('employees').select('id, full_name, home_location_id, employment_status').eq('entity_id', activeEntityId).order('full_name'),
      supabase
        .from('schedule_templates')
        .select('*, employees(id, full_name), positions(id, title)')
        .eq('entity_id', activeEntityId)
        .eq('is_active', true)
        .order('day_of_week', { ascending: true }),
      supabase
        .from('leave_requests')
        .select('employee_id, start_date, end_date')
        .eq('status', 'approved')
        .lte('start_date', weekEnd)
        .gte('end_date', weekStart),
    ])
    const leaveDays = new Set<string>()
    for (const lr of (leaveRes.data ?? []) as { employee_id: string; start_date: string; end_date: string }[]) {
      for (let d = lr.start_date; d <= lr.end_date; d = addDaysIso(d, 1)) leaveDays.add(`${lr.employee_id}|${d}`)
    }
    setOnLeave(leaveDays)
    const weekShifts = (shiftsRes.data ?? []) as unknown as Shift[]
    if (shiftsRes.error) setError(shiftsRes.error.message)
    else setShifts(weekShifts)
    const publishedIds = weekShifts.filter((s) => s.is_published).map((s) => s.id)
    if (publishedIds.length) {
      const { data: adj } = await supabase.from('shift_adjustments').select('shift_id').in('shift_id', publishedIds)
      setAdjustedIds(new Set((adj ?? []).map((a: { shift_id: string }) => a.shift_id)))
    } else setAdjustedIds(new Set())
    setSwaps((swapsRes.data ?? []) as unknown as ShiftSwapRequest[])
    setLocations(locRes.data ?? [])
    setPositions(posRes.data ?? [])
    setEmployees((empRes.data ?? []) as AdminEmployee[])
    setTemplates((templatesRes.data ?? []) as unknown as ScheduleTemplate[])
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeEntityId, weekStart])

  // Arriving from a leave approval's "Reassign" link: jump to that shift's week and open it.
  const [focusHandled, setFocusHandled] = useState<string | null>(null)
  const [focusWeekSet, setFocusWeekSet] = useState<string | null>(null)
  useEffect(() => {
    if (!focusShiftId || focusWeekSet === focusShiftId) return
    setFocusWeekSet(focusShiftId)
    supabase
      .from('shifts')
      .select('shift_date')
      .eq('id', focusShiftId)
      .maybeSingle()
      .then(({ data }) => {
        if (!data) return setError('That shift is no longer in the schedule.')
        setTab('week')
        setLocationFilter('all')
        setWeekStart(mondayOf((data as { shift_date: string }).shift_date))
      })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusShiftId, focusWeekSet])
  useEffect(() => {
    if (!focusShiftId || loading || focusHandled === focusShiftId) return
    const s = shifts.find((x) => x.id === focusShiftId)
    if (!s) return
    setFocusHandled(focusShiftId)
    setActionShift(s)
    window.setTimeout(() => document.getElementById(`shift-${s.id}`)?.scrollIntoView({ block: 'center', behavior: 'smooth' }), 50)
  }, [focusShiftId, loading, shifts, focusHandled])

  const visibleShifts = useMemo(
    () => (locationFilter === 'all' ? shifts : shifts.filter((s) => s.location_id === locationFilter)),
    [shifts, locationFilter]
  )
  const visibleTemplates = useMemo(
    () => (locationFilter === 'all' ? templates : templates.filter((t) => t.location_id === locationFilter)),
    [templates, locationFilter]
  )
  const liveCount = visibleShifts.filter((s) => s.status !== 'cancelled').length
  const draftCount = visibleShifts.filter((s) => s.status !== 'cancelled' && !s.is_published).length
  const cancelledInView = visibleShifts.filter((s) => s.status === 'cancelled')
  const leaveClashCount = visibleShifts.filter(
    (s) => !!s.employee_id && s.status !== 'cancelled' && onLeave.has(`${s.employee_id}|${s.shift_date}`)
  ).length

  const people: BoardPerson[] = useMemo(() => {
    const withShift = new Set(visibleShifts.map((s) => s.employee_id).filter((x): x is string => !!x))
    return employees
      .filter((e) =>
        withShift.has(e.id) ||
        (locationFilter !== 'all' && e.home_location_id === locationFilter && e.employment_status === 'active')
      )
      .map((e) => ({ id: e.id, name: e.full_name, homeLocationId: e.home_location_id }))
  }, [employees, visibleShifts, locationFilter])

  async function handleCancelDraftShift(shift: Shift) {
    if (!(await confirmDialog('Cancel this draft shift?'))) return
    const { error: updateError } = await supabase.from('shifts').update({ status: 'cancelled' }).eq('id', shift.id)
    if (updateError) {
      setError(friendlyError(updateError))
      return
    }
    load()
  }

  function handleCancelShiftClick(shift: Shift) {
    if (shift.is_published) setCancelPublishedShift(shift)
    else handleCancelDraftShift(shift)
  }

  async function handleDeactivateTemplate(id: string) {
    if (!(await confirmDialog('Deactivate this recurring template? Existing generated shifts are unaffected.'))) return
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
      setError(friendlyError(rpcError))
      return
    }
    setNotice(action === 'approve' ? 'Swap approved — the shift has been reassigned.' : 'Swap rejected.')
    load()
  }

  async function publishWeek() {
    if (locationFilter === 'all') return
    const branch = locationNames.get(locationFilter) ?? 'this branch'
    if (!(await confirmDialog(`Publish ${draftCount} draft shift${draftCount === 1 ? '' : 's'} at ${branch} for ${weekLabel(weekStart)}? Staff will see them.`))) return
    setPublishing(true)
    const { data, error: rpcError } = await supabase.rpc('publish_schedule_period', {
      p_location_id: locationFilter,
      p_period_start: weekStart,
      p_period_end: weekEnd,
    })
    setPublishing(false)
    if (rpcError) return setError(friendlyError(rpcError))
    const res = data as { published: number; skipped_leave: { shift_date: string; employee: string }[] } | null
    const published = res?.published ?? 0
    const skipped = res?.skipped_leave ?? []
    setNotice(
      `Published ${published} shift${published === 1 ? '' : 's'} — now visible to staff.` +
        (skipped.length
          ? ` ${skipped.length} left as draft because the person is on approved leave: ${skipped
              .map((x) => `${x.employee} (${fmtDate(x.shift_date)})`)
              .join(', ')}.`
          : '')
    )
    load()
  }

  async function openBranchSetup() {
    if (!activeEntityId) return
    const { data, error: rpcError } = await supabase.rpc('get_scheduling_setup', { p_entity_id: activeEntityId })
    if (rpcError) return setError(friendlyError(rpcError))
    setBranchSetup((data ?? []) as SetupBranch[])
    setBranchSetupOpen(true)
  }

  function asDeletable(s: Shift): DeletableShift {
    const who = s.employees?.full_name ?? employeesById.get(s.employee_id ?? '')?.full_name ?? 'Open shift'
    return { id: s.id, shift_date: s.shift_date, start_time: s.start_time, end_time: s.end_time, label: `${who} · ${s.locations?.name ?? 'Branch'}` }
  }

  function asCover(s: Shift): CoverShift {
    return {
      id: s.id,
      shift_date: s.shift_date,
      start_time: s.start_time,
      end_time: s.end_time,
      break_minutes: s.break_minutes,
      location_id: s.location_id,
      employee_id: s.employee_id,
      is_published: s.is_published,
      currentName: s.employee_id ? (employeesById.get(s.employee_id)?.full_name ?? null) : null,
    }
  }

  const pendingSwaps = swaps.filter((s) => s.status === 'claimed')
  const otherSwaps = swaps.filter((s) => s.status !== 'claimed').slice(0, 30)
  const tabs: { id: AdminTab; label: string }[] = [
    { id: 'week', label: 'Week' },
    ...(isAdmin ? [{ id: 'auto' as AdminTab, label: 'Auto-schedule' }] : []),
    { id: 'setup', label: 'Setup' },
  ]
  const actionKind = actionShift ? shiftKind(actionShift, adjustedIds) : null
  const actionOnLeave =
    !!actionShift?.employee_id && actionShift.status !== 'cancelled' && onLeave.has(`${actionShift.employee_id}|${actionShift.shift_date}`)
  const then = (fn: () => void) => () => {
    setActionShift(null)
    fn()
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Schedules</h1>
          <p className="text-xs text-muted">
            {loading
              ? 'Loading…'
              : `${weekLabel(weekStart)} · ${liveCount} shift${liveCount === 1 ? '' : 's'}${draftCount ? ` · ${draftCount} draft` : ''}`}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Link to="/attendance" className="btn-ghost press">
            Attendance
          </Link>
          {tab === 'week' && (
            <button
              onClick={() => setCreateOpen(true)}
              className="press rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark"
            >
              New shift
            </button>
          )}
        </div>
      </div>

      <div className="flex flex-wrap items-end justify-between gap-3">
        <SegmentedTabs options={tabs} value={tab} onChange={setTab} />
        {tab !== 'auto' && (
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
        )}
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
                  <button onClick={() => handleResolveSwap(s.id, 'approve')} className="press rounded-full bg-brand-action-soft px-2 py-1 font-medium text-brand-action-text">
                    Approve
                  </button>
                  <button onClick={() => handleResolveSwap(s.id, 'reject')} className="press rounded-full bg-brand-risk-soft px-2 py-1 font-medium text-brand-risk-text">
                    Reject
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {tab === 'week' && (
        <div key="week" className="rise space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-1">
              <button aria-label="Previous week" onClick={() => setWeekStart(isoAddDays(weekStart, -7))} className="press btn-secondary px-3">
                ‹
              </button>
              <button onClick={() => setWeekStart(thisMonday())} disabled={weekStart === thisMonday()} className="press btn-secondary">
                This week
              </button>
              <button aria-label="Next week" onClick={() => setWeekStart(isoAddDays(weekStart, 7))} className="press btn-secondary px-3">
                ›
              </button>
              <span className="ml-2 text-sm font-medium text-ink">{weekLabel(weekStart)}</span>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              {isAdmin && cancelledInView.length > 0 && (
                <button onClick={() => setToDelete(cancelledInView)} className="press rounded-full bg-brand-risk-soft px-3 py-1.5 text-xs font-medium text-brand-risk-text">
                  Delete {cancelledInView.length} cancelled
                </button>
              )}
              {draftCount > 0 &&
                (locationFilter === 'all' ? (
                  <span className="text-xs text-muted">Choose a branch to publish its {draftCount} draft{draftCount === 1 ? '' : 's'}</span>
                ) : (
                  <button onClick={publishWeek} disabled={publishing} className="btn-primary press">
                    {publishing ? 'Publishing…' : `Publish week (${draftCount} draft${draftCount === 1 ? '' : 's'})`}
                  </button>
                ))}
            </div>
          </div>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <StatusLegend />
            {leaveClashCount > 0 && (
              <p role="status" className="text-xs font-medium text-brand-risk-text">
                {leaveClashCount} shift{leaveClashCount === 1 ? '' : 's'} held by someone on approved leave — reassign or cancel.
              </p>
            )}
          </div>

          {loading ? (
            <div className="h-64 animate-pulse rounded-[14px] bg-surface" />
          ) : visibleShifts.length === 0 && people.length === 0 ? (
            <EmptyState title="No shifts this week" description="Create a shift, generate from templates in Setup, or use Auto-schedule." />
          ) : (
            <WeekBoard
              weekStart={weekStart}
              shifts={visibleShifts}
              people={people}
              adjustedIds={adjustedIds}
              onLeave={onLeave}
              locationNames={locationNames}
              showBranch={locationFilter === 'all'}
              focusId={focusShiftId}
              onOpen={setActionShift}
            />
          )}

          {otherSwaps.length > 0 && (
            <details className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
              <summary className="cursor-pointer text-sm font-semibold text-ink">Swap history</summary>
              <ul className="mt-3 space-y-1.5">
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
            </details>
          )}
        </div>
      )}

      {tab === 'auto' && activeEntityId && (
        <div key="auto" className="rise">
          <AutoSchedulePanel
            entityId={activeEntityId}
            positions={positions}
            onNotice={setNotice}
            onApplied={(created, periodStart, locationIds) => {
              // Land on the week that was just planned so it can be reviewed and published.
              setWeekStart(mondayOf(periodStart))
              if (locationIds && locationIds.length === 1) setLocationFilter(locationIds[0])
              setTab('week')
              setNotice(
                `Created ${created} draft shift${created === 1 ? '' : 's'} for ${weekLabel(mondayOf(periodStart))}. Review them below, then use Publish week${
                  locationIds && locationIds.length === 1 ? '' : ' for each branch'
                } when you're ready for staff to see them.`
              )
            }}
          />
        </div>
      )}

      {tab === 'setup' && (
        <div key="setup" className="rise space-y-5">
          <RecurringTemplatesPanel
            templates={visibleTemplates}
            locations={locations}
            onNewTemplate={() => setTemplateModalOpen(true)}
            onDeactivate={handleDeactivateTemplate}
            onGenerated={() => {
              setNotice('Draft shifts generated from your recurring templates. Review them in the week view, then publish.')
              load()
            }}
            onPublished={(msg) => {
              setNotice(msg)
              load()
            }}
            onError={setError}
          />
          {isAdmin && activeEntityId && (
            <>
              <section className="card flex flex-wrap items-center justify-between gap-3">
                <span>
                  <span className="block text-sm font-semibold text-ink">Opening hours and staffing needs</span>
                  <span className="block text-sm text-muted">Used by Auto-schedule. Set them per branch.</span>
                </span>
                <button className="btn-secondary press" onClick={openBranchSetup}>
                  Branch setup
                </button>
              </section>
              <section className="card space-y-3">
                <h2 className="text-sm font-semibold text-ink">Staff self-service</h2>
                <div className="flex flex-col gap-2">
                  <ShiftSwapsToggle entityId={activeEntityId} onChanged={setSwapsEnabled} onError={setError} />
                  {profile?.role === 'owner' && <CrossBranchClaimsToggle entityId={activeEntityId} onError={setError} />}
                  {!swapsEnabled && <p className="text-xs text-brand-warning-solid">Swaps are off — staff can't request or claim them.</p>}
                </div>
              </section>
              <section className="card flex flex-wrap items-center justify-between gap-3">
                <span>
                  <span className="block text-sm font-semibold text-ink">Deleted shifts</span>
                  <span className="block text-sm text-muted">Every deleted shift, who deleted it and why.</span>
                </span>
                <button className="btn-secondary press" onClick={() => setShowDeleted(true)}>
                  Open log
                </button>
              </section>
            </>
          )}
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

      {actionShift && actionKind && (
        <ShiftActionsSheet
          shift={actionShift}
          kind={actionKind}
          personName={
            actionShift.employee_id ? (employeesById.get(actionShift.employee_id)?.full_name ?? 'Unknown employee') : 'Open shift'
          }
          branchName={locationNames.get(actionShift.location_id) ?? 'Branch'}
          onLeave={actionOnLeave}
          onClose={() => setActionShift(null)}
          actions={{
            onEdit: actionKind !== 'cancelled' ? then(() => setAdjustShift(actionShift)) : undefined,
            onCover:
              actionKind !== 'cancelled' && actionShift.shift_date >= todayIso() ? then(() => setCoverShift(asCover(actionShift))) : undefined,
            onHistory: actionShift.is_published ? then(() => setHistoryShift(actionShift)) : undefined,
            onCancel: actionKind !== 'cancelled' ? then(() => handleCancelShiftClick(actionShift)) : undefined,
            onDelete: isAdmin && actionKind === 'cancelled' ? then(() => setToDelete([actionShift])) : undefined,
          }}
        />
      )}

      {cancelPublishedShift && (
        <CancelShiftModal
          shift={cancelPublishedShift}
          onClose={() => setCancelPublishedShift(null)}
          onCancelled={() => {
            setCancelPublishedShift(null)
            setNotice('Shift cancelled and change recorded.')
            load()
          }}
        />
      )}

      {adjustShift && (
        <AdjustShiftModal
          shift={adjustShift}
          locations={locations}
          employees={employees}
          onClose={() => setAdjustShift(null)}
          onAdjusted={() => {
            setAdjustShift(null)
            setNotice(adjustShift.is_published ? 'Shift updated and change recorded.' : 'Draft shift updated.')
            load()
          }}
        />
      )}

      {historyShift && (
        <ShiftHistoryDrawer shift={historyShift} employees={employees} locations={locations} onClose={() => setHistoryShift(null)} />
      )}

      {toDelete && (
        <DeleteShiftsModal
          shifts={toDelete.map(asDeletable)}
          onClose={() => setToDelete(null)}
          onDone={(res) => {
            setToDelete(null)
            const skipped = res.skipped.length
              ? ` ${res.skipped.length} skipped: ${res.skipped.map((x) => `${fmtDate(x.shift_date)} (${x.reason})`).join(', ')}.`
              : ''
            setNotice(`Deleted ${res.deleted} shift${res.deleted === 1 ? '' : 's'} — kept in the deleted shifts log.${skipped}`)
            load()
          }}
        />
      )}

      {coverShift && (
        <FindCoverSheet
          shift={coverShift}
          onClose={() => setCoverShift(null)}
          onAssigned={(msg) => {
            setCoverShift(null)
            setNotice(msg)
            load()
          }}
        />
      )}

      {branchSetupOpen && branchSetup && (
        <BranchSetupSheet
          setup={branchSetup}
          initialLocationId={locationFilter !== 'all' ? locationFilter : undefined}
          positions={positions}
          onClose={() => setBranchSetupOpen(false)}
          onSaved={(msg) => {
            setNotice(msg)
            if (activeEntityId)
              supabase.rpc('get_scheduling_setup', { p_entity_id: activeEntityId }).then(({ data }) => setBranchSetup((data ?? []) as SetupBranch[]))
          }}
        />
      )}

      {showDeleted && activeEntityId && (
        <DeletedShiftsSheet entityId={activeEntityId} locations={locations} employees={employees} onClose={() => setShowDeleted(false)} />
      )}
    </div>
  )
}

function SegmentedTabs<T extends string>({ options, value, onChange }: { options: { id: T; label: string }[]; value: T; onChange: (v: T) => void }) {
  const index = Math.max(0, options.findIndex((o) => o.id === value))
  return (
    <div
      className="segmented"
      role="tablist"
      aria-label="Schedule views"
      onKeyDown={(e) => {
        if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return
        e.preventDefault()
        const next = options[(index + (e.key === 'ArrowRight' ? 1 : options.length - 1)) % options.length]
        onChange(next.id)
        ;(e.currentTarget.querySelector(`[data-tab="${next.id}"]`) as HTMLElement | null)?.focus()
      }}
    >
      <span
        className="segmented__thumb"
        aria-hidden="true"
        style={{ width: `calc(${100 / options.length}% - ${6 / options.length}px)`, transform: `translateX(${index * 100}%)` }}
      />
      {options.map((o) => (
        <button
          key={o.id}
          data-tab={o.id}
          role="tab"
          aria-selected={value === o.id}
          aria-checked={value === o.id}
          tabIndex={value === o.id ? 0 : -1}
          onClick={() => onChange(o.id)}
          className="segmented__option"
        >
          {o.label}
        </button>
      ))}
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
  onPublished: (message: string) => void
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
    if (!(await confirmDialog('Publish all draft shifts in this branch and period? They will become visible to employees.'))) return
    setBusy('publish')
    const { data, error } = await supabase.rpc('publish_schedule_period', {
      p_location_id: genLocationId,
      p_period_start: periodStart,
      p_period_end: periodEnd,
    })
    setBusy(null)
    if (error) {
      onError(error.message)
      return
    }
    const res = data as { published: number; skipped_leave: { shift_date: string; employee: string }[] } | null
    const published = res?.published ?? 0
    const skipped = res?.skipped_leave ?? []
    onPublished(
      `Published ${published} shift${published === 1 ? '' : 's'} — now visible to employees.` +
        (skipped.length
          ? ` ${skipped.length} left as draft because the person is on approved leave: ${skipped
              .map((x) => `${x.employee} (${fmtDate(x.shift_date)})`)
              .join(', ')}. Reassign or cancel them.`
          : '')
    )
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
                {fmtDate(t.effective_start_date)}
                {t.effective_end_date ? ` to ${fmtDate(t.effective_end_date)}` : ' (ongoing)'}
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
  const [breakMinutes, setBreakMinutes] = useState(0)
  const [notes, setNotes] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const patternWarnings = useWorkPatternWarnings(employeeId, shiftDate)

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
      break_minutes: breakMinutes,
      status: employeeId ? 'assigned' : 'open',
      notes: notes || null,
      created_by: user?.id ?? null,
    })
    setSubmitting(false)
    if (insertError) {
      setError(friendlyError(insertError))
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
          <div className="grid grid-cols-4 gap-2">
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
            <div>
              <label htmlFor="schedules-break-new-shift" className="mb-1 block text-sm font-medium text-ink">Break (min)</label>
              <input id="schedules-break-new-shift"
                type="number"
                min={0}
                value={breakMinutes}
                onChange={(e) => setBreakMinutes(Number(e.target.value))}
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

          <WorkPatternWarnings warnings={patternWarnings} />
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
  const { profile } = useAuth()
  const [swapsOn, setSwapsOn] = useState(true)
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
    if (profile?.entity_id) {
      const { data: on } = await supabase.rpc('shift_swaps_enabled', { p_entity_id: profile.entity_id })
      setSwapsOn(on !== false)
    }
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profile?.entity_id])

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
                    {!swapsOn ? null : existingSwap ? (
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
                  {swapsOn && swapNoteFor === s.id && (
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
        <h2 className="mb-1 text-sm font-semibold text-ink">Open shifts</h2>
        <p className="mb-3 text-xs text-muted">Unfilled shifts you can pick up.</p>
        {openShifts.length === 0 ? (
          <p className="text-sm text-muted">No open shifts right now.</p>
        ) : (
          <ul className="space-y-2">
            {openShifts.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span className="text-ink">
                  {fmtDate(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                  {s.locations?.name ? ` · ${s.locations.name}` : ''}
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

      {swapsOn && (
      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-1 text-sm font-semibold text-ink">Open swap board</h2>
        <p className="mb-3 text-xs text-muted">Shifts colleagues want covered. If you can't take one, the app tells you why.</p>
        {claimableSwapBoard.length === 0 ? (
          <p className="text-sm text-muted">No open swap requests right now.</p>
        ) : (
          <ul className="space-y-2">
            {claimableSwapBoard.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span className="text-ink">
                  {s.shifts && `${fmtDate(s.shifts.shift_date)} · ${fmtTime(s.shifts.start_time)}–${fmtTime(s.shifts.end_time)}`}
                  {s.shifts?.locations?.name ? ` · ${s.shifts.locations.name}` : ''}
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
      )}

      {swapsOn && myOwnSwapHistory.length > 0 && (
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

// ---------------------------------------------------------------------------
// Cancel a published shift (reason required → cancel_published_shift RPC)
// ---------------------------------------------------------------------------

function CancelShiftModal({
  shift,
  onClose,
  onCancelled,
}: {
  shift: Shift
  onClose: () => void
  onCancelled: () => void
}) {
  const [reason, setReason] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!reason.trim()) { setError('A reason is required.'); return }
    setSubmitting(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('cancel_published_shift', {
      p_shift_id: shift.id,
      p_reason: reason.trim(),
    })
    setSubmitting(false)
    if (rpcError) { setError(friendlyError(rpcError)); return }
    onCancelled()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card" onClick={(e) => e.stopPropagation()}>
        <h2 className="mb-1 text-base font-semibold text-ink">Cancel published shift</h2>
        <p className="mb-4 text-xs text-muted">
          {fmtDate(shift.shift_date)} · {fmtTime(shift.start_time)}–{fmtTime(shift.end_time)}
          {shift.employees?.full_name ? ` · ${shift.employees.full_name}` : ''}
        </p>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="cancel-shift-reason" className="mb-1 block text-sm font-medium text-ink">Reason *</label>
            <textarea
              id="cancel-shift-reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              placeholder="e.g. Employee called in sick, shift no longer needed"
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
          <div className="flex justify-end gap-2 pt-2">
            <button type="button" onClick={onClose} className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt">
              Back
            </button>
            <button
              type="submit"
              disabled={submitting || !reason.trim()}
              className="rounded-lg bg-brand-risk px-4 py-2 text-sm font-medium text-white hover:bg-brand-risk/90 disabled:opacity-60"
            >
              {submitting ? 'Cancelling…' : 'Cancel shift'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Adjust a published shift (reason required → adjust_published_shift RPC)
// ---------------------------------------------------------------------------

function AdjustShiftModal({
  shift,
  locations,
  employees,
  onClose,
  onAdjusted,
}: {
  shift: Shift
  locations: Pick<Location, 'id' | 'name'>[]
  employees: Pick<Employee, 'id' | 'full_name' | 'home_location_id'>[]
  onClose: () => void
  onAdjusted: () => void
}) {
  const [shiftDate, setShiftDate] = useState(shift.shift_date)
  const [startTime, setStartTime] = useState(shift.start_time.slice(0, 5))
  const [endTime, setEndTime] = useState(shift.end_time.slice(0, 5))
  const [breakMinutes, setBreakMinutes] = useState(shift.break_minutes)
  const [employeeId, setEmployeeId] = useState(shift.employee_id ?? '')
  const [locationId, setLocationId] = useState(shift.location_id)
  const [reason, setReason] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const patternWarnings = useWorkPatternWarnings(employeeId, shiftDate, shift.id)

  const isDraft = !shift.is_published

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!isDraft && !reason.trim()) { setError('A reason is required.'); return }
    setSubmitting(true)
    setError(null)
    // Drafts aren't visible to staff yet, so they are edited directly; published
    // shifts need a reason and keep their history (the database enforces this).
    const { error: rpcError } = isDraft
      ? await supabase
          .from('shifts')
          .update({
            shift_date: shiftDate,
            start_time: startTime,
            end_time: endTime,
            break_minutes: breakMinutes,
            employee_id: employeeId || null,
            location_id: locationId,
          })
          .eq('id', shift.id)
      : await supabase.rpc('adjust_published_shift', {
          p_shift_id: shift.id,
          p_reason: reason.trim(),
          p_shift_date: shiftDate,
          p_start_time: startTime,
          p_end_time: endTime,
          p_break_minutes: breakMinutes,
          p_employee_id: employeeId || null,
          p_location_id: locationId,
        })
    setSubmitting(false)
    if (rpcError) { setError(friendlyError(rpcError)); return }
    onAdjusted()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card" onClick={(e) => e.stopPropagation()}>
        <h2 className="mb-4 text-base font-semibold text-ink">{isDraft ? 'Edit draft shift' : 'Adjust published shift'}</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="adjust-branch" className="mb-1 block text-sm font-medium text-ink">Branch</label>
            <select id="adjust-branch" value={locationId} onChange={(e) => setLocationId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20">
              {locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
          </div>
          <div>
            <label htmlFor="adjust-employee" className="mb-1 block text-sm font-medium text-ink">Assigned to</label>
            <select id="adjust-employee" value={employeeId} onChange={(e) => setEmployeeId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20">
              <option value="">Open shift (unassigned)</option>
              {employees.map((emp) => <option key={emp.id} value={emp.id}>{emp.full_name}</option>)}
            </select>
          </div>
          <div className="grid grid-cols-4 gap-2">
            <div className="col-span-1">
              <label htmlFor="adjust-date" className="mb-1 block text-sm font-medium text-ink">Date</label>
              <input id="adjust-date" type="date" value={shiftDate} onChange={(e) => setShiftDate(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20" />
            </div>
            <div>
              <label htmlFor="adjust-start" className="mb-1 block text-sm font-medium text-ink">Start</label>
              <input id="adjust-start" type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20" />
            </div>
            <div>
              <label htmlFor="adjust-end" className="mb-1 block text-sm font-medium text-ink">End</label>
              <input id="adjust-end" type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20" />
            </div>
            <div>
              <label htmlFor="adjust-break" className="mb-1 block text-sm font-medium text-ink">Break (min)</label>
              <input id="adjust-break" type="number" min={0} value={breakMinutes} onChange={(e) => setBreakMinutes(Number(e.target.value))}
                className="w-full rounded-lg border border-border px-2 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20" />
            </div>
          </div>
          {!isDraft && (
            <div>
              <label htmlFor="adjust-reason" className="mb-1 block text-sm font-medium text-ink">Reason for change *</label>
              <textarea id="adjust-reason" value={reason} onChange={(e) => setReason(e.target.value)} rows={2}
                placeholder="e.g. Employee requested time change, branch operational need"
                className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20" />
            </div>
          )}
          <WorkPatternWarnings warnings={patternWarnings} />
          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
          <div className="flex justify-end gap-2 pt-2">
            <button type="button" onClick={onClose} className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt">
              Cancel
            </button>
            <button type="submit" disabled={submitting || (!isDraft && !reason.trim())}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60">
              {submitting ? 'Saving…' : 'Save changes'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Shift change history drawer (reads shift_adjustments)
// ---------------------------------------------------------------------------

function ShiftHistoryDrawer({
  shift,
  onClose,
  employees = [],
  locations = [],
}: {
  shift: Shift
  onClose: () => void
  employees?: Pick<Employee, 'id' | 'full_name'>[]
  locations?: Pick<Location, 'id' | 'name'>[]
}) {
  const [history, setHistory] = useState<ShiftAdjustment[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    const { data, error: qErr } = await supabase
      .from('shift_adjustments')
      .select('*')
      .eq('shift_id', shift.id)
      .order('changed_at', { ascending: false })
    setLoading(false)
    if (qErr) { setError(qErr.message); return }
    setHistory((data ?? []) as ShiftAdjustment[])
  }, [shift.id])

  useEffect(() => { load() }, [load])

  const empName = (id: unknown) => (typeof id === 'string' ? employees.find((e) => e.id === id)?.full_name ?? 'someone else' : 'open shift')
  const locName = (id: unknown) => (typeof id === 'string' ? locations.find((l) => l.id === id)?.name ?? 'another branch' : '—')
  function describeWas(v: Record<string, unknown>) {
    const parts: string[] = []
    if (typeof v.shift_date === 'string') parts.push(fmtDate(v.shift_date))
    if (typeof v.start_time === 'string' && typeof v.end_time === 'string') parts.push(`${fmtTime(v.start_time)}–${fmtTime(v.end_time)}`)
    if (typeof v.break_minutes === 'number' && v.break_minutes > 0) parts.push(`${v.break_minutes}m break`)
    if ('employee_id' in v) parts.push(empName(v.employee_id))
    if ('location_id' in v) parts.push(locName(v.location_id))
    return parts.join(' · ')
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div className="w-full max-w-lg rounded-[14px] border border-border bg-surface p-6 shadow-card" onClick={(e) => e.stopPropagation()}>
        <div className="mb-4 flex items-start justify-between">
          <div>
            <h2 className="text-base font-semibold text-ink">Change history</h2>
            <p className="text-xs text-muted">
              {fmtDate(shift.shift_date)} · {fmtTime(shift.start_time)}–{fmtTime(shift.end_time)}
              {shift.employees?.full_name ? ` · ${shift.employees.full_name}` : ''}
            </p>
          </div>
          <button onClick={onClose} className="text-sm text-muted hover:text-ink">Close</button>
        </div>

        {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text mb-3">{error}</p>}

        {loading ? (
          <div className="space-y-2">
            {[0, 1, 2].map((i) => <div key={i} className="h-12 animate-pulse rounded-lg bg-surface-alt" />)}
          </div>
        ) : history.length === 0 ? (
          <p className="text-sm text-muted">No recorded changes for this shift.</p>
        ) : (
          <ul className="divide-y divide-border">
            {history.map((h) => (
              <li key={h.id} className="py-3 text-sm">
                <div className="flex items-start justify-between gap-2">
                  <span className="font-medium text-ink">{CHANGE_TYPE_LABEL[h.change_type]}</span>
                  <span className="shrink-0 text-xs text-muted">{fmtDateTime(h.changed_at)}</span>
                </div>
                {h.reason && <p className="mt-0.5 text-xs text-muted">Reason: {h.reason}</p>}
                {h.old_values && Object.keys(h.old_values).length > 0 && (
                  <p className="mt-0.5 text-xs text-muted">Was: {describeWas(h.old_values)}</p>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}
