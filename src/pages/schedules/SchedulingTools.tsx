import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { fmtDayShort, fmtTime, todayDubai } from '../../lib/format'
import { isoAddDays, thisMonday } from './week'
import { Sheet } from '../../components/Sheet'
import type { Employee, Location, Position, ShiftAdjustment } from '../../types/db'

const DOW_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

const errText = (err: { message: string }) => err.message.replace(/^ERROR:\s*/i, '')
const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : '')
const toMin = (t: string) => {
  const [h, m] = t.split(':').map(Number)
  return h * 60 + (m || 0)
}

function isoOf(d: Date) {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}
function todayIso() {
  return isoOf(new Date())
}
function addDaysIso(iso: string, days: number) {
  const d = new Date(iso + 'T00:00:00')
  d.setDate(d.getDate() + days)
  return isoOf(d)
}
function daysBetween(a: string, b: string) {
  return Math.round((new Date(b + 'T00:00:00').getTime() - new Date(a + 'T00:00:00').getTime()) / 86400000)
}

type Loc = Pick<Location, 'id' | 'name'>
type Pos = Pick<Position, 'id' | 'title'>
type Emp = Pick<Employee, 'id' | 'full_name' | 'home_location_id'>

function ErrorBox({ msg }: { msg: string | null }) {
  if (!msg) return null
  return (
    <p role="alert" className="rise rounded-xl bg-brand-risk-soft px-3.5 py-2.5 text-sm text-brand-risk-text">
      {msg}
    </p>
  )
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
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="delete-shifts-title"
        className="rise w-full max-w-lg rounded-[18px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 id="delete-shifts-title" className="text-base font-semibold tracking-[-0.01em] text-ink">
          {shifts.length === 1 ? 'Delete cancelled shift' : `Delete ${shifts.length} cancelled shifts`}
        </h2>
        <p className="mt-1 text-[13px] text-muted">Removed from the roster, but kept in the deleted shifts log with your reason.</p>
        <ul className="my-4 max-h-48 space-y-1 overflow-y-auto text-xs">
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
          <button className="btn-secondary press" onClick={onClose}>
            Back
          </button>
          <button
            onClick={submit}
            disabled={busy}
            className="press rounded-lg bg-brand-risk px-4 py-2 text-sm font-medium text-white hover:bg-brand-risk/90 disabled:opacity-60"
          >
            {busy ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Deleted-shift history → shift_adjustments where change_type = 'deleted'
// ---------------------------------------------------------------------------

export function DeletedShiftsSheet({
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
    <Sheet title="Deleted shifts" subtitle="Every deleted shift, who deleted it and why." onClose={onClose}>
      <ErrorBox msg={error} />
      {loading ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-14 animate-pulse rounded-xl bg-surface-alt" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <p className="py-10 text-center text-sm text-muted">No shifts have been deleted.</p>
      ) : (
        <ul className="divide-y divide-border">
          {rows.map((r, i) => {
            const o = (r.old_values ?? {}) as Record<string, string | null>
            const who = o.employee_id ? empName.get(o.employee_id) ?? 'Unknown employee' : 'Open shift'
            return (
              <li key={r.id} className="rise py-3.5 text-sm" style={{ '--i': Math.min(i, 12) } as React.CSSProperties}>
                <div className="flex items-start justify-between gap-2">
                  <span className="font-medium text-ink">
                    {o.shift_date ? fmtDayShort(o.shift_date) : '—'} · {o.start_time ? fmtTime(o.start_time) : ''}–
                    {o.end_time ? fmtTime(o.end_time) : ''}
                  </span>
                  <span className="shrink-0 text-xs tabular-nums text-muted">{fmtTs(r.changed_at)}</span>
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
    </Sheet>
  )
}

// ---------------------------------------------------------------------------
// Branch setup sheet: opening hours + staffing needs
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
export interface SetupBranch {
  location_id: string
  name: string
  hours: { day_of_week: number; is_closed: boolean; open_time: string | null; close_time: string | null }[]
  needs: { id: string; day_of_week: number | null; start_time: string; end_time: string; position_id: string | null; staff_needed: number }[]
}

let keySeq = 0
const newKey = () => `n${++keySeq}`

export function BranchSetupSheet({
  setup,
  initialLocationId,
  positions,
  onClose,
  onSaved,
}: {
  setup: SetupBranch[]
  initialLocationId?: string
  positions: Pos[]
  onClose: () => void
  onSaved: (msg: string) => void
}) {
  const [locId, setLocId] = useState(initialLocationId || setup[0]?.location_id || '')
  const [hours, setHours] = useState<HourRow[]>([])
  const [needs, setNeeds] = useState<NeedRow[]>([])
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [savedAt, setSavedAt] = useState<number | null>(null)

  const branch = setup.find((b) => b.location_id === locId)

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
    setDirty(false)
    setError(null)
  }, [branch])

  function setHour(d: number, patch: Partial<HourRow>) {
    setDirty(true)
    setHours((hs) => hs.map((h) => (h.day_of_week === d ? { ...h, ...patch } : h)))
  }
  function setNeed(key: string, patch: Partial<NeedRow>) {
    setDirty(true)
    setNeeds((ns) => ns.map((n) => (n.key === key ? { ...n, ...patch } : n)))
  }

  // Inline validation — shown as the user types, not on submit.
  const problem = useMemo(() => {
    for (const h of hours) {
      if (h.is_closed) continue
      if (!h.open_time || !h.close_time) return `Set ${DOW_LONG[h.day_of_week]}'s hours, or mark it closed.`
      if (h.open_time === h.close_time) return `${DOW_LONG[h.day_of_week]}: opening and closing can't be the same time.`
    }
    for (const n of needs) {
      if (!n.start_time || !n.end_time) return 'Each staffing need needs a start and end time.'
      if (n.start_time === n.end_time) return 'A staffing need can’t start and end at the same time.'
      if (!(n.staff_needed >= 1)) return 'Staff needed must be at least 1.'
    }
    return null
  }, [hours, needs])

  async function save() {
    if (problem) return setError(problem)
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
    setDirty(false)
    setSavedAt(Date.now())
    onSaved(`Saved opening hours and staffing needs for ${branch?.name ?? 'the branch'}.`)
  }

  const firstOpen = hours.find((h) => !h.is_closed && h.open_time && h.close_time)

  return (
    <Sheet
      title="Branch setup"
      subtitle="When each branch is open and how many people it needs. The auto-scheduler plans only for branches with opening hours."
      onClose={onClose}
      footer={
        <div className="flex items-center justify-between gap-3">
          <p className="min-w-0 text-xs text-muted" aria-live="polite">
            {problem && dirty ? (
              <span className="text-brand-warning-solid">{problem}</span>
            ) : dirty ? (
              'Unsaved changes'
            ) : savedAt ? (
              'Saved'
            ) : (
              ' '
            )}
          </p>
          <button className="btn-primary press shrink-0" onClick={save} disabled={busy || !locId || !dirty}>
            {busy ? 'Saving…' : `Save ${branch?.name ?? ''}`}
          </button>
        </div>
      }
    >
      {setup.length === 0 ? (
        <p className="py-10 text-center text-sm text-muted">No active branches in this company.</p>
      ) : (
        <div className="space-y-7">
          <div className="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1" role="tablist" aria-label="Branch">
            {setup.map((b) => {
              const on = b.location_id === locId
              return (
                <button
                  key={b.location_id}
                  role="tab"
                  aria-selected={on}
                  onClick={() => setLocId(b.location_id)}
                  className={`press shrink-0 rounded-full px-3.5 py-1.5 text-[13px] font-medium ${
                    on ? 'bg-ink text-white' : 'bg-surface-alt text-ink hover:bg-border'
                  }`}
                >
                  {b.name}
                  {b.hours.length === 0 && (
                    <span className={`ml-1.5 inline-block h-1.5 w-1.5 rounded-full align-middle ${on ? 'bg-white/70' : 'bg-brand-warning'}`} aria-label="not set up" />
                  )}
                </button>
              )
            })}
          </div>

          <section key={`h-${locId}`} className="rise">
            <div className="mb-2 flex items-baseline justify-between gap-3">
              <h3 className="text-[15px] font-semibold tracking-[-0.01em] text-ink">Opening hours</h3>
              {firstOpen && (
                <button
                  className="press text-xs font-medium text-brand-blue hover:underline"
                  onClick={() => {
                    setDirty(true)
                    setHours((hs) => hs.map((h) => (h.is_closed ? h : { ...h, open_time: firstOpen.open_time, close_time: firstOpen.close_time })))
                  }}
                >
                  Use {firstOpen.open_time}–{firstOpen.close_time} for all open days
                </button>
              )}
            </div>
            {branch && branch.hours.length === 0 && (
              <p className="mb-3 rounded-xl bg-brand-warning-soft px-3.5 py-2.5 text-xs text-brand-warning-solid">
                Not set up yet — nothing will be auto-scheduled here until you save opening hours.
              </p>
            )}
            <div className="overflow-hidden rounded-2xl border border-border">
              {hours.map((h) => {
                const overnight = !h.is_closed && h.open_time && h.close_time && h.close_time < h.open_time
                return (
                  <div
                    key={h.day_of_week}
                    className={`flex min-h-12 flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2 text-sm ${h.day_of_week ? 'border-t border-border' : ''} ${
                      h.is_closed ? 'bg-surface-alt/60' : ''
                    }`}
                  >
                    <span className={`w-24 font-medium ${h.is_closed ? 'text-muted' : 'text-ink'}`}>{DOW_LONG[h.day_of_week]}</span>
                    {h.is_closed ? (
                      <span className="flex-1 text-[13px] text-muted">Closed</span>
                    ) : (
                      <span className="flex flex-1 flex-wrap items-center gap-2">
                        <input
                          type="time"
                          aria-label={`${DOW_LONG[h.day_of_week]} opens`}
                          className="input w-[7.5rem] py-1.5"
                          value={h.open_time}
                          onChange={(e) => setHour(h.day_of_week, { open_time: e.target.value })}
                        />
                        <span className="text-muted">–</span>
                        <input
                          type="time"
                          aria-label={`${DOW_LONG[h.day_of_week]} closes`}
                          className="input w-[7.5rem] py-1.5"
                          value={h.close_time}
                          onChange={(e) => setHour(h.day_of_week, { close_time: e.target.value })}
                        />
                        {overnight && <span className="rounded-full bg-brand-info-soft px-2 py-0.5 text-[11px] font-medium text-brand-info-text">next day</span>}
                      </span>
                    )}
                    <label className="flex items-center gap-2 text-xs text-muted">
                      <input
                        type="checkbox"
                        className="h-4 w-4 accent-[var(--color-brand-blue)]"
                        checked={!h.is_closed}
                        onChange={(e) => setHour(h.day_of_week, { is_closed: !e.target.checked })}
                      />
                      Open
                    </label>
                  </div>
                )
              })}
            </div>
          </section>

          <section key={`n-${locId}`} className="rise" style={{ '--i': 3 } as React.CSSProperties}>
            <h3 className="text-[15px] font-semibold tracking-[-0.01em] text-ink">Staffing needs</h3>
            <p className="mb-3 mt-0.5 text-xs text-muted">
              {needs.length === 0
                ? 'None yet — the scheduler will plan 1 person for the whole opening time.'
                : 'Saving replaces all needs for this branch.'}
            </p>
            <div className="space-y-2">
              {needs.map((n, i) => (
                <div key={n.key} className="rise rounded-2xl border border-border p-3" style={{ '--i': i } as React.CSSProperties}>
                  <div className="flex flex-wrap items-center gap-2">
                    <input
                      type="number"
                      min={1}
                      aria-label="People needed"
                      className="input w-16 py-1.5 text-center tabular-nums"
                      value={n.staff_needed}
                      onChange={(e) => setNeed(n.key, { staff_needed: Number(e.target.value) })}
                    />
                    <select
                      aria-label="Role"
                      className="input w-auto min-w-36 py-1.5"
                      value={n.position_id ?? ''}
                      onChange={(e) => setNeed(n.key, { position_id: e.target.value || null })}
                    >
                      <option value="">{n.staff_needed === 1 ? 'person' : 'people'} · any role</option>
                      {positions.map((p) => (
                        <option key={p.id} value={p.id}>
                          × {p.title}
                        </option>
                      ))}
                    </select>
                    <span className="text-[13px] text-muted">on</span>
                    <select
                      aria-label="Day"
                      className="input w-auto py-1.5"
                      value={n.day_of_week ?? ''}
                      onChange={(e) => setNeed(n.key, { day_of_week: e.target.value === '' ? null : Number(e.target.value) })}
                    >
                      <option value="">every open day</option>
                      {DOW_LONG.map((d, di) => (
                        <option key={di} value={di}>
                          {d}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="mt-2 flex flex-wrap items-center gap-2">
                    <span className="text-[13px] text-muted">from</span>
                    <input
                      type="time"
                      aria-label="From"
                      className="input w-[7.5rem] py-1.5"
                      value={n.start_time}
                      onChange={(e) => setNeed(n.key, { start_time: e.target.value })}
                    />
                    <span className="text-[13px] text-muted">to</span>
                    <input
                      type="time"
                      aria-label="To"
                      className="input w-[7.5rem] py-1.5"
                      value={n.end_time}
                      onChange={(e) => setNeed(n.key, { end_time: e.target.value })}
                    />
                    <button
                      className="press ml-auto rounded-full px-2.5 py-1 text-xs font-medium text-brand-risk hover:bg-brand-risk-soft"
                      onClick={() => {
                        setDirty(true)
                        setNeeds((ns) => ns.filter((x) => x.key !== n.key))
                      }}
                    >
                      Remove
                    </button>
                  </div>
                </div>
              ))}
            </div>
            <button
              className="press mt-3 w-full rounded-2xl border border-dashed border-border py-3 text-[13px] font-medium text-brand-blue hover:border-brand-blue/50 hover:bg-brand-blue-soft/40"
              onClick={() => {
                setDirty(true)
                setNeeds((ns) => [
                  ...ns,
                  {
                    key: newKey(),
                    day_of_week: null,
                    start_time: firstOpen?.open_time ?? '',
                    end_time: firstOpen?.close_time ?? '',
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
        </div>
      )}
    </Sheet>
  )
}

// ---------------------------------------------------------------------------
// Auto-schedule workspace: choose → preview (propose) → create drafts (apply)
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
interface PlanGap {
  shift_date: string
  location: string
  role: string | null
  start_time: string
  end_time: string
}
interface Plan {
  period_start: string
  period_end: string
  shifts: PlanShift[]
  unfilled: PlanGap[]
  warnings: string[]
  summary: { planned: number; cross_branch: number; unfilled: number; planned_hours: number }
  created?: number
}

type Preset = 'week' | 'next7' | 'twoweeks' | 'custom'

// Weeks run Monday–Sunday, like the week grid and the 48 h / working-day rules.
function presetRange(p: Exclude<Preset, 'custom'>): [string, string] {
  const t = todayDubai()
  if (p === 'next7') return [isoAddDays(t, 1), isoAddDays(t, 7)]
  const nextMonday = isoAddDays(thisMonday(), 7)
  if (p === 'twoweeks') return [nextMonday, isoAddDays(nextMonday, 13)]
  return [nextMonday, isoAddDays(nextMonday, 6)]
}

export function AutoSchedulePanel({
  entityId,
  positions,
  onApplied,
  onNotice,
}: {
  entityId: string
  positions: Pos[]
  onApplied: (created: number, periodStart: string, locationIds: string[] | null) => void
  onNotice: (msg: string) => void
}) {
  const [setup, setSetup] = useState<SetupBranch[] | null>(null)
  const [preset, setPreset] = useState<Preset>('week')
  const [[start, end], setRange] = useState<[string, string]>(presetRange('week'))
  const [picked, setPicked] = useState<Set<string> | null>(null)
  const [plan, setPlan] = useState<Plan | null>(null)
  const [planKey, setPlanKey] = useState<string | null>(null)
  const [busy, setBusy] = useState<'preview' | 'apply' | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [setupFor, setSetupFor] = useState<string | null | undefined>(undefined)

  const loadSetup = useCallback(async () => {
    const { data, error: rpcError } = await supabase.rpc('get_scheduling_setup', { p_entity_id: entityId })
    if (rpcError) return setError(errText(rpcError))
    const list = (data ?? []) as SetupBranch[]
    setSetup(list)
    setPicked((cur) => cur ?? new Set(list.map((b) => b.location_id)))
  }, [entityId])

  useEffect(() => {
    loadSetup()
  }, [loadSetup])

  const selected = useMemo(() => setup?.filter((b) => picked?.has(b.location_id)) ?? [], [setup, picked])
  const allPicked = !!setup && selected.length === setup.length
  const notReady = selected.filter((b) => b.hours.length === 0)

  const inputKey = JSON.stringify([start, end, allPicked ? null : [...(picked ?? [])].sort()])
  const stale = !!plan && planKey !== inputKey

  const rangeProblem = useMemo(() => {
    if (!start || !end) return 'Choose a start and end date.'
    if (start < todayIso()) return 'The period can’t start in the past.'
    if (end < start) return 'The end date must be on or after the start.'
    if (daysBetween(start, end) + 1 > 31) return 'Choose 31 days or fewer.'
    return null
  }, [start, end])

  function args() {
    return {
      p_entity_id: entityId,
      p_period_start: start,
      p_period_end: end,
      p_location_ids: allPicked ? null : [...(picked ?? [])],
    }
  }

  async function preview() {
    if (rangeProblem) return setError(rangeProblem)
    if (selected.length === 0) return setError('Choose at least one branch.')
    setBusy('preview')
    setError(null)
    const key = inputKey
    const { data, error: rpcError } = await supabase.rpc('propose_auto_schedule', args())
    setBusy(null)
    if (rpcError) return setError(errText(rpcError))
    setPlan(data as Plan)
    setPlanKey(key)
  }

  async function apply() {
    if (!plan || stale) return
    setBusy('apply')
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('apply_auto_schedule', args())
    setBusy(null)
    if (rpcError) return setError(errText(rpcError))
    onApplied((data as Plan).created ?? 0, start, allPicked ? null : [...(picked ?? [])])
  }

  function choosePreset(p: Preset) {
    setPreset(p)
    if (p !== 'custom') setRange(presetRange(p))
  }

  function toggleBranch(id: string) {
    setPicked((cur) => {
      const n = new Set(cur ?? [])
      if (n.has(id)) n.delete(id)
      else n.add(id)
      return n
    })
  }

  const days = rangeProblem ? 0 : daysBetween(start, end) + 1

  return (
    <div className="space-y-5 pb-4">
      {/* 1 — When */}
      <section className="card rise space-y-4">
        <StepTitle n={1} title="Choose the period" />
        <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Period">
          {(
            [
              ['week', 'Next week'],
              ['next7', 'Next 7 days'],
              ['twoweeks', 'Next 2 weeks'],
              ['custom', 'Custom'],
            ] as [Preset, string][]
          ).map(([p, label]) => (
            <button
              key={p}
              role="radio"
              aria-checked={preset === p}
              onClick={() => choosePreset(p)}
              className={`press rounded-full px-3.5 py-1.5 text-[13px] font-medium ${
                preset === p ? 'bg-ink text-white' : 'bg-surface-alt text-ink hover:bg-border'
              }`}
            >
              {label}
            </button>
          ))}
        </div>
        {preset === 'custom' && (
          <div className="rise flex flex-wrap items-end gap-3">
            <label>
              <span className="label">From</span>
              <input type="date" className="input" min={todayIso()} value={start} onChange={(e) => setRange([e.target.value, end])} />
            </label>
            <label>
              <span className="label">To</span>
              <input type="date" className="input" min={start} max={start ? addDaysIso(start, 30) : undefined} value={end} onChange={(e) => setRange([start, e.target.value])} />
            </label>
          </div>
        )}
        <p className="text-[13px] text-muted" aria-live="polite">
          {rangeProblem ? (
            <span className="text-brand-warning-solid">{rangeProblem}</span>
          ) : (
            <>
              <span className="font-medium text-ink">
                {fmtDayShort(start)} – {fmtDayShort(end)}
              </span>{' '}
              · {days} day{days === 1 ? '' : 's'}
            </>
          )}
        </p>
      </section>

      {/* 2 — Where */}
      <section className="card rise space-y-4" style={{ '--i': 2 } as React.CSSProperties}>
        <div className="flex items-baseline justify-between gap-3">
          <StepTitle n={2} title="Choose branches" />
          {setup && setup.length > 0 && (
            <button className="press text-xs font-medium text-brand-blue hover:underline" onClick={() => setSetupFor(null)}>
              Branch setup
            </button>
          )}
        </div>
        {!setup ? (
          <div className="grid gap-2 sm:grid-cols-2">
            {[0, 1].map((i) => (
              <div key={i} className="h-[72px] animate-pulse rounded-2xl bg-surface-alt" />
            ))}
          </div>
        ) : setup.length === 0 ? (
          <p className="text-sm text-muted">No active branches in this company.</p>
        ) : (
          <div className="grid gap-2 sm:grid-cols-2">
            {setup.map((b) => {
              const on = !!picked?.has(b.location_id)
              const ready = b.hours.length > 0
              const openDays = b.hours.filter((h) => !h.is_closed).length
              return (
                <div
                  key={b.location_id}
                  className={`relative rounded-2xl border p-3.5 transition-[border-color,background-color,box-shadow] duration-200 ${
                    on ? 'border-brand-blue bg-brand-blue-soft/50 shadow-[0_0_0_1px_var(--color-brand-blue)]' : 'border-border bg-surface'
                  }`}
                >
                  <button
                    role="checkbox"
                    aria-checked={on}
                    onClick={() => toggleBranch(b.location_id)}
                    className="press flex w-full items-start gap-3 text-left"
                  >
                    <span
                      className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border transition-colors duration-150 ${
                        on ? 'border-brand-blue bg-brand-blue text-white' : 'border-border bg-surface'
                      }`}
                      aria-hidden="true"
                    >
                      {on && (
                        <svg viewBox="0 0 12 12" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="2">
                          <path d="M2.5 6.2 5 8.5l4.5-5" strokeLinecap="round" strokeLinejoin="round" />
                        </svg>
                      )}
                    </span>
                    <span className="min-w-0">
                      <span className="block text-sm font-medium text-ink">{b.name}</span>
                      <span className={`block text-xs ${ready ? 'text-muted' : 'text-brand-warning-solid'}`}>
                        {ready
                          ? `Open ${openDays} day${openDays === 1 ? '' : 's'} · ${
                              b.needs.length ? `${b.needs.length} staffing need${b.needs.length === 1 ? '' : 's'}` : '1 person default'
                            }`
                          : 'No opening hours yet'}
                      </span>
                    </span>
                  </button>
                  <button
                    onClick={() => setSetupFor(b.location_id)}
                    className={`press absolute right-3 top-3 rounded-full px-2.5 py-1 text-xs font-medium ${
                      ready ? 'text-muted hover:bg-surface-alt hover:text-ink' : 'bg-brand-warning-soft text-brand-warning-solid'
                    }`}
                  >
                    {ready ? 'Edit' : 'Set up'}
                  </button>
                </div>
              )
            })}
          </div>
        )}
        {notReady.length > 0 && (
          <p className="rise rounded-xl bg-brand-warning-soft px-3.5 py-2.5 text-xs text-brand-warning-solid">
            {notReady.map((b) => b.name).join(', ')} {notReady.length === 1 ? 'has' : 'have'} no opening hours — nothing will be planned there.
          </p>
        )}
      </section>

      {/* 3 — Preview */}
      <section className="card rise space-y-4" style={{ '--i': 4 } as React.CSSProperties}>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <StepTitle n={3} title="Preview the plan" />
          <button
            className={`${plan && !stale ? 'btn-secondary' : 'btn-primary'} press`}
            onClick={preview}
            disabled={busy !== null || !!rangeProblem || selected.length === 0}
          >
            {busy === 'preview' ? 'Planning…' : plan ? (stale ? 'Update preview' : 'Run again') : 'Preview plan'}
          </button>
        </div>
        {!plan && busy !== 'preview' && (
          <p className="text-[13px] text-muted">
            Plans draft shifts from opening hours, staffing needs, availability, approved leave and weekly limits (48 h, 6 days).
            Home-branch staff go first; others are borrowed only to fill gaps. Nothing is saved until you create the drafts.
          </p>
        )}
        <ErrorBox msg={error} />
        {!plan && busy === 'preview' && (
          <div className="space-y-2">
            {[0, 1, 2].map((i) => (
              <div key={i} className="h-10 animate-pulse rounded-xl bg-surface-alt" style={{ animationDelay: `${i * 120}ms` }} />
            ))}
          </div>
        )}
        {plan && (
          <div className={stale || busy === 'preview' ? 'stale' : 'fresh'} aria-busy={busy === 'preview'}>
            {stale && busy !== 'preview' && (
              <p className="mb-3 rounded-xl bg-surface-alt px-3.5 py-2.5 text-xs text-ink">
                You changed the period or branches — update the preview to see the new plan.
              </p>
            )}
            <PlanView key={planKey ?? ''} plan={plan} />
          </div>
        )}
      </section>

      {plan && (
        <div className="material material-edge-top sticky bottom-3 z-10 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-border/70 px-4 py-3">
          <p className="min-w-0 text-[13px] text-muted">
            {stale ? (
              'Update the preview before creating shifts.'
            ) : (
              <>
                <span className="font-medium text-ink tabular-nums">
                  {plan.summary.planned} shift{plan.summary.planned === 1 ? '' : 's'} · {plan.summary.planned_hours} h
                </span>{' '}
                saved as drafts — review them in the Week tab, then Publish week.
              </>
            )}
          </p>
          <button className="btn-primary press shrink-0" onClick={apply} disabled={busy !== null || stale || plan.summary.planned === 0}>
            {busy === 'apply' ? 'Creating…' : `Create ${plan.summary.planned} draft${plan.summary.planned === 1 ? '' : 's'}`}
          </button>
        </div>
      )}

      {setupFor !== undefined && setup && (
        <BranchSetupSheet
          setup={setup}
          initialLocationId={setupFor ?? undefined}
          positions={positions}
          onClose={() => setSetupFor(undefined)}
          onSaved={(msg) => {
            onNotice(msg)
            loadSetup()
          }}
        />
      )}
    </div>
  )
}

function StepTitle({ n, title }: { n: number; title: string }) {
  return (
    <h2 className="flex items-center gap-2.5 text-[15px] font-semibold tracking-[-0.01em] text-ink">
      <span className="flex h-6 w-6 items-center justify-center rounded-full bg-brand-primary-soft text-xs font-semibold tabular-nums text-brand-primary">
        {n}
      </span>
      {title}
    </h2>
  )
}

function Stat({ label, value, tone, i }: { label: string; value: string | number; tone?: 'warn'; i: number }) {
  return (
    <div className="rise rounded-2xl bg-surface-alt px-4 py-3" style={{ '--i': i } as React.CSSProperties}>
      <span className="block text-xs text-muted">{label}</span>
      <span
        className={`mt-0.5 block text-2xl font-semibold leading-tight tracking-[-0.02em] tabular-nums ${
          tone === 'warn' ? 'text-brand-warning-solid' : 'text-ink'
        }`}
      >
        {value}
      </span>
    </div>
  )
}

// Day-by-day timeline: one row per branch, bars on a shared hour axis so the
// same time lines up across every day.
function PlanView({ plan }: { plan: Plan }) {
  const [onlyGaps, setOnlyGaps] = useState(false)

  const span = (s: { start_time: string; end_time: string }) => {
    const a = toMin(s.start_time)
    let b = toMin(s.end_time)
    if (b <= a) b += 1440
    return [a, b] as const
  }

  const axis = useMemo(() => {
    const all = [...plan.shifts, ...plan.unfilled].map(span)
    if (!all.length) return { from: 6 * 60, to: 22 * 60 }
    const from = Math.floor(Math.min(...all.map((x) => x[0])) / 60) * 60
    const to = Math.ceil(Math.max(...all.map((x) => x[1])) / 60) * 60
    return { from, to: Math.max(to, from + 240) }
  }, [plan])

  const days = useMemo(() => {
    const m = new Map<string, { shifts: PlanShift[]; gaps: PlanGap[] }>()
    const at = (d: string) => {
      if (!m.has(d)) m.set(d, { shifts: [], gaps: [] })
      return m.get(d)!
    }
    plan.shifts.forEach((s) => at(s.shift_date).shifts.push(s))
    plan.unfilled.forEach((g) => at(g.shift_date).gaps.push(g))
    return [...m.entries()].sort(([a], [b]) => a.localeCompare(b))
  }, [plan])

  const visible = onlyGaps ? days.filter(([, d]) => d.gaps.length > 0) : days
  const pct = (min: number) => ((min - axis.from) / (axis.to - axis.from)) * 100
  const ticks: number[] = []
  for (let t = axis.from; t <= axis.to; t += (axis.to - axis.from) / 60 > 12 ? 180 : 120) ticks.push(t)
  const tickLabel = (t: number) => String(Math.floor(t / 60) % 24).padStart(2, '0')

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4" aria-live="polite">
        <Stat i={0} label="Shifts planned" value={plan.summary.planned} />
        <Stat i={1} label="Hours" value={plan.summary.planned_hours} />
        <Stat i={2} label="From another branch" value={plan.summary.cross_branch} />
        <Stat i={3} label="Unfilled" value={plan.summary.unfilled} tone={plan.summary.unfilled > 0 ? 'warn' : undefined} />
      </div>

      {plan.warnings.length > 0 && (
        <ul className="space-y-1.5">
          {plan.warnings.map((w, i) => (
            <li key={i} className="rise rounded-xl bg-brand-warning-soft px-3.5 py-2.5 text-xs text-brand-warning-solid" style={{ '--i': 4 + i } as React.CSSProperties}>
              {w}
            </li>
          ))}
        </ul>
      )}

      {days.length === 0 ? (
        <p className="py-8 text-center text-sm text-muted">Nothing to plan for this period — check opening hours in Branch setup.</p>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-[11px] text-muted">
            <Legend className="bg-brand-blue-soft ring-1 ring-brand-blue/30" label="Planned" />
            <Legend className="bg-brand-info-soft ring-1 ring-brand-info/40" label="From another branch" />
            <Legend className="border border-dashed border-brand-warning bg-brand-warning-soft" label="Unfilled" />
            {plan.summary.unfilled > 0 && (
              <label className="ml-auto flex items-center gap-1.5 text-xs text-ink">
                <input type="checkbox" checked={onlyGaps} onChange={(e) => setOnlyGaps(e.target.checked)} />
                Only days with gaps
              </label>
            )}
          </div>

          <div className="overflow-x-auto">
            <div className="space-y-3 sm:min-w-[560px]">
              <div className="flex pl-[13px] pr-[13px] text-[10px] tabular-nums text-muted sm:pl-[calc(9.5rem+13px)]" aria-hidden="true">
                <div className="relative h-4 flex-1">
                  {ticks.map((t) => (
                    <span key={t} className="absolute -translate-x-1/2" style={{ left: `${pct(t)}%` }}>
                      {tickLabel(t)}
                    </span>
                  ))}
                </div>
              </div>
              {visible.map(([date, d], di) => (
                <DayRow key={date} date={date} day={d} di={di} pct={pct} ticks={ticks} span={span} />
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  )
}

function Legend({ className, label }: { className: string; label: string }) {
  return (
    <span className="flex items-center gap-1.5">
      <span className={`inline-block h-2.5 w-5 rounded-[4px] ${className}`} />
      {label}
    </span>
  )
}

function DayRow({
  date,
  day,
  di,
  pct,
  ticks,
  span,
}: {
  date: string
  day: { shifts: PlanShift[]; gaps: PlanGap[] }
  di: number
  pct: (m: number) => number
  ticks: number[]
  span: (s: { start_time: string; end_time: string }) => readonly [number, number]
}) {
  const branches = [...new Set([...day.shifts.map((s) => s.location), ...day.gaps.map((g) => g.location)])].sort()
  return (
    <div className="rise rounded-2xl border border-border p-3" style={{ '--i': Math.min(di, 10) + 4 } as React.CSSProperties}>
      <div className="mb-2 flex items-baseline justify-between">
        <span className="text-[13px] font-semibold text-ink">{fmtDayShort(date)}</span>
        <span className="text-[11px] tabular-nums text-muted">
          {day.shifts.length} shift{day.shifts.length === 1 ? '' : 's'}
          {day.gaps.length > 0 && <span className="text-brand-warning-solid"> · {day.gaps.length} unfilled</span>}
        </span>
      </div>
      <div className="space-y-2">
        {branches.map((loc) => {
          const rows: ({ kind: 'shift'; s: PlanShift } | { kind: 'gap'; g: PlanGap })[] = [
            ...day.shifts.filter((s) => s.location === loc).map((s) => ({ kind: 'shift' as const, s })),
            ...day.gaps.filter((g) => g.location === loc).map((g) => ({ kind: 'gap' as const, g })),
          ]
          return (
            <div key={loc} className="flex flex-col gap-1 sm:flex-row sm:gap-2">
              <span className="shrink-0 truncate text-xs text-muted sm:w-36 sm:pt-1.5" title={loc}>
                {loc}
              </span>
              <div className="relative flex-1 space-y-1 rounded-lg bg-surface-alt/70 py-1">
                {ticks.map((t) => (
                  <span key={t} className="pointer-events-none absolute bottom-0 top-0 w-px bg-border/70" style={{ left: `${pct(t)}%` }} aria-hidden="true" />
                ))}
                {rows.map((r, i) => {
                  const src = r.kind === 'shift' ? r.s : r.g
                  const [a, b] = span(src)
                  const style = { left: `${pct(a)}%`, width: `${Math.max(pct(b) - pct(a), 3)}%`, '--i': i } as React.CSSProperties
                  const time = `${fmtTime(src.start_time)}–${fmtTime(src.end_time)}`
                  if (r.kind === 'gap') {
                    return (
                      <div key={`g${i}`} className="relative h-7">
                        <div
                          className="bar-grow absolute inset-y-0 flex items-center overflow-hidden rounded-md border border-dashed border-brand-warning bg-brand-warning-soft px-2 text-[11px] font-medium text-brand-warning-solid"
                          style={style}
                          title={`Unfilled ${time}${r.g.role ? ` · ${r.g.role}` : ''}`}
                        >
                          <span className="truncate">Unfilled{r.g.role ? ` · ${r.g.role}` : ''}</span>
                        </div>
                      </div>
                    )
                  }
                  const s = r.s
                  return (
                    <div key={`s${i}`} className="relative h-7">
                      <div
                        className={`bar-grow absolute inset-y-0 flex items-center gap-1.5 overflow-hidden rounded-md px-2 text-[11px] ${
                          s.cross_branch ? 'bg-brand-info-soft text-brand-info-text ring-1 ring-brand-info/40' : 'bg-brand-blue-soft text-brand-blue-text ring-1 ring-brand-blue/25'
                        }`}
                        style={style}
                        title={`${s.employee} · ${time}${s.break_minutes ? ` · ${s.break_minutes}m break` : ''}${
                          s.cross_branch ? ` · moved from ${s.home_location ?? 'no home branch'}` : ''
                        }`}
                      >
                        <span className="truncate font-medium">{s.employee.split(' ')[0]}</span>
                        <span className="truncate tabular-nums opacity-80">{time}</span>
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Work-pattern warnings for manual shifts (advisory — never blocks saving)
// ---------------------------------------------------------------------------

export function WorkPatternWarnings({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null
  return (
    <div role="status" className="rise space-y-1 rounded-xl bg-brand-warning-soft px-3.5 py-2.5 text-xs text-brand-warning-solid">
      {warnings.map((w, i) => (
        <p key={i}>{w}</p>
      ))}
      <p className="opacity-80">You can still save — this is a heads-up, not a block.</p>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Find cover (P0-2): ranked eligible people for one shift → assign
// ---------------------------------------------------------------------------

interface CoverCandidate {
  employee_id: string
  name: string
  home_location: string | null
  position: string | null
  home_branch: boolean
  hours_this_week: number
  days_this_week: number
}
interface CoverResult {
  shift: {
    id: string
    shift_date: string
    start_time: string
    end_time: string
    location_id: string
    location: string | null
    position: string | null
    employee_id: string | null
    is_published: boolean
    status: string
  }
  candidates: CoverCandidate[]
  not_eligible: { employee_id: string; name: string; reason: string }[]
}

export interface CoverShift {
  id: string
  shift_date: string
  start_time: string
  end_time: string
  break_minutes: number
  location_id: string
  employee_id: string | null
  is_published: boolean
  currentName: string | null
}

export function FindCoverSheet({
  shift,
  onClose,
  onAssigned,
}: {
  shift: CoverShift
  onClose: () => void
  onAssigned: (message: string) => void
}) {
  const [data, setData] = useState<CoverResult | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [picked, setPicked] = useState<CoverCandidate | null>(null)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)

  // Every change to a published shift goes through adjust_published_shift with a
  // reason (the database refuses direct edits, P0-6); drafts are assigned directly.
  const needsReason = shift.is_published

  useEffect(() => {
    supabase.rpc('suggest_shift_cover', { p_shift_id: shift.id }).then(({ data: d, error: e }) => {
      if (e) setError(errText(e))
      else setData(d as CoverResult)
    })
  }, [shift.id])

  async function assign() {
    if (!picked) return
    if (needsReason && !reason.trim()) return setError('Add a reason for the change.')
    setBusy(true)
    setError(null)
    const res = needsReason
      ? await supabase.rpc('adjust_published_shift', {
          p_shift_id: shift.id,
          p_reason: reason.trim(),
          p_shift_date: shift.shift_date,
          p_start_time: shift.start_time.slice(0, 5),
          p_end_time: shift.end_time.slice(0, 5),
          p_break_minutes: shift.break_minutes,
          p_employee_id: picked.employee_id,
          p_location_id: shift.location_id,
        })
      : await supabase.from('shifts').update({ employee_id: picked.employee_id, status: 'assigned' }).eq('id', shift.id)
    setBusy(false)
    if (res.error) return setError(errText(res.error))
    onAssigned(`${picked.name} now covers ${fmtDayShort(shift.shift_date)} ${fmtTime(shift.start_time)}–${fmtTime(shift.end_time)}.`)
  }

  const s = data?.shift
  return (
    <Sheet
      title="Find cover"
      subtitle={
        s
          ? `${fmtDayShort(s.shift_date)} · ${fmtTime(s.start_time)}–${fmtTime(s.end_time)} · ${s.location ?? 'Branch'}${s.position ? ` · ${s.position}` : ''}${
              shift.currentName ? ` · now ${shift.currentName}` : ' · unassigned'
            }`
          : 'Checking who can work this shift…'
      }
      onClose={onClose}
      footer={
        picked ? (
          <div className="space-y-3">
            {needsReason && (
              <label className="block">
                <span className="label">Reason (kept in the shift history)</span>
                <input
                  className="input"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder={shift.currentName ? `e.g. Cover for ${shift.currentName}` : 'e.g. Cover'}
                />
              </label>
            )}
            <div className="flex items-center justify-between gap-3">
              <p className="min-w-0 text-[13px] text-muted">
                Assign <span className="font-medium text-ink">{picked.name}</span>
                {!picked.home_branch && picked.home_location ? ` (from ${picked.home_location})` : ''}
              </p>
              <button className="btn-primary press shrink-0" onClick={assign} disabled={busy || (needsReason && !reason.trim())}>
                {busy ? 'Assigning…' : 'Assign'}
              </button>
            </div>
          </div>
        ) : undefined
      }
    >
      <ErrorBox msg={error} />
      {!data && !error && (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-14 animate-pulse rounded-xl bg-surface-alt" />
          ))}
        </div>
      )}
      {data && (
        <div className="space-y-5">
          <p className="text-xs text-muted">
            Only people who pass every rule are listed: right role, not on leave or a day off, available, no overlapping shift, and within 48 hours and
            their working days that week. Their own branch comes first, then the fewest hours.
          </p>
          {data.candidates.length === 0 ? (
            <p className="rounded-xl bg-brand-warning-soft px-3.5 py-2.5 text-sm text-brand-warning-solid">
              Nobody is eligible for this shift. See the reasons below, or change the shift.
            </p>
          ) : (
            <ul className="space-y-2" role="radiogroup" aria-label="Choose who covers">
              {data.candidates.map((c, i) => {
                const on = picked?.employee_id === c.employee_id
                return (
                  <li key={c.employee_id} className="rise" style={{ '--i': Math.min(i, 10) } as React.CSSProperties}>
                    <button
                      role="radio"
                      aria-checked={on}
                      onClick={() => setPicked(c)}
                      className={`press flex w-full items-center justify-between gap-3 rounded-2xl border px-4 py-3 text-left transition-[border-color,background-color] duration-200 ${
                        on ? 'border-brand-blue bg-brand-blue-soft/50' : 'border-border hover:bg-surface-alt'
                      }`}
                    >
                      <span className="min-w-0">
                        <span className="block text-sm font-medium text-ink">
                          {c.name}
                          {!c.home_branch && (
                            <span className="ml-2 rounded-full bg-brand-info-soft px-2 py-0.5 text-[11px] font-medium text-brand-info-text">
                              {c.home_location ?? 'Other branch'}
                            </span>
                          )}
                        </span>
                        <span className="block text-xs text-muted">{c.position ?? 'No role set'}</span>
                      </span>
                      <span className="shrink-0 text-right text-xs tabular-nums text-muted">
                        {c.hours_this_week} h · {c.days_this_week} day{c.days_this_week === 1 ? '' : 's'}
                        <span className="block">this week</span>
                      </span>
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
          {data.not_eligible.length > 0 && (
            <details className="rounded-2xl border border-border px-4 py-3">
              <summary className="cursor-pointer text-[13px] font-medium text-ink">
                Not eligible ({data.not_eligible.length})
              </summary>
              <ul className="mt-2 space-y-1.5 text-xs">
                {data.not_eligible.map((n) => (
                  <li key={n.employee_id} className="flex justify-between gap-3">
                    <span className="text-ink">{n.name}</span>
                    <span className="text-right text-muted">{n.reason}</span>
                  </li>
                ))}
              </ul>
            </details>
          )}
        </div>
      )}
    </Sheet>
  )
}

// ---------------------------------------------------------------------------
// Owner switch: may staff pick up open shifts / swaps at other branches? (P0-2)
// ---------------------------------------------------------------------------

export function CrossBranchClaimsToggle({ entityId, onError }: { entityId: string; onError: (msg: string) => void }) {
  const [enabled, setEnabled] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    supabase
      .from('app_settings')
      .select('value')
      .eq('key', `cross_outlet_claims:${entityId}`)
      .maybeSingle()
      .then(({ data }) => setEnabled(!!(data as { value: boolean } | null)?.value))
  }, [entityId])

  async function toggle() {
    const next = !enabled
    setBusy(true)
    const { error } = await supabase.rpc('set_cross_outlet_claims', { p_entity_id: entityId, p_enabled: next })
    setBusy(false)
    if (error) return onError(errText(error))
    setEnabled(next)
  }

  if (enabled === null) return null
  return (
    <label className="flex items-center gap-2 text-xs text-muted">
      <input type="checkbox" checked={enabled} disabled={busy} onChange={toggle} className="h-4 w-4 accent-[var(--color-brand-blue)]" />
      Staff can pick up open shifts and swaps at other branches
    </label>
  )
}

// ---------------------------------------------------------------------------
// Admin switch: shift swaps on/off for the company (hides swaps from staff)
// ---------------------------------------------------------------------------

export function ShiftSwapsToggle({
  entityId,
  onChanged,
  onError,
}: {
  entityId: string
  onChanged?: (enabled: boolean) => void
  onError: (msg: string) => void
}) {
  const [enabled, setEnabled] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    supabase.rpc('shift_swaps_enabled', { p_entity_id: entityId }).then(({ data, error }) => {
      const v = error ? true : data !== false
      setEnabled(v)
      onChanged?.(v)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entityId])

  async function toggle() {
    const next = !enabled
    setBusy(true)
    const { error } = await supabase.rpc('set_shift_swaps_enabled', { p_entity_id: entityId, p_enabled: next })
    setBusy(false)
    if (error) return onError(errText(error))
    setEnabled(next)
    onChanged?.(next)
  }

  if (enabled === null) return null
  return (
    <label className="flex items-center gap-2 text-xs text-muted">
      <input type="checkbox" checked={enabled} disabled={busy} onChange={toggle} className="h-4 w-4 accent-[var(--color-brand-blue)]" />
      Shift swaps for staff
    </label>
  )
}
