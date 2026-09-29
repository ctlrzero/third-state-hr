import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { fmtDayShort, fmtTime } from '../../lib/format'
import type { Employee, Location, Position, ShiftAdjustment } from '../../types/db'

const DOW_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const DOW_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

const errText = (err: { message: string }) => err.message.replace(/^ERROR:\s*/i, '')
const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : '')

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}
function addDaysIso(iso: string, days: number) {
  const d = new Date(iso + 'T00:00:00')
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}
function daysBetween(a: string, b: string) {
  return Math.round((new Date(b + 'T00:00:00').getTime() - new Date(a + 'T00:00:00').getTime()) / 86400000)
}

type Loc = Pick<Location, 'id' | 'name'>
type Pos = Pick<Position, 'id' | 'title'>
type Emp = Pick<Employee, 'id' | 'full_name' | 'home_location_id'>

function Overlay({ children, onClose, wide }: { children: React.ReactNode; onClose: () => void; wide?: boolean }) {
  return (
    <div className="fixed inset-0 z-30 flex items-start justify-center overflow-y-auto bg-ink/40 px-4 py-8" onClick={onClose}>
      <div
        className={`w-full ${wide ? 'max-w-4xl' : 'max-w-lg'} rounded-[14px] border border-border bg-surface p-6 shadow-card`}
        onClick={(e) => e.stopPropagation()}
      >
        {children}
      </div>
    </div>
  )
}

function Header({ title, sub, onClose }: { title: string; sub?: string; onClose: () => void }) {
  return (
    <div className="mb-4 flex items-start justify-between gap-3">
      <div>
        <h2 className="text-base font-semibold text-ink">{title}</h2>
        {sub && <p className="text-xs text-muted">{sub}</p>}
      </div>
      <button onClick={onClose} className="text-sm text-muted hover:text-ink">
        Close
      </button>
    </div>
  )
}

function ErrorBox({ msg }: { msg: string | null }) {
  if (!msg) return null
  return <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{msg}</p>
}

// ---------------------------------------------------------------------------
// Delete cancelled shifts (single or bulk) → delete_cancelled_shifts
// ---------------------------------------------------------------------------

export interface DeletableShift {
  id: string
  shift_date: string
  start_time: string
  end_time: string
  label: string
}

interface DeleteResult {
  ok: boolean
  deleted: number
  skipped: { id: string; shift_date: string; reason: string }[]
}

export function DeleteShiftsModal({
  shifts,
  onClose,
  onDone,
}: {
  shifts: DeletableShift[]
  onClose: () => void
  onDone: (res: DeleteResult) => void
}) {
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit() {
    setBusy(true)
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('delete_cancelled_shifts', {
      p_shift_ids: shifts.map((s) => s.id),
      p_reason: reason.trim() || null,
    })
    setBusy(false)
    if (rpcError) return setError(errText(rpcError))
    onDone(data as DeleteResult)
  }

  return (
    <Overlay onClose={onClose}>
      <Header
        title={shifts.length === 1 ? 'Delete cancelled shift' : `Delete ${shifts.length} cancelled shifts`}
        sub="The shift is removed from the roster but kept in the change log with your reason."
        onClose={onClose}
      />
      <ul className="mb-3 max-h-48 space-y-1 overflow-y-auto text-xs">
        {shifts.map((s) => (
          <li key={s.id} className="rounded-lg bg-surface-alt px-3 py-1.5 text-ink">
            {fmtDayShort(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)} · {s.label}
          </li>
        ))}
      </ul>
      <label className="block">
        <span className="label">Reason (optional)</span>
        <textarea
          className="input"
          rows={2}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="e.g. Duplicate after template regeneration"
        />
      </label>
      <p className="mt-2 text-xs text-muted">Shifts with clock-in records or payable time are never deleted — they'll be listed as skipped.</p>
      <div className="mt-3">
        <ErrorBox msg={error} />
      </div>
      <div className="mt-4 flex justify-end gap-2">
        <button className="btn-secondary" onClick={onClose}>
          Back
        </button>
        <button
          onClick={submit}
          disabled={busy}
          className="rounded-lg bg-brand-risk px-4 py-2 text-sm font-medium text-white hover:bg-brand-risk/90 disabled:opacity-60"
        >
          {busy ? 'Deleting…' : 'Delete'}
        </button>
      </div>
    </Overlay>
  )
}

// ---------------------------------------------------------------------------
// Deleted-shift history → shift_adjustments where change_type = 'deleted'
// ---------------------------------------------------------------------------

export function DeletedShiftsDrawer({
  entityId,
  locations,
  employees,
  onClose,
}: {
  entityId: string
  locations: Loc[]
  employees: Emp[]
  onClose: () => void
}) {
  const [rows, setRows] = useState<ShiftAdjustment[]>([])
  const [names, setNames] = useState<Map<string, string>>(new Map())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const locName = useMemo(() => new Map(locations.map((l) => [l.id, l.name])), [locations])
  const empName = useMemo(() => new Map(employees.map((e) => [e.id, e.full_name])), [employees])

  const load = useCallback(async () => {
    setLoading(true)
    const { data, error: qErr } = await supabase
      .from('shift_adjustments')
      .select('*')
      .eq('entity_id', entityId)
      .eq('change_type', 'deleted')
      .order('changed_at', { ascending: false })
      .limit(200)
    if (qErr) {
      setLoading(false)
      return setError(qErr.message)
    }
    const list = (data ?? []) as ShiftAdjustment[]
    setRows(list)
    const ids = [...new Set(list.map((r) => r.changed_by).filter((x): x is string => !!x))]
    if (ids.length) {
      const { data: profs } = await supabase.from('profiles').select('id, full_name').in('id', ids)
      setNames(new Map((profs ?? []).map((p: { id: string; full_name: string | null }) => [p.id, p.full_name ?? 'Unknown'])))
    }
    setLoading(false)
  }, [entityId])

  useEffect(() => {
    load()
  }, [load])

  const fmtTs = (ts: string) =>
    new Date(ts).toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })

  return (
    <Overlay onClose={onClose}>
      <Header title="Deleted shifts" sub="Every deleted shift is kept here with who deleted it and why." onClose={onClose} />
      <ErrorBox msg={error} />
      {loading ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-12 animate-pulse rounded-lg bg-surface-alt" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No shifts have been deleted.</p>
      ) : (
        <ul className="max-h-[60vh] divide-y divide-border overflow-y-auto">
          {rows.map((r) => {
            const o = (r.old_values ?? {}) as Record<string, string | null>
            const who = o.employee_id ? empName.get(o.employee_id) ?? 'Unknown employee' : 'Open shift'
            return (
              <li key={r.id} className="py-3 text-sm">
                <div className="flex items-start justify-between gap-2">
                  <span className="font-medium text-ink">
                    {o.shift_date ? fmtDayShort(o.shift_date) : '—'} · {o.start_time ? fmtTime(o.start_time) : ''}–
                    {o.end_time ? fmtTime(o.end_time) : ''}
                  </span>
                  <span className="shrink-0 text-xs text-muted">{fmtTs(r.changed_at)}</span>
                </div>
                <p className="mt-0.5 text-xs text-muted">
                  {who} · {(r.location_id && locName.get(r.location_id)) || (o.location_id && locName.get(o.location_id)) || 'Branch'}
                  {o.status ? ` · was ${o.status}` : ''}
                </p>
                <p className="mt-0.5 text-xs text-muted">
                  Deleted by {(r.changed_by && names.get(r.changed_by)) || 'an admin'}
                  {r.reason ? ` — ${r.reason}` : ''}
                </p>
              </li>
            )
          })}
        </ul>
      )}
    </Overlay>
  )
}

// ---------------------------------------------------------------------------
// Branch setup: opening hours + staffing needs
// ---------------------------------------------------------------------------

interface HourRow {
  day_of_week: number
  is_closed: boolean
  open_time: string
  close_time: string
}
interface NeedRow {
  key: string
  day_of_week: number | null
  start_time: string
  end_time: string
  position_id: string | null
  staff_needed: number
}
interface SetupBranch {
  location_id: string
  name: string
  hours: { day_of_week: number; is_closed: boolean; open_time: string | null; close_time: string | null }[]
  needs: { id: string; day_of_week: number | null; start_time: string; end_time: string; position_id: string | null; staff_needed: number }[]
}

let keySeq = 0
const newKey = () => `n${++keySeq}`

export function BranchSetupDrawer({
  entityId,
  positions,
  onClose,
  onSaved,
}: {
  entityId: string
  positions: Pos[]
  onClose: () => void
  onSaved: (msg: string) => void
}) {
  const [setup, setSetup] = useState<SetupBranch[] | null>(null)
  const [locId, setLocId] = useState('')
  const [hours, setHours] = useState<HourRow[]>([])
  const [needs, setNeeds] = useState<NeedRow[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    const { data, error: rpcError } = await supabase.rpc('get_scheduling_setup', { p_entity_id: entityId })
    if (rpcError) return setError(errText(rpcError))
    const list = (data ?? []) as SetupBranch[]
    setSetup(list)
    setLocId((cur) => cur || list[0]?.location_id || '')
  }, [entityId])

  useEffect(() => {
    load()
  }, [load])

  const branch = setup?.find((b) => b.location_id === locId)

  useEffect(() => {
    if (!branch) return
    setHours(
      DOW_LONG.map((_, d) => {
        const h = branch.hours.find((x) => x.day_of_week === d)
        return { day_of_week: d, is_closed: h?.is_closed ?? false, open_time: hhmm(h?.open_time), close_time: hhmm(h?.close_time) }
      })
    )
    setNeeds(
      branch.needs.map((n) => ({
        key: newKey(),
        day_of_week: n.day_of_week,
        start_time: hhmm(n.start_time),
        end_time: hhmm(n.end_time),
        position_id: n.position_id,
        staff_needed: n.staff_needed,
      }))
    )
    setError(null)
  }, [branch])

  const hoursConfigured = (branch?.hours.length ?? 0) > 0

  function setHour(d: number, patch: Partial<HourRow>) {
    setHours((hs) => hs.map((h) => (h.day_of_week === d ? { ...h, ...patch } : h)))
  }
  function setNeed(key: string, patch: Partial<NeedRow>) {
    setNeeds((ns) => ns.map((n) => (n.key === key ? { ...n, ...patch } : n)))
  }

  function validate(): string | null {
    for (const h of hours) {
      if (h.is_closed) continue
      if (!h.open_time || !h.close_time) return `Set opening and closing time for ${DOW_LONG[h.day_of_week]}, or mark it closed.`
      if (h.open_time === h.close_time) return `${DOW_LONG[h.day_of_week]}: opening and closing time can't be the same.`
    }
    for (const n of needs) {
      if (!n.start_time || !n.end_time) return 'Every staffing need needs a start and end time.'
      if (n.start_time === n.end_time) return 'A staffing need cannot start and end at the same time.'
      if (!(n.staff_needed >= 1)) return 'Staff needed must be at least 1.'
    }
    return null
  }

  async function save() {
    const v = validate()
    if (v) return setError(v)
    setBusy(true)
    setError(null)
    const h = await supabase.rpc('set_location_operating_hours', {
      p_location_id: locId,
      p_hours: hours.map((x) =>
        x.is_closed
          ? { day_of_week: x.day_of_week, is_closed: true }
          : { day_of_week: x.day_of_week, is_closed: false, open_time: x.open_time, close_time: x.close_time }
      ),
    })
    if (h.error) {
      setBusy(false)
      return setError(errText(h.error))
    }
    const n = await supabase.rpc('set_location_staffing_needs', {
      p_location_id: locId,
      p_needs: needs.map((x) => ({
        day_of_week: x.day_of_week,
        start_time: x.start_time,
        end_time: x.end_time,
        position_id: x.position_id,
        staff_needed: x.staff_needed,
      })),
    })
    setBusy(false)
    if (n.error) return setError(errText(n.error))
    onSaved(`Saved opening hours and staffing needs for ${branch?.name ?? 'the branch'}.`)
    await load()
  }

  return (
    <Overlay onClose={onClose} wide>
      <Header
        title="Branch setup"
        sub="Opening hours and how many people each branch needs. The auto-scheduler plans nothing for a branch without opening hours."
        onClose={onClose}
      />
      {!setup ? (
        error ? <ErrorBox msg={error} /> : <div className="h-40 animate-pulse rounded-lg bg-surface-alt" />
      ) : setup.length === 0 ? (
        <p className="text-sm text-muted">No active branches in this company.</p>
      ) : (
        <div className="space-y-5">
          <div className="flex flex-wrap gap-2">
            {setup.map((b) => (
              <button
                key={b.location_id}
                onClick={() => setLocId(b.location_id)}
                className={`rounded-full px-3 py-1.5 text-xs font-medium ${
                  b.location_id === locId ? 'bg-brand-blue text-white' : 'bg-surface-alt text-ink hover:bg-border'
                }`}
              >
                {b.name}
                {b.hours.length === 0 && <span className="ml-1 opacity-70">· not set</span>}
              </button>
            ))}
          </div>

          <section>
            <h3 className="mb-1 text-sm font-semibold text-ink">Opening hours</h3>
            {!hoursConfigured && (
              <p className="mb-2 text-xs text-brand-warning-solid">Not set yet — fill these in and save.</p>
            )}
            <p className="mb-2 text-xs text-muted">If closing is earlier than opening, the branch closes the next day (overnight).</p>
            <div className="divide-y divide-border rounded-lg border border-border">
              {hours.map((h) => (
                <div key={h.day_of_week} className="flex flex-wrap items-center gap-3 px-3 py-2 text-sm">
                  <span className="w-24 font-medium text-ink">{DOW_LONG[h.day_of_week]}</span>
                  <label className="flex items-center gap-1.5 text-xs text-muted">
                    <input type="checkbox" checked={h.is_closed} onChange={(e) => setHour(h.day_of_week, { is_closed: e.target.checked })} />
                    Closed
                  </label>
                  {!h.is_closed && (
                    <>
                      <input
                        type="time"
                        aria-label={`${DOW_LONG[h.day_of_week]} opening time`}
                        className="input w-32"
                        value={h.open_time}
                        onChange={(e) => setHour(h.day_of_week, { open_time: e.target.value })}
                      />
                      <span className="text-muted">to</span>
                      <input
                        type="time"
                        aria-label={`${DOW_LONG[h.day_of_week]} closing time`}
                        className="input w-32"
                        value={h.close_time}
                        onChange={(e) => setHour(h.day_of_week, { close_time: e.target.value })}
                      />
                      {h.open_time && h.close_time && h.close_time < h.open_time && (
                        <span className="text-xs text-muted">overnight</span>
                      )}
                    </>
                  )}
                </div>
              ))}
            </div>
            <button
              className="mt-2 text-xs font-medium text-brand-blue hover:underline"
              onClick={() => {
                const first = hours.find((h) => !h.is_closed && h.open_time && h.close_time)
                if (first) setHours((hs) => hs.map((h) => (h.is_closed ? h : { ...h, open_time: first.open_time, close_time: first.close_time })))
              }}
            >
              Copy first open day's hours to all open days
            </button>
          </section>

          <section>
            <h3 className="mb-1 text-sm font-semibold text-ink">Staffing needs</h3>
            <p className="mb-2 text-xs text-muted">
              With no needs set, the scheduler plans 1 person for the whole opening time. Saving replaces all needs for this branch.
            </p>
            {needs.length > 0 && (
              <div className="space-y-2">
                {needs.map((n) => (
                  <div key={n.key} className="flex flex-wrap items-center gap-2 rounded-lg bg-surface-alt px-3 py-2">
                    <select
                      aria-label="Day"
                      className="input w-40"
                      value={n.day_of_week ?? ''}
                      onChange={(e) => setNeed(n.key, { day_of_week: e.target.value === '' ? null : Number(e.target.value) })}
                    >
                      <option value="">Every open day</option>
                      {DOW_LONG.map((d, i) => (
                        <option key={i} value={i}>
                          {d}
                        </option>
                      ))}
                    </select>
                    <input
                      type="time"
                      aria-label="From"
                      className="input w-32"
                      value={n.start_time}
                      onChange={(e) => setNeed(n.key, { start_time: e.target.value })}
                    />
                    <span className="text-sm text-muted">to</span>
                    <input
                      type="time"
                      aria-label="To"
                      className="input w-32"
                      value={n.end_time}
                      onChange={(e) => setNeed(n.key, { end_time: e.target.value })}
                    />
                    <input
                      type="number"
                      min={1}
                      aria-label="Staff needed"
                      className="input w-20"
                      value={n.staff_needed}
                      onChange={(e) => setNeed(n.key, { staff_needed: Number(e.target.value) })}
                    />
                    <span className="text-xs text-muted">people</span>
                    <select
                      aria-label="Role"
                      className="input w-44"
                      value={n.position_id ?? ''}
                      onChange={(e) => setNeed(n.key, { position_id: e.target.value || null })}
                    >
                      <option value="">Any role</option>
                      {positions.map((p) => (
                        <option key={p.id} value={p.id}>
                          {p.title}
                        </option>
                      ))}
                    </select>
                    <button
                      className="ml-auto text-xs font-medium text-brand-risk hover:underline"
                      onClick={() => setNeeds((ns) => ns.filter((x) => x.key !== n.key))}
                    >
                      Remove
                    </button>
                  </div>
                ))}
              </div>
            )}
            <button
              className="mt-2 text-xs font-medium text-brand-blue hover:underline"
              onClick={() => {
                const open = hours.find((h) => !h.is_closed && h.open_time && h.close_time)
                setNeeds((ns) => [
                  ...ns,
                  {
                    key: newKey(),
                    day_of_week: null,
                    start_time: open?.open_time ?? '',
                    end_time: open?.close_time ?? '',
                    position_id: null,
                    staff_needed: 1,
                  },
                ])
              }}
            >
              + Add staffing need
            </button>
          </section>

          <ErrorBox msg={error} />
          <div className="flex justify-end gap-2">
            <button className="btn-secondary" onClick={onClose}>
              Close
            </button>
            <button className="btn-primary" onClick={save} disabled={busy || !locId}>
              {busy ? 'Saving…' : `Save ${branch?.name ?? ''}`}
            </button>
          </div>
        </div>
      )}
    </Overlay>
  )
}

// ---------------------------------------------------------------------------
// Auto-scheduler: preview (propose_auto_schedule) → create drafts (apply_auto_schedule)
// ---------------------------------------------------------------------------

interface PlanShift {
  shift_date: string
  location_id: string
  location: string
  employee_id: string
  employee: string
  position_id: string | null
  start_time: string
  end_time: string
  break_minutes: number
  cross_branch: boolean
  home_location: string | null
}
interface Plan {
  period_start: string
  period_end: string
  shifts: PlanShift[]
  unfilled: { shift_date: string; location: string; role: string | null; start_time: string; end_time: string }[]
  warnings: string[]
  summary: { planned: number; cross_branch: number; unfilled: number; planned_hours: number }
  created?: number
}

export function AutoScheduleModal({
  entityId,
  locations,
  onClose,
  onApplied,
  onOpenSetup,
}: {
  entityId: string
  locations: Loc[]
  onClose: () => void
  onApplied: (created: number) => void
  onOpenSetup: () => void
}) {
  const [start, setStart] = useState(addDaysIso(todayIso(), 1))
  const [end, setEnd] = useState(addDaysIso(todayIso(), 7))
  const [picked, setPicked] = useState<Set<string>>(new Set(locations.map((l) => l.id)))
  const [plan, setPlan] = useState<Plan | null>(null)
  const [busy, setBusy] = useState<'preview' | 'apply' | null>(null)
  const [error, setError] = useState<string | null>(null)

  const allPicked = picked.size === locations.length

  function args() {
    return {
      p_entity_id: entityId,
      p_period_start: start,
      p_period_end: end,
      p_location_ids: allPicked ? null : [...picked],
    }
  }

  function validate(): string | null {
    if (!start || !end) return 'Choose a start and end date.'
    if (start < todayIso()) return 'The period cannot start in the past.'
    if (end < start) return 'The end date must be on or after the start date.'
    if (daysBetween(start, end) + 1 > 31) return 'The period can be at most 31 days.'
    if (picked.size === 0) return 'Choose at least one branch.'
    return null
  }

  async function preview() {
    const v = validate()
    if (v) return setError(v)
    setBusy('preview')
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('propose_auto_schedule', args())
    setBusy(null)
    if (rpcError) return setError(errText(rpcError))
    setPlan(data as Plan)
  }

  async function apply() {
    if (!plan) return
    setBusy('apply')
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('apply_auto_schedule', args())
    setBusy(null)
    if (rpcError) return setError(errText(rpcError))
    onApplied((data as Plan).created ?? 0)
  }

  const byDate = useMemo(() => {
    const m = new Map<string, PlanShift[]>()
    plan?.shifts.forEach((s) => m.set(s.shift_date, [...(m.get(s.shift_date) ?? []), s]))
    return [...m.entries()]
  }, [plan])

  const changeInputs = <T,>(fn: (v: T) => void) => (v: T) => {
    fn(v)
    setPlan(null)
  }

  return (
    <Overlay onClose={onClose} wide>
      <Header
        title="Auto-schedule"
        sub="Plans draft shifts from each branch's opening hours, staffing needs, availability, leave and weekly limits. Nothing is published — you review and publish as usual."
        onClose={onClose}
      />

      <div className="flex flex-wrap items-end gap-3">
        <label>
          <span className="label">From</span>
          <input type="date" className="input" min={todayIso()} value={start} onChange={(e) => changeInputs(setStart)(e.target.value)} />
        </label>
        <label>
          <span className="label">To</span>
          <input type="date" className="input" min={start} max={addDaysIso(start, 30)} value={end} onChange={(e) => changeInputs(setEnd)(e.target.value)} />
        </label>
        <span className="pb-2 text-xs text-muted">{start && end && end >= start ? `${daysBetween(start, end) + 1} days` : ''}</span>
        <button className="btn-ghost ml-auto" onClick={onOpenSetup}>
          Branch setup
        </button>
      </div>

      <div className="mt-3">
        <span className="label">Branches</span>
        <div className="flex flex-wrap gap-2">
          {locations.map((l) => (
            <label key={l.id} className="flex items-center gap-1.5 rounded-full bg-surface-alt px-3 py-1.5 text-xs text-ink">
              <input
                type="checkbox"
                checked={picked.has(l.id)}
                onChange={(e) =>
                  changeInputs(setPicked)(
                    (() => {
                      const n = new Set(picked)
                      if (e.target.checked) n.add(l.id)
                      else n.delete(l.id)
                      return n
                    })()
                  )
                }
              />
              {l.name}
            </label>
          ))}
        </div>
      </div>

      <div className="mt-4 flex justify-end">
        <button className="btn-secondary" onClick={preview} disabled={busy !== null}>
          {busy === 'preview' ? 'Planning…' : plan ? 'Re-run preview' : 'Preview plan'}
        </button>
      </div>

      <div className="mt-3">
        <ErrorBox msg={error} />
      </div>

      {plan && (
        <div className="mt-4 space-y-4">
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Stat label="Shifts planned" value={plan.summary.planned} />
            <Stat label="Hours" value={plan.summary.planned_hours} />
            <Stat label="At another branch" value={plan.summary.cross_branch} />
            <Stat label="Unfilled slots" value={plan.summary.unfilled} warn={plan.summary.unfilled > 0} />
          </div>

          {plan.warnings.length > 0 && (
            <ul className="space-y-1">
              {plan.warnings.map((w, i) => (
                <li key={i} className="rounded-lg bg-brand-warning-soft px-3 py-2 text-xs text-brand-warning-solid">
                  {w}
                </li>
              ))}
            </ul>
          )}

          {byDate.length === 0 ? (
            <p className="text-sm text-muted">No shifts could be planned for this period.</p>
          ) : (
            <div className="max-h-[40vh] overflow-y-auto rounded-lg border border-border">
              <table className="w-full text-left text-sm">
                <thead className="sticky top-0 bg-surface-alt text-xs uppercase tracking-wide text-muted">
                  <tr>
                    <th className="px-3 py-2 font-medium">Date</th>
                    <th className="px-3 py-2 font-medium">Branch</th>
                    <th className="px-3 py-2 font-medium">Person</th>
                    <th className="px-3 py-2 font-medium">Time</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {byDate.flatMap(([date, list]) =>
                    list.map((s, i) => (
                      <tr key={`${date}-${i}`}>
                        <td className="px-3 py-2 text-ink">{i === 0 ? `${DOW_SHORT[new Date(date + 'T00:00:00').getDay()]} ${fmtDayShort(date)}` : ''}</td>
                        <td className="px-3 py-2 text-muted">{s.location}</td>
                        <td className="px-3 py-2 text-ink">
                          {s.employee}
                          {s.cross_branch && (
                            <span className="ml-1.5 rounded-full bg-brand-blue/10 px-2 py-0.5 text-[11px] text-brand-blue">
                              moved from {s.home_location ?? 'no home branch'}
                            </span>
                          )}
                        </td>
                        <td className="px-3 py-2 text-muted">
                          {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                          {s.break_minutes > 0 && <span className="ml-1 text-xs">· {s.break_minutes}m break</span>}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          )}

          {plan.unfilled.length > 0 && (
            <details className="rounded-lg border border-border px-3 py-2">
              <summary className="cursor-pointer text-sm font-medium text-ink">
                {plan.unfilled.length} slot{plan.unfilled.length === 1 ? '' : 's'} not filled — not enough available people
              </summary>
              <ul className="mt-2 max-h-40 space-y-1 overflow-y-auto text-xs text-muted">
                {plan.unfilled.map((u, i) => (
                  <li key={i}>
                    {fmtDayShort(u.shift_date)} · {u.location} · {fmtTime(u.start_time)}–{fmtTime(u.end_time)}
                    {u.role ? ` · ${u.role}` : ''}
                  </li>
                ))}
              </ul>
            </details>
          )}

          <div className="flex items-center justify-end gap-2">
            <p className="mr-auto text-xs text-muted">Creating re-runs the plan on the server, so it reflects any changes since this preview.</p>
            <button className="btn-secondary" onClick={onClose}>
              Cancel
            </button>
            <button className="btn-primary" onClick={apply} disabled={busy !== null || plan.summary.planned === 0}>
              {busy === 'apply' ? 'Creating…' : `Create ${plan.summary.planned} draft shift${plan.summary.planned === 1 ? '' : 's'}`}
            </button>
          </div>
        </div>
      )}
    </Overlay>
  )
}

function Stat({ label, value, warn }: { label: string; value: number; warn?: boolean }) {
  return (
    <div className="rounded-lg bg-surface-alt p-3">
      <span className="block text-xs text-muted">{label}</span>
      <span className={`mt-1 block text-lg font-semibold tabular-nums ${warn ? 'text-brand-warning-solid' : 'text-ink'}`}>{value}</span>
    </div>
  )
}
