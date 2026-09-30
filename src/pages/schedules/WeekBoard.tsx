import type { ReactNode } from 'react'
import { fmtDayShort, fmtTime, todayDubai } from '../../lib/format'
import { Sheet } from '../../components/Sheet'
import type { Shift } from '../../types/db'
import { isoAddDays, shiftKind, type ShiftKind } from './week'

const KIND_LABEL: Record<ShiftKind, string> = { draft: 'Draft', published: 'Published', adjusted: 'Adjusted', cancelled: 'Cancelled' }
const KIND_PILL: Record<ShiftKind, string> = {
  draft: 'border border-dashed border-muted/60 bg-surface text-muted',
  published: 'bg-brand-blue-soft text-brand-blue-text',
  adjusted: 'bg-brand-info-soft text-brand-info-text',
  cancelled: 'bg-surface-alt text-muted line-through',
}
const KIND_CHIP: Record<ShiftKind, string> = {
  draft: 'border border-dashed border-border bg-surface',
  published: 'border border-brand-blue/25 bg-brand-blue-soft/60',
  adjusted: 'border border-brand-info/30 bg-brand-info-soft/70',
  cancelled: 'border border-border bg-surface-alt/60 opacity-70',
}

export function ShiftStatusPill({ kind }: { kind: ShiftKind }) {
  return (
    <span className={`inline-flex items-center rounded-full px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide ${KIND_PILL[kind]}`}>
      {KIND_LABEL[kind]}
    </span>
  )
}

export function StatusLegend() {
  return (
    <div className="flex flex-wrap items-center gap-2 text-[11px] text-muted" aria-label="Status key">
      {(['draft', 'published', 'adjusted', 'cancelled'] as ShiftKind[]).map((k) => (
        <ShiftStatusPill key={k} kind={k} />
      ))}
      <span className="rounded-full bg-brand-risk-soft px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide text-brand-risk-text">On leave</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Board
// ---------------------------------------------------------------------------

export interface BoardPerson {
  id: string
  name: string
  homeLocationId: string | null
}

interface BoardProps {
  weekStart: string
  shifts: Shift[]
  people: BoardPerson[]
  adjustedIds: Set<string>
  onLeave: Set<string>
  locationNames: Map<string, string>
  showBranch: boolean
  focusId: string | null
  onOpen: (s: Shift) => void
}

function Chip({
  s,
  kind,
  leave,
  branch,
  who,
  focused,
  onOpen,
}: {
  s: Shift
  kind: ShiftKind
  leave: boolean
  branch: string | null
  who?: string
  focused: boolean
  onOpen: () => void
}) {
  return (
    <button
      id={`shift-${s.id}`}
      onClick={onOpen}
      className={`press block w-full rounded-lg px-2 py-1.5 text-left text-xs transition-shadow hover:shadow-card ${KIND_CHIP[kind]} ${
        leave ? 'ring-2 ring-brand-risk/50' : ''
      } ${focused ? 'outline outline-2 outline-offset-1 outline-brand-blue' : ''}`}
      aria-label={`${who ? who + ', ' : ''}${fmtDayShort(s.shift_date)} ${fmtTime(s.start_time)} to ${fmtTime(s.end_time)}, ${KIND_LABEL[kind]}${leave ? ', on leave' : ''}`}
    >
      {who && <span className="block truncate font-medium text-ink">{who}</span>}
      <span className={`block font-medium tabular-nums ${kind === 'cancelled' ? 'text-muted line-through' : 'text-ink'}`}>
        {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
      </span>
      <span className="mt-0.5 flex flex-wrap items-center gap-1">
        <ShiftStatusPill kind={kind} />
        {leave && (
          <span className="rounded-full bg-brand-risk-soft px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide text-brand-risk-text">
            On leave
          </span>
        )}
      </span>
      {branch && <span className="mt-0.5 block truncate text-[11px] text-muted">{branch}</span>}
    </button>
  )
}

export function WeekBoard({ weekStart, shifts, people, adjustedIds, onLeave, locationNames, showBranch, focusId, onOpen }: BoardProps) {
  const days = Array.from({ length: 7 }, (_, i) => isoAddDays(weekStart, i))
  const today = todayDubai()
  const byCell = new Map<string, Shift[]>()
  for (const s of shifts) {
    const key = `${s.employee_id ?? 'open'}|${s.shift_date}`
    byCell.set(key, [...(byCell.get(key) ?? []), s].sort((a, b) => a.start_time.localeCompare(b.start_time)))
  }
  const openCount = shifts.filter((s) => !s.employee_id).length
  const rows: { key: string; label: ReactNode; home: string | null }[] = [
    ...(openCount > 0 || shifts.length === 0
      ? [{ key: 'open', label: <span className="font-medium text-brand-warning-solid">Open shifts</span>, home: null }]
      : []),
    ...people.map((p) => ({ key: p.id, label: <span className="font-medium text-ink">{p.name}</span>, home: p.homeLocationId })),
  ]
  const branchLabel = (s: Shift, home: string | null) =>
    showBranch || (home && s.location_id !== home) ? (locationNames.get(s.location_id) ?? null) : null

  return (
    <>
      {/* Desktop / tablet: people × days */}
      <div className="hidden overflow-x-auto rounded-[14px] border border-border bg-surface shadow-card md:block">
        <table className="w-full min-w-[860px] table-fixed border-collapse text-left">
          <thead>
            <tr className="border-b border-border bg-surface-alt">
              <th className="sticky left-0 z-[1] w-44 bg-surface-alt px-3 py-2.5 text-xs font-medium uppercase tracking-wide text-muted">Person</th>
              {days.map((d) => (
                <th key={d} className={`px-2 py-2.5 text-xs font-medium ${d === today ? 'text-brand-blue' : 'text-muted'}`}>
                  <span className={d === today ? 'rounded-full bg-brand-blue-soft px-2 py-0.5' : ''}>{fmtDayShort(d)}</span>
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((r) => (
              <tr key={r.key} className="align-top">
                <th scope="row" className="sticky left-0 z-[1] truncate bg-surface px-3 py-2 text-sm font-normal">
                  {r.label}
                </th>
                {days.map((d) => {
                  const cell = byCell.get(`${r.key}|${d}`) ?? []
                  return (
                    <td key={d} className={`px-1.5 py-1.5 ${d === today ? 'bg-brand-blue-soft/20' : ''}`}>
                      <div className="space-y-1">
                        {cell.map((s) => (
                          <Chip
                            key={s.id}
                            s={s}
                            kind={shiftKind(s, adjustedIds)}
                            leave={!!s.employee_id && s.status !== 'cancelled' && onLeave.has(`${s.employee_id}|${s.shift_date}`)}
                            branch={branchLabel(s, r.home)}
                            focused={focusId === s.id}
                            onOpen={() => onOpen(s)}
                          />
                        ))}
                      </div>
                    </td>
                  )
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Phone: one card per day */}
      <div className="space-y-3 md:hidden">
        {days.map((d) => {
          const dayShifts = shifts
            .filter((s) => s.shift_date === d)
            .sort((a, b) => a.start_time.localeCompare(b.start_time))
          const live = dayShifts.filter((s) => s.status !== 'cancelled').length
          return (
            <section key={d} className={`rounded-[14px] border bg-surface p-3 shadow-card ${d === today ? 'border-brand-blue/40' : 'border-border'}`}>
              <h3 className="mb-2 flex items-baseline justify-between text-sm font-semibold text-ink">
                <span>
                  {fmtDayShort(d)}
                  {d === today && <span className="ml-2 text-xs font-medium text-brand-blue">Today</span>}
                </span>
                <span className="text-xs font-normal text-muted">
                  {live} shift{live === 1 ? '' : 's'}
                </span>
              </h3>
              {dayShifts.length === 0 ? (
                <p className="text-xs text-muted">No shifts.</p>
              ) : (
                <div className="grid grid-cols-1 gap-1.5 min-[380px]:grid-cols-2">
                  {dayShifts.map((s) => {
                    const person = people.find((p) => p.id === s.employee_id)
                    return (
                      <Chip
                        key={s.id}
                        s={s}
                        kind={shiftKind(s, adjustedIds)}
                        leave={!!s.employee_id && s.status !== 'cancelled' && onLeave.has(`${s.employee_id}|${s.shift_date}`)}
                        branch={branchLabel(s, person?.homeLocationId ?? null)}
                        who={s.employee_id ? (person?.name ?? 'Unknown') : 'Open shift'}
                        focused={focusId === s.id}
                        onOpen={() => onOpen(s)}
                      />
                    )
                  })}
                </div>
              )}
            </section>
          )
        })}
      </div>
    </>
  )
}

// ---------------------------------------------------------------------------
// Shift actions (opened by tapping a shift)
// ---------------------------------------------------------------------------

export interface ShiftActionHandlers {
  onEdit?: () => void
  onCover?: () => void
  onHistory?: () => void
  onCancel?: () => void
  onDelete?: () => void
}

export function ShiftActionsSheet({
  shift,
  kind,
  personName,
  branchName,
  onLeave,
  onClose,
  actions,
}: {
  shift: Shift
  kind: ShiftKind
  personName: string
  branchName: string
  onLeave: boolean
  onClose: () => void
  actions: ShiftActionHandlers
}) {
  const btn = 'press w-full rounded-xl border border-border px-4 py-3 text-left text-sm font-medium hover:bg-surface-alt'
  return (
    <Sheet
      title={personName}
      subtitle={`${fmtDayShort(shift.shift_date)} · ${fmtTime(shift.start_time)}–${fmtTime(shift.end_time)} · ${branchName}`}
      onClose={onClose}
    >
      <div className="space-y-5">
        <div className="flex flex-wrap items-center gap-2">
          <ShiftStatusPill kind={kind} />
          {onLeave && (
            <span className="rounded-full bg-brand-risk-soft px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide text-brand-risk-text">
              On approved leave
            </span>
          )}
        </div>
        <dl className="grid grid-cols-2 gap-3 text-sm">
          <div>
            <dt className="text-xs text-muted">Role</dt>
            <dd className="text-ink">{shift.positions?.title ?? 'Any role'}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted">Break</dt>
            <dd className="text-ink">{shift.break_minutes > 0 ? `${shift.break_minutes} min` : 'None'}</dd>
          </div>
          {shift.notes && (
            <div className="col-span-2">
              <dt className="text-xs text-muted">Notes</dt>
              <dd className="text-ink">{shift.notes}</dd>
            </div>
          )}
        </dl>
        <p className="text-xs text-muted">
          {kind === 'draft'
            ? 'Draft — staff can’t see it until it’s published.'
            : kind === 'cancelled'
              ? 'Cancelled — kept for the record.'
              : 'Published — staff can see it. Every change needs a reason and is kept in the history.'}
        </p>
        <div className="space-y-2">
          {actions.onEdit && (
            <button className={`${btn} text-ink`} onClick={actions.onEdit}>
              {kind === 'draft' ? 'Edit' : 'Edit (with a reason)'}
            </button>
          )}
          {actions.onCover && (
            <button className={`${btn} text-brand-blue`} onClick={actions.onCover}>
              {shift.employee_id ? 'Reassign / find cover' : 'Find someone for this shift'}
            </button>
          )}
          {actions.onHistory && (
            <button className={`${btn} text-ink`} onClick={actions.onHistory}>
              Change history
            </button>
          )}
          {actions.onCancel && (
            <button className={`${btn} text-brand-risk`} onClick={actions.onCancel}>
              {kind === 'draft' ? 'Cancel draft' : 'Cancel shift (with a reason)'}
            </button>
          )}
          {actions.onDelete && (
            <button className={`${btn} text-brand-risk`} onClick={actions.onDelete}>
              Delete cancelled shift
            </button>
          )}
        </div>
      </div>
    </Sheet>
  )
}
