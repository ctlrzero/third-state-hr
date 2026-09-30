import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { Alert, Field, Modal } from './ui'
import { fmtDate, fmtDayShort, fmtTime, todayDubai } from '../lib/format'
import { confirmDialog } from '../lib/confirm'

// Transfer workflow (P1-6). transfer_employee moves the home branch within the
// same company — today, or on a later date via the nightly job — and returns
// what to review at the old branch. Nothing is cancelled automatically.

interface TransferRow {
  id: string
  from_location_id: string | null
  to_location_id: string
  effective_date: string
  reason: string
  status: 'scheduled' | 'completed' | 'cancelled'
  completed_at: string | null
}

export interface TransferReview {
  shifts: { shift_id: string; shift_date: string; start_time: string; end_time: string; is_published: boolean }[]
  templates: { template_id: string; day_of_week: number; start_time: string; end_time: string }[]
  availability: { day_of_week: number; is_available: boolean; start_time: string | null; end_time: string | null }[]
  work_pattern: { days_per_week: number; days_off_mode: string; fixed_days_off: number[] | null } | null
}

const DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

/** Scheduled or recent transfer for one employee, with its review list. */
export function TransferStatusCard({
  employeeId,
  canManage,
  refreshKey,
  onChanged,
}: {
  employeeId: string
  canManage: boolean
  refreshKey: number
  onChanged: () => void
}) {
  const [row, setRow] = useState<TransferRow | null>(null)
  const [names, setNames] = useState<Record<string, string>>({})
  const [review, setReview] = useState<TransferReview | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data, error: e } = await supabase
      .from('employee_transfers')
      .select('id, from_location_id, to_location_id, effective_date, reason, status, completed_at')
      .eq('employee_id', employeeId)
      .neq('status', 'cancelled')
      .order('created_at', { ascending: false })
      .limit(1)
    if (e) return setError(e.message)
    const t = ((data ?? []) as TransferRow[])[0] ?? null
    // Completed transfers stay visible for two weeks so the old branch can be tidied up.
    const recent = t && (t.status === 'scheduled' || (t.completed_at && Date.now() - new Date(t.completed_at).getTime() < 14 * 864e5))
    setRow(recent ? t : null)
    setReview(null)
    if (!recent || !t) return
    const ids = [t.from_location_id, t.to_location_id].filter(Boolean) as string[]
    const { data: locs } = await supabase.from('locations').select('id, name').in('id', ids)
    setNames(Object.fromEntries(((locs ?? []) as { id: string; name: string }[]).map((l) => [l.id, l.name])))
    const { data: rev, error: re } = await supabase.rpc('get_transfer_review', { p_transfer_id: t.id })
    if (re) setError(re.message)
    else setReview(rev as TransferReview)
  }, [employeeId])

  useEffect(() => {
    load()
  }, [load, refreshKey])

  if (!row) return error ? <Alert tone="error">{error}</Alert> : null

  async function cancel() {
    if (!row) return
    const ok = await confirmDialog('Cancel this transfer? The employee stays at their current branch.')
    if (!ok) return
    setBusy(true)
    const { error: e } = await supabase.rpc('cancel_employee_transfer', { p_transfer_id: row.id, p_reason: null })
    setBusy(false)
    if (e) return setError(e.message)
    onChanged()
  }

  const from = row.from_location_id ? (names[row.from_location_id] ?? 'old branch') : 'no branch'
  const to = names[row.to_location_id] ?? 'new branch'
  return (
    <section className="card space-y-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-semibold text-ink">
            {row.status === 'scheduled' ? `Moving to ${to} on ${fmtDayShort(row.effective_date)}` : `Moved from ${from} to ${to} on ${fmtDayShort(row.effective_date)}`}
          </h2>
          <p className="text-sm text-muted">Reason: {row.reason}</p>
        </div>
        {canManage && row.status === 'scheduled' && (
          <button className="btn-secondary" disabled={busy} onClick={cancel}>
            Cancel transfer
          </button>
        )}
      </div>
      {error && <Alert tone="error">{error}</Alert>}
      {review && <TransferReviewList review={review} fromName={from} />}
    </section>
  )
}

export function TransferReviewList({ review, fromName }: { review: TransferReview; fromName: string }) {
  const off = review.availability.filter((a) => !a.is_available).map((a) => DAY[a.day_of_week])
  const limited = review.availability.filter((a) => a.is_available && a.start_time && a.end_time)
  const nothing = review.shifts.length === 0 && review.templates.length === 0
  return (
    <div className="space-y-3 text-sm">
      {nothing ? (
        <p className="text-muted">Nothing left at {fromName} from that date — no shifts or recurring templates to change.</p>
      ) : (
        <p className="text-muted">Nothing was changed automatically. Review these at {fromName}:</p>
      )}
      {review.shifts.length > 0 && (
        <div>
          <h3 className="text-xs font-semibold uppercase tracking-wide text-muted">Shifts still at {fromName} · {review.shifts.length}</h3>
          <ul className="mt-1 divide-y divide-border rounded-lg border border-border">
            {review.shifts.map((s) => (
              <li key={s.shift_id} className="flex items-center justify-between gap-2 px-3 py-2">
                <span>
                  {fmtDayShort(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                  {!s.is_published && <span className="ml-1 text-xs text-muted">(draft)</span>}
                </span>
                <Link to={`/schedules?shift=${s.shift_id}`} className="text-sm font-medium text-brand-blue">
                  Reassign
                </Link>
              </li>
            ))}
          </ul>
        </div>
      )}
      {review.templates.length > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-2">
          <span>
            <span className="font-medium text-ink">Recurring templates at {fromName}:</span>{' '}
            {review.templates.map((t) => `${DAY[t.day_of_week]} ${fmtTime(t.start_time)}–${fmtTime(t.end_time)}`).join(', ')}
          </span>
          <Link to="/schedules?tab=setup" className="text-sm font-medium text-brand-blue">
            Replace templates
          </Link>
        </div>
      )}
      <p className="text-muted">
        Availability:{' '}
        {review.availability.length === 0
          ? 'not set'
          : off.length === 0 && limited.length === 0
            ? 'any day, any time'
            : [off.length ? `off ${off.join(', ')}` : null, ...limited.map((a) => `${DAY[a.day_of_week]} ${fmtTime(a.start_time)}–${fmtTime(a.end_time)}`)]
                .filter(Boolean)
                .join(' · ')}
        {review.work_pattern &&
          ` · works ${review.work_pattern.days_per_week} days a week${
            review.work_pattern.days_off_mode === 'fixed' && review.work_pattern.fixed_days_off?.length
              ? ` (off ${review.work_pattern.fixed_days_off.map((d) => DAY[d]).join(', ')})`
              : ''
          }`}
        . Check it still fits the new branch's hours.
      </p>
    </div>
  )
}

export function TransferModal({
  employee,
  onClose,
  onDone,
}: {
  employee: { id: string; name: string; entity_id: string; home_location_id: string | null; home_location_name: string | null }
  onClose: () => void
  onDone: (message: string) => void
}) {
  const [branches, setBranches] = useState<{ id: string; name: string }[]>([])
  const [to, setTo] = useState('')
  const [date, setDate] = useState(todayDubai())
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<{ status: string; to_location_name: string; effective_date: string; review: TransferReview } | null>(null)

  useEffect(() => {
    supabase
      .from('locations')
      .select('id, name')
      .eq('entity_id', employee.entity_id)
      .order('name')
      .then(({ data }) => {
        const list = ((data ?? []) as { id: string; name: string }[]).filter((l) => l.id !== employee.home_location_id)
        setBranches(list)
        setTo((cur) => cur || list[0]?.id || '')
      })
  }, [employee.entity_id, employee.home_location_id])

  async function submit() {
    setBusy(true)
    setError(null)
    const { data, error: e } = await supabase.rpc('transfer_employee', {
      p_employee_id: employee.id,
      p_new_home_location_id: to,
      p_effective_date: date,
      p_reason: reason,
    })
    setBusy(false)
    if (e) return setError(e.message)
    setResult(data as typeof result)
  }

  const fromName = employee.home_location_name ?? 'the old branch'
  if (result) {
    return (
      <Modal
        open
        title={result.status === 'completed' ? `${employee.name} moved to ${result.to_location_name}` : `Transfer scheduled for ${fmtDate(result.effective_date)}`}
        onClose={() => onDone(result.status === 'completed' ? `Moved to ${result.to_location_name}.` : `Transfer to ${result.to_location_name} scheduled.`)}
        footer={
          <button
            className="btn-primary"
            onClick={() => onDone(result.status === 'completed' ? `Moved to ${result.to_location_name}.` : `Transfer to ${result.to_location_name} scheduled.`)}
          >
            Done
          </button>
        }
      >
        {result.status === 'scheduled' && (
          <p className="text-muted">The home branch changes automatically just after midnight on that day. The old branch's managers have been told.</p>
        )}
        <TransferReviewList review={result.review} fromName={fromName} />
      </Modal>
    )
  }

  return (
    <Modal
      open
      title={`Transfer ${employee.name}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" disabled={busy || !to || !reason.trim() || !date} onClick={submit}>
            {busy ? 'Saving…' : date <= todayDubai() ? 'Transfer now' : 'Schedule transfer'}
          </button>
        </>
      }
    >
      {branches.length === 0 ? (
        <p className="text-muted">This company has no other branch. To move someone to another company, offboard and onboard them.</p>
      ) : (
        <>
          <Field label="New home branch" required>
            {(p) => (
              <select {...p} className="input" value={to} onChange={(e) => setTo(e.target.value)}>
                {branches.map((b) => (
                  <option key={b.id} value={b.id}>
                    {b.name}
                  </option>
                ))}
              </select>
            )}
          </Field>
          <Field label="From" required hint="Today moves them now; a later date moves them automatically that day.">
            {(p) => <input {...p} type="date" className="input" min={todayDubai()} value={date} onChange={(e) => setDate(e.target.value)} />}
          </Field>
          <Field label="Reason" required>
            {(p) => <textarea {...p} rows={2} className="input" value={reason} onChange={(e) => setReason(e.target.value)} />}
          </Field>
          <p className="text-xs text-muted">Same company only. Their shifts and recurring templates at the current branch are listed for you afterwards — nothing is cancelled for you.</p>
        </>
      )}
      {error && <Alert tone="error">{error}</Alert>}
    </Modal>
  )
}
