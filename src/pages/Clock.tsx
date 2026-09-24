import { useCallback, useEffect, useRef, useState } from 'react'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { Alert, NotAvailable, PageHeader, Skeleton } from '../components/ui'
import {
  clockIn,
  clockOut,
  getMyAttendance,
  getMyClockStatus,
  type ClockStatus,
  type MyAttendanceRow,
} from '../lib/api/attendance'
import { CLOCK_STATE_LABEL, clockButtonModel } from '../lib/clockState'
import { addDays, fmtDayShort, fmtMinutes, fmtTime, todayDubai } from '../lib/format'

// Staff "Clock" screen (mobile-first). The big button's state is always
// derived from what the server says (get_my_clock_status), never from an
// optimistic local guess — a success message and captured time are shown
// only after clock_in()/clock_out() return and the status is re-read.
export default function Clock() {
  const [status, setStatus] = useState<ClockStatus | null>(null)
  const [statusUnavailable, setStatusUnavailable] = useState(false)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const inFlight = useRef(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const [history, setHistory] = useState<MyAttendanceRow[] | null>(null)
  const [historyUnavailable, setHistoryUnavailable] = useState(false)

  const loadStatus = useCallback(async () => {
    const res = await getMyClockStatus()
    if (res.notAvailable) setStatusUnavailable(true)
    else if (res.error) setError(res.error)
    else setStatus(res.data)
    setLoading(false)
    return res.data
  }, [])

  const loadHistory = useCallback(async () => {
    const today = todayDubai()
    const res = await getMyAttendance(addDays(today, -30), today)
    if (res.notAvailable) setHistoryUnavailable(true)
    else if (res.error) setError(res.error)
    else setHistory(res.data ?? [])
  }, [])

  useEffect(() => {
    loadStatus()
    loadHistory()
  }, [loadStatus, loadHistory])

  const model = clockButtonModel(loading ? null : (status?.state ?? null), saving)

  async function handleClock() {
    // Double-tap guard: a ref flips synchronously, before React re-renders
    // the disabled button.
    if (inFlight.current || !model.action) return
    inFlight.current = true
    setSaving(true)
    setError(null)
    setSuccess(null)
    const action = model.action
    const res = action === 'clock_in' ? await clockIn() : await clockOut()
    if (res.error || res.notAvailable) {
      setError(res.error ?? 'Clocking is not available yet.')
    } else {
      const fresh = await loadStatus()
      const at = action === 'clock_in' ? fresh?.attendance?.clock_in_at : fresh?.attendance?.clock_out_at
      setSuccess(
        `${action === 'clock_in' ? 'Clocked in' : 'Clocked out'}${at ? ` at ${fmtTime(at)}` : ''}. Saved.`
      )
      loadHistory()
    }
    setSaving(false)
    inFlight.current = false
  }

  const shift = status?.today_shift

  return (
    <div className="mx-auto max-w-lg space-y-5">
      <PageHeader title="Clock in / out" description={fmtDayShort(todayDubai())} />

      {statusUnavailable ? (
        <NotAvailable feature="Clock in / out" />
      ) : (
        <section className="card space-y-4" aria-labelledby="today-heading">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 id="today-heading" className="text-sm font-semibold text-muted">
                Today's shift
              </h2>
              {loading ? (
                <div className="mt-1 h-7 w-40 animate-pulse rounded bg-surface-alt" />
              ) : shift ? (
                <>
                  <p className="mt-0.5 text-2xl font-semibold text-ink">
                    {fmtTime(shift.start_time)} – {fmtTime(shift.end_time)}
                  </p>
                  {(shift.location_name || shift.position_title) && (
                    <p className="text-sm text-muted">
                      {[shift.position_title, shift.location_name].filter(Boolean).join(' · ')}
                    </p>
                  )}
                </>
              ) : (
                <p className="mt-0.5 text-lg font-medium text-ink">No shift scheduled</p>
              )}
            </div>
            {status && (
              <StatusBadge
                status={CLOCK_STATE_LABEL[status.state]}
                tone={status.state === 'clocked_in' ? 'success' : status.state === 'no_shift' ? 'warning' : 'neutral'}
              />
            )}
          </div>

          {status?.attendance && (
            <dl className="grid grid-cols-2 gap-3 rounded-lg bg-surface-alt p-3 text-sm">
              <div>
                <dt className="text-muted">Clocked in</dt>
                <dd className="text-lg font-semibold text-ink">{fmtTime(status.attendance.clock_in_at)}</dd>
              </div>
              <div>
                <dt className="text-muted">Clocked out</dt>
                <dd className="text-lg font-semibold text-ink">{fmtTime(status.attendance.clock_out_at)}</dd>
              </div>
            </dl>
          )}

          <button
            type="button"
            onClick={handleClock}
            disabled={model.disabled}
            aria-busy={saving}
            aria-describedby="clock-helper"
            className={`flex min-h-14 w-full items-center justify-center rounded-xl text-lg font-semibold transition disabled:cursor-not-allowed ${
              model.tone === 'primary'
                ? 'bg-brand-blue text-white hover:bg-brand-primary disabled:opacity-70'
                : model.tone === 'danger'
                  ? 'bg-brand-risk text-white hover:opacity-90 disabled:opacity-70'
                  : 'bg-surface-alt text-muted'
            }`}
          >
            {saving && (
              <span className="mr-2 h-5 w-5 animate-spin rounded-full border-2 border-white/40 border-t-white" aria-hidden="true" />
            )}
            {model.label}
          </button>
          <p id="clock-helper" className="text-center text-sm text-muted">
            {model.helper}
          </p>

          <div aria-live="polite">
            {success && <Alert tone="success">{success}</Alert>}
            {error && (
              <Alert tone="error" onDismiss={() => setError(null)}>
                {error}
              </Alert>
            )}
          </div>
        </section>
      )}

      <section aria-labelledby="history-heading" className="space-y-2">
        <h2 id="history-heading" className="text-base font-semibold text-ink">
          My last 30 days
        </h2>
        {historyUnavailable ? (
          <NotAvailable feature="Attendance history" />
        ) : history === null ? (
          <Skeleton rows={3} />
        ) : history.length === 0 ? (
          <EmptyState title="No attendance yet" description="Your clock-ins will appear here." />
        ) : (
          <ul className="space-y-2">
            {history.map((r) => (
              <li key={r.id} className="card flex flex-wrap items-center justify-between gap-2 py-3">
                <div>
                  <p className="font-medium text-ink">{fmtDayShort(r.shift_date ?? r.clock_in_at)}</p>
                  <p className="text-sm text-muted">
                    {r.planned_start ? `Planned ${fmtTime(r.planned_start)}–${fmtTime(r.planned_end)} · ` : ''}
                    Actual {fmtTime(r.clock_in_at)}–{fmtTime(r.clock_out_at)}
                  </p>
                  {r.corrected && (
                    <p className="text-xs text-brand-info-text">Corrected{r.correction_reason ? `: ${r.correction_reason}` : ''}</p>
                  )}
                </div>
                <div className="text-right text-sm">
                  <p className="font-semibold text-ink">{fmtMinutes(r.worked_minutes)}</p>
                  {r.late_minutes ? <p className="text-brand-warning-solid">{r.late_minutes}m late</p> : null}
                  {r.status && <StatusBadge status={r.status} />}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
