import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { callRpc } from '../../lib/api/client'
import { fmtDayShort } from '../../lib/format'

// Pre-payroll readiness (P2-2): one read-only checklist of what still blocks this
// payroll month — the payroll engine's own checks plus the HR inputs that feed pay.
// Names and counts only; it never shows or changes amounts.

interface ReadinessItem {
  key: string
  severity: 'blocking' | 'warning'
  count: number
  title: string
  people: (string | { name: string; detail: string | null })[]
  link: string
  action: string
}

export interface Readiness {
  pay_date: string
  days_to_pay_day: number
  records: number
  approved: number
  blocking: number
  warnings: number
  ready: boolean
  /** Every current payslip published — the month is finished. */
  done?: boolean
  items: ReadinessItem[]
}

export default function ReadinessPanel({ periodId, refreshKey }: { periodId: string; refreshKey: number }) {
  const [data, setData] = useState<Readiness | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    callRpc<Readiness>('get_payroll_readiness', { p_period_id: periodId }).then((res) => {
      if (!alive) return
      if (res.error) setError(res.error)
      else {
        setError(null)
        setData(res.data)
      }
    })
    return () => {
      alive = false
    }
  }, [periodId, refreshKey])

  // No readiness permission: hide the panel; the workspace itself still works.
  if (error && /permission|not authori[sz]ed|42501|can’t do this/i.test(error)) return null
  if (error)
    return (
      <section aria-label="Payroll readiness" className="rounded-[14px] border border-border bg-surface p-4 text-sm text-muted">
        Couldn’t load the pre-payroll checklist. Refresh the page to try again.
      </section>
    )
  if (!data) return null

  const days = data.days_to_pay_day
  const when = days === 0 ? 'today' : days === 1 ? 'tomorrow' : days > 1 ? `in ${days} days` : `${-days} day${days === -1 ? '' : 's'} ago`
  const finished = !!data.done
  const done = finished || (data.records > 0 && data.approved === data.records && data.ready)
  const tone = data.blocking ? 'border-brand-risk/30 bg-brand-risk-soft' : data.warnings ? 'border-brand-warning/40 bg-brand-warning-soft' : 'border-border bg-surface'

  return (
    <section aria-label="Payroll readiness" className={`rounded-[14px] border p-4 ${tone}`}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-semibold text-ink">
          {finished
            ? 'This month is finished'
            : done
            ? 'Everything approved'
            : data.blocking
              ? `${data.blocking} to fix before you can approve`
              : data.warnings
                ? 'Ready to approve — a few things to check'
                : 'Ready to approve'}
        </h2>
        <p className="text-sm text-muted">
          Pay day {fmtDayShort(data.pay_date)} ({when}) · {data.approved} of {data.records} approved
        </p>
      </div>
      {done ? (
        <p className="mt-1 text-sm text-ink">
          {finished ? 'Everyone is paid and payslips are published. Nothing to do.' : 'Everything approved. Next: record payment, then publish payslips.'}
        </p>
      ) : (
        !data.blocking && <p className="mt-1 text-sm text-ink">Next: tick ‘Select all’ in the table below, then press Approve.</p>
      )}
      {data.items.length > 0 && (
        <ul className="mt-3 space-y-2">
          {data.items.map((i) => {
            const names = i.people.map((p) => (typeof p === 'string' ? p : p.name))
            const details = i.people.filter((p): p is { name: string; detail: string | null } => typeof p !== 'string' && !!p.detail)
            return (
              <li key={i.key} className="rounded-lg bg-surface px-3 py-2">
                <div className="flex flex-wrap items-center gap-2">
                  <span
                    className={`rounded-full px-2 py-px text-[11px] font-semibold ${
                      i.severity === 'blocking' ? 'bg-brand-risk-soft text-brand-risk-text' : 'bg-brand-warning-soft text-brand-warning-solid'
                    }`}
                  >
                    {i.severity === 'blocking' ? 'Must fix' : 'Worth a look'}
                  </span>
                  <span className="min-w-0 flex-1 text-sm font-medium text-ink">
                    {i.count} × {i.title}
                  </span>
                  {details.length > 0 && (
                    <button className="text-xs font-medium text-brand-blue" onClick={() => setOpen(open === i.key ? null : i.key)}>
                      {open === i.key ? 'Hide details' : 'Show details'}
                    </button>
                  )}
                  <Link to={i.link} className="text-sm font-medium text-brand-blue">
                    {i.action}
                  </Link>
                </div>
                {names.length > 0 && (
                  <p className="mt-0.5 text-xs text-muted">
                    {names.join(', ')}
                    {i.count > names.length ? ` and ${i.count - names.length} more` : ''}
                  </p>
                )}
                {open === i.key && (
                  <ul className="mt-1 list-disc pl-5 text-xs text-muted">
                    {details.map((d, n) => (
                      <li key={n}>
                        {d.name}: {d.detail}
                      </li>
                    ))}
                  </ul>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
