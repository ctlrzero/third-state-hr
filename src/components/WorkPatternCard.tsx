import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { fmtTime } from '../lib/format'
import { confirmDialog } from '../lib/confirm'

const DOW_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const DOW_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
// Order days are offered as default days off: weekend first (Fri, Sat), then outward.
const DEFAULT_OFF_ORDER = [5, 6, 4, 0, 3, 1, 2]

export interface WorkPattern {
  employee_id: string
  days_per_week: number
  days_off_mode: 'fixed' | 'flexible'
  fixed_days_off: number[]
}

interface AvailabilityRow {
  day_of_week: number
  is_available: boolean
  start_time: string | null
  end_time: string | null
}

const errText = (err: { message: string }) => err.message.replace(/^ERROR:\s*/i, '')

function joinDays(days: number[]) {
  const names = [...days].sort((a, b) => a - b).map((d) => DOW_LONG[d])
  if (names.length <= 1) return names.join('')
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`
}

function describePattern(p: WorkPattern | null) {
  if (!p) return 'No pattern set — the scheduler allows up to 6 days a week, any day.'
  const days = `Works ${p.days_per_week} day${p.days_per_week === 1 ? '' : 's'} a week`
  const off = 7 - p.days_per_week
  if (p.days_off_mode === 'flexible') return `${days} · ${off} day${off === 1 ? '' : 's'} off, any day`
  return `${days} · ${joinDays(p.fixed_days_off)} off`
}

function defaultDaysOff(daysPerWeek: number) {
  return DEFAULT_OFF_ORDER.slice(0, 7 - daysPerWeek).sort((a, b) => a - b)
}

export default function WorkPatternCard({ employeeId, canEdit }: { employeeId: string; canEdit: boolean }) {
  const [pattern, setPattern] = useState<WorkPattern | null | undefined>(undefined)
  const [availability, setAvailability] = useState<AvailabilityRow[]>([])
  const [editing, setEditing] = useState(false)
  const [days, setDays] = useState(6)
  const [mode, setMode] = useState<'fixed' | 'flexible'>('flexible')
  const [daysOff, setDaysOff] = useState<number[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  const load = useCallback(async () => {
    const [p, a] = await Promise.all([
      supabase.from('employee_work_patterns').select('employee_id, days_per_week, days_off_mode, fixed_days_off').eq('employee_id', employeeId).maybeSingle(),
      supabase.from('employee_availability').select('day_of_week, is_available, start_time, end_time').eq('employee_id', employeeId).order('day_of_week'),
    ])
    if (p.error) setError(p.error.message)
    setPattern((p.data as WorkPattern | null) ?? null)
    setAvailability((a.data ?? []) as AvailabilityRow[])
  }, [employeeId])

  useEffect(() => {
    load()
  }, [load])

  function startEdit() {
    const p = pattern ?? null
    setDays(p?.days_per_week ?? 6)
    setMode(p?.days_off_mode ?? 'flexible')
    setDaysOff(p?.days_off_mode === 'fixed' ? p.fixed_days_off : defaultDaysOff(p?.days_per_week ?? 6))
    setError(null)
    setSaved(false)
    setEditing(true)
  }

  function chooseDays(n: number) {
    setDays(n)
    setDaysOff(defaultDaysOff(n))
  }

  function toggleDayOff(d: number) {
    setDaysOff((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d].sort((a, b) => a - b)))
  }

  const needOff = 7 - days
  const problem = useMemo(() => {
    if (mode !== 'fixed') return null
    if (daysOff.length === needOff) return null
    return `Pick exactly ${needOff} day${needOff === 1 ? '' : 's'} off (${daysOff.length} selected).`
  }, [mode, daysOff, needOff])

  async function save() {
    if (problem) return setError(problem)
    setBusy(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('set_employee_work_pattern', {
      p_employee_id: employeeId,
      p_days_per_week: days,
      p_days_off_mode: mode,
      p_fixed_days_off: mode === 'fixed' ? daysOff : [],
    })
    setBusy(false)
    if (rpcError) return setError(errText(rpcError))
    setEditing(false)
    setSaved(true)
    load()
  }

  async function clear() {
    if (!(await confirmDialog('Remove this work pattern? The scheduler will go back to allowing up to 6 days a week, any day.'))) return
    setBusy(true)
    const { error: rpcError } = await supabase.rpc('clear_employee_work_pattern', { p_employee_id: employeeId })
    setBusy(false)
    if (rpcError) return setError(errText(rpcError))
    setEditing(false)
    load()
  }

  const availByDay = new Map(availability.map((a) => [a.day_of_week, a]))

  return (
    <section className="card space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold text-ink">Work pattern</h2>
          <p className="mt-0.5 text-sm text-muted" aria-live="polite">
            {pattern === undefined ? 'Loading…' : describePattern(pattern)}
          </p>
          {saved && !editing && <p className="mt-1 text-xs text-brand-action-text">Saved. The auto-scheduler and shift forms now use this pattern.</p>}
        </div>
        {canEdit && !editing && pattern !== undefined && (
          <button className="btn-secondary press shrink-0" onClick={startEdit}>
            {pattern ? 'Edit' : 'Set pattern'}
          </button>
        )}
      </div>

      {editing && (
        <div className="rise space-y-5 rounded-2xl border border-border p-4">
          <div>
            <span className="label">Working days per week</span>
            <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Working days per week">
              {[1, 2, 3, 4, 5, 6].map((n) => (
                <button
                  key={n}
                  role="radio"
                  aria-checked={days === n}
                  onClick={() => chooseDays(n)}
                  className={`press h-10 w-10 rounded-full text-sm font-semibold tabular-nums ${
                    days === n ? 'bg-ink text-white' : 'bg-surface-alt text-ink hover:bg-border'
                  }`}
                >
                  {n}
                </button>
              ))}
            </div>
            <p className="mt-1.5 text-xs text-muted">
              {needOff} day{needOff === 1 ? '' : 's'} off each week (Monday–Sunday).
            </p>
          </div>

          <div>
            <span className="label">Days off</span>
            <div className="grid gap-2 sm:grid-cols-2" role="radiogroup" aria-label="Days off">
              {(
                [
                  ['flexible', 'Flexible', 'Any day — the scheduler decides which each week.'],
                  ['fixed', 'Fixed days', 'Always the same days, e.g. the weekend.'],
                ] as const
              ).map(([m, title, sub]) => (
                <button
                  key={m}
                  role="radio"
                  aria-checked={mode === m}
                  onClick={() => setMode(m)}
                  className={`press rounded-2xl border p-3 text-left transition-[border-color,background-color] duration-200 ${
                    mode === m ? 'border-brand-blue bg-brand-blue-soft/50' : 'border-border hover:bg-surface-alt'
                  }`}
                >
                  <span className="block text-sm font-medium text-ink">{title}</span>
                  <span className="block text-xs text-muted">{sub}</span>
                </button>
              ))}
            </div>
          </div>

          {mode === 'fixed' && (
            <div className="rise">
              <span className="label">
                Which {needOff === 1 ? 'day' : `${needOff} days`}?
              </span>
              <div className="flex flex-wrap gap-2">
                {DOW_SHORT.map((label, d) => {
                  const on = daysOff.includes(d)
                  return (
                    <button
                      key={d}
                      aria-pressed={on}
                      aria-label={`${DOW_LONG[d]} off`}
                      onClick={() => toggleDayOff(d)}
                      className={`press min-w-12 rounded-full px-3 py-2 text-[13px] font-medium ${
                        on ? 'bg-brand-blue text-white' : 'bg-surface-alt text-ink hover:bg-border'
                      }`}
                    >
                      {label}
                    </button>
                  )
                })}
              </div>
              <p className={`mt-1.5 text-xs ${problem ? 'text-brand-warning-solid' : 'text-muted'}`}>
                {problem ?? `Off every ${joinDays(daysOff)}.`}
              </p>
            </div>
          )}

          {error && <p role="alert" className="rounded-xl bg-brand-risk-soft px-3.5 py-2.5 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex flex-wrap items-center gap-2">
            {pattern && (
              <button className="press mr-auto text-xs font-medium text-brand-risk hover:underline" onClick={clear} disabled={busy}>
                Remove pattern
              </button>
            )}
            <button className="btn-secondary press ml-auto" onClick={() => setEditing(false)} disabled={busy}>
              Cancel
            </button>
            <button className="btn-primary press" onClick={save} disabled={busy || !!problem}>
              {busy ? 'Saving…' : 'Save pattern'}
            </button>
          </div>
        </div>
      )}

      <div>
        <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Availability</h3>
        {availability.length === 0 ? (
          <p className="text-sm text-muted">None on file — treated as available any day and any time.</p>
        ) : (
          <ul className="grid grid-cols-2 gap-1.5 sm:grid-cols-4">
            {DOW_SHORT.map((label, d) => {
              const a = availByDay.get(d)
              const fixedOff = pattern?.days_off_mode === 'fixed' && pattern.fixed_days_off.includes(d)
              return (
                <li key={d} className={`rounded-lg px-3 py-2 text-xs ${a?.is_available && !fixedOff ? 'bg-surface-alt text-ink' : 'bg-surface-alt/50 text-muted'}`}>
                  <span className="font-medium">{label}</span>{' '}
                  {fixedOff
                    ? 'Day off'
                    : !a
                      ? 'Not set'
                      : !a.is_available
                        ? 'Unavailable'
                        : a.start_time || a.end_time
                          ? `${a.start_time ? fmtTime(a.start_time) : 'Any'}–${a.end_time ? fmtTime(a.end_time) : 'Any'}`
                          : 'Any time'}
                </li>
              )
            })}
          </ul>
        )}
      </div>
    </section>
  )
}
