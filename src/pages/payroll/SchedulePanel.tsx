import { useEffect, useState } from 'react'
import { Alert } from '../../components/ui'
import { fmtDate, fmtDateTime, fromDubaiLocalInput, toDubaiLocalInput } from '../../lib/format'
import { setPayrollSchedule, type PayrollPeriod } from '../../lib/api/payroll'

// Pay date and payslip schedule for one payroll month (owner's flow:
// month > employees > salary preparation > pay date > payslips on a date).
// The pay date can be in the future. Payslips are published automatically at the
// chosen time for people who are approved (and paid, when that box is ticked);
// anyone not ready is left unpublished and the payroll team is told.

export default function SchedulePanel({
  period,
  payDate,
  canEdit,
  onSaved,
}: {
  period: PayrollPeriod
  /** Effective pay date (stored, or worked out from the pay-day setting). */
  payDate: string | null
  canEdit: boolean
  onSaved: (message: string) => void
}) {
  const [editing, setEditing] = useState(false)
  // Blank = follow the pay-day setting; only a date the owner types is stored.
  const [date, setDate] = useState(period.pay_date ?? '')
  const [publishAt, setPublishAt] = useState(toDubaiLocalInput(period.publish_payslips_at))
  const [requirePaid, setRequirePaid] = useState(period.publish_requires_paid ?? true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    setDate(period.pay_date ?? '')
    setPublishAt(toDubaiLocalInput(period.publish_payslips_at))
    setRequirePaid(period.publish_requires_paid ?? true)
    setEditing(false)
  }, [period.id, period.pay_date, period.publish_payslips_at, period.publish_requires_paid, payDate])

  async function save(clearPublish = false) {
    setBusy(true)
    setError(null)
    const at = clearPublish ? null : fromDubaiLocalInput(publishAt)
    const res = await setPayrollSchedule(period.id, date || null, at, requirePaid)
    setBusy(false)
    if (res.error || !res.data) return setError(res.error ?? 'Couldn’t save the dates.')
    setEditing(false)
    onSaved(
      [
        date ? `Pay date set to ${fmtDate(date)}.` : 'Pay date follows the payroll settings.',
        at ? `Payslips will be published on ${fmtDateTime(at)}${requirePaid ? ' for everyone approved and paid' : ' for everyone approved'}.` : 'Payslips are published by hand.',
        res.data.warning ?? '',
      ]
        .filter(Boolean)
        .join(' ')
    )
  }

  const scheduled = period.publish_payslips_at
  return (
    <section aria-label="Pay date and payslips" className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-0.5 text-sm">
          <p>
            <span className="text-muted">Pay date: </span>
            <span className="font-semibold text-ink">{payDate ? fmtDate(payDate) : 'Not set'}</span>
            {!period.pay_date && payDate && <span className="text-xs text-muted"> (from payroll settings)</span>}
          </p>
          <p>
            <span className="text-muted">Payslips: </span>
            <span className="font-semibold text-ink">
              {scheduled
                ? `published automatically on ${fmtDateTime(scheduled)}${period.publish_requires_paid ? ', once paid' : ''}`
                : 'published by hand'}
            </span>
          </p>
        </div>
        {canEdit && !editing && (
          <button type="button" className="btn-secondary min-h-11" onClick={() => setEditing(true)}>
            Change dates
          </button>
        )}
      </div>

      {editing && (
        <div className="mt-3 space-y-3 border-t border-border pt-3">
          {error && <Alert tone="error">{error}</Alert>}
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block">
              <span className="label">Pay date (when the salary goes to the bank)</span>
              <input type="date" className="input" value={date} onChange={(e) => setDate(e.target.value)} />
              <span className="mt-1 block text-xs text-muted">
                Can be in the future. Leave empty to use the payroll settings{payDate && !period.pay_date ? ` (${fmtDate(payDate)})` : ''}. Record the payment on the day it’s sent.
              </span>
            </label>
            <label className="block">
              <span className="label">Publish payslips on (Dubai time)</span>
              <input type="datetime-local" className="input" value={publishAt} onChange={(e) => setPublishAt(e.target.value)} />
              <span className="mt-1 block text-xs text-muted">Leave empty to publish by hand.</span>
            </label>
          </div>
          <label className="flex min-h-11 items-center gap-2 text-sm text-ink">
            <input type="checkbox" checked={requirePaid} onChange={(e) => setRequirePaid(e.target.checked)} />
            Only publish payslips for people whose payment is recorded
          </label>
          <div className="flex flex-wrap justify-end gap-2">
            {scheduled && (
              <button type="button" className="btn-ghost min-h-11" disabled={busy} onClick={() => save(true)}>
                Stop automatic publishing
              </button>
            )}
            <button type="button" className="btn-secondary min-h-11" disabled={busy} onClick={() => setEditing(false)}>
              Cancel
            </button>
            <button type="button" className="btn-primary min-h-11" disabled={busy} onClick={() => save(false)}>
              {busy ? 'Saving…' : 'Save dates'}
            </button>
          </div>
        </div>
      )}
    </section>
  )
}
