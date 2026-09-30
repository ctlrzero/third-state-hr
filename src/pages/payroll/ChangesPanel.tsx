import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { callRpc, friendlyError } from '../../lib/api/client'
import { fmtMoney } from '../../lib/payroll'

// Payroll explainer (P2-3): what changed since last month, person by person.
// The comparison comes from get_payroll_changes (payroll view_pay); "Explain in
// plain words" asks the payroll-explainer Edge Function for sentences. Read-only.

interface Change {
  kind: string
  label: string
  now: number
  prev: number
  change: number
}
interface Person {
  employee_id: string
  name: string
  net_now: number
  net_prev: number | null
  net_change: number
  new_this_month: boolean
  changes: Change[]
}
interface Changes {
  previous_label: string | null
  currency: string
  employees: Person[]
  left_since_last_month: { employee_id: string; name: string; net_prev: number }[]
  totals: { net_now: number; net_prev: number }
}
interface Explanation {
  ai: boolean
  summary: string[]
  people: { employee_id: string; sentence: string }[]
}

export default function ChangesPanel({ periodId, refreshKey }: { periodId: string; refreshKey: number }) {
  const [data, setData] = useState<Changes | null>(null)
  const [explained, setExplained] = useState<Explanation | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    setExplained(null)
    callRpc<Changes>('get_payroll_changes', { p_period_id: periodId }).then((res) => {
      if (alive && !res.error) setData(res.data)
    })
    return () => {
      alive = false
    }
  }, [periodId, refreshKey])

  if (!data || !data.previous_label || data.employees.length === 0) return null
  const cur = data.currency
  const changed = data.employees.filter((p) => p.new_this_month || Number(p.net_change) !== 0)
  const diff = Number(data.totals.net_now) - Number(data.totals.net_prev)
  const sentence = new Map((explained?.people ?? []).map((p) => [p.employee_id, p.sentence]))
  const signed = (n: number) => `${n >= 0 ? '+' : '−'}${fmtMoney(Math.abs(n), cur)}`

  async function explain() {
    setBusy(true)
    setError(null)
    const { data: res, error: e } = await supabase.functions.invoke<Explanation>('payroll-explainer', { body: { period_id: periodId } })
    setBusy(false)
    if (e || !res) return setError(e ? friendlyError(e) : 'The explanation isn’t available right now. The table below is still accurate.')
    setExplained(res)
  }

  return (
    <details className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <summary className="cursor-pointer text-sm font-semibold text-ink">
        What changed since {data.previous_label} · {signed(diff)} net · {changed.length} {changed.length === 1 ? 'person' : 'people'}
      </summary>
      <div className="mt-3 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="text-xs text-muted">
            Net pay {fmtMoney(data.totals.net_prev, cur)} → {fmtMoney(data.totals.net_now, cur)}. Only people whose pay changed are listed.
          </p>
          {!explained && (
            <button className="btn-secondary press text-sm" onClick={explain} disabled={busy}>
              {busy ? 'Explaining…' : 'Explain in plain words'}
            </button>
          )}
        </div>
        {error && <p className="text-sm text-brand-risk-text">{error}</p>}
        {explained && explained.summary.length > 0 && (
          <div className="rounded-xl bg-brand-blue-soft/50 px-3.5 py-3 text-sm">
            <ul className="list-disc space-y-1 pl-5 text-ink">
              {explained.summary.map((s, i) => (
                <li key={i}>{s}</li>
              ))}
            </ul>
            <p className="mt-2 text-[11px] text-muted">
              {explained.ai ? 'Written by the assistant from the pay lines.' : 'Worked out from the pay lines.'} Check before you approve.
            </p>
          </div>
        )}
        {changed.length === 0 ? (
          <p className="text-sm text-muted">Nobody’s pay changed.</p>
        ) : (
          <ul className="divide-y divide-border">
            {changed.map((p) => (
              <li key={p.employee_id} className="py-2.5 text-sm">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="font-medium text-ink">{p.name}</span>
                  <span className={`tabular-nums ${Number(p.net_change) < 0 ? 'text-brand-risk-text' : 'text-ink'}`}>
                    {p.new_this_month ? `New · ${fmtMoney(p.net_now, cur)}` : `${fmtMoney(p.net_prev, cur)} → ${fmtMoney(p.net_now, cur)} (${signed(Number(p.net_change))})`}
                  </span>
                </div>
                {sentence.get(p.employee_id) ? (
                  <p className="mt-0.5 text-muted">{sentence.get(p.employee_id)}</p>
                ) : (
                  p.changes.length > 0 && (
                    <p className="mt-0.5 text-xs text-muted">
                      {p.changes
                        .slice(0, 3)
                        .map((c) => `${c.label} ${signed(Number(c.change))}`)
                        .join(' · ')}
                    </p>
                  )
                )}
              </li>
            ))}
          </ul>
        )}
        {data.left_since_last_month.length > 0 && (
          <p className="text-xs text-muted">Paid in {data.previous_label} but not this month: {data.left_since_last_month.map((p) => p.name).join(', ')}.</p>
        )}
      </div>
    </details>
  )
}
