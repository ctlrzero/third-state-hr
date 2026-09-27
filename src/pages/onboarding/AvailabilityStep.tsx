import { useEffect, useState } from 'react'
import { Skeleton } from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import { getMyAvailability, saveMyAvailability, type AvailabilityDay } from '../../lib/api/onboarding'
import { fmtDate } from '../../lib/format'

// 0 = Sunday … 6 = Saturday (same as schedule templates). UAE week order.
const ORDER = [1, 2, 3, 4, 5, 6, 0]
const DAY = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

export default function AvailabilityStep({ n, onDone, onError }: { n: number | string; onDone: (m: string) => Promise<void>; onError: (e: string) => void }) {
  const [days, setDays] = useState<AvailabilityDay[] | null>(null)
  const [confirmed, setConfirmed] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    getMyAvailability().then((r) => {
      if (r.error) return onError(r.error)
      const got = new Map((r.data?.days ?? []).map((d) => [d.day_of_week, d]))
      setDays([0, 1, 2, 3, 4, 5, 6].map((d) => got.get(d) ?? { day_of_week: d, is_available: true, start_time: null, end_time: null }))
      setConfirmed(r.data?.confirmed_at ?? null)
    })
  }, [onError])

  function set(dow: number, patch: Partial<AvailabilityDay>) {
    setDays((ds) => ds?.map((d) => (d.day_of_week === dow ? { ...d, ...patch } : d)) ?? ds)
  }

  async function save() {
    if (!days) return
    const bad = days.find((d) => d.is_available && d.start_time && d.end_time && d.end_time <= d.start_time)
    if (bad) return onError(`${DAY[bad.day_of_week]}: the end time must be after the start time.`)
    setBusy(true)
    const r = await saveMyAvailability(days.map((d) => ({ ...d, start_time: d.start_time || null, end_time: d.end_time || null })))
    setBusy(false)
    if (r.error) return onError(r.error)
    onDone('Availability saved. Your manager uses it when planning the rota.')
  }

  return (
    <section className="card space-y-3" aria-label="Weekly availability">
      <div className="flex items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-base font-semibold text-ink">
          <span className="flex h-7 w-7 items-center justify-center rounded-full bg-brand-blue-soft text-sm text-brand-blue-text" aria-hidden="true">
            {n}
          </span>
          When you can work
        </h2>
        {confirmed ? <StatusBadge status="Done" tone="success" /> : <StatusBadge status="To do" tone="neutral" />}
      </div>
      <p className="text-sm text-muted">Tick the days you can work. Leave the times empty if you are free all day.{confirmed && ` Last confirmed ${fmtDate(confirmed)}.`}</p>
      {!days ? (
        <Skeleton rows={3} className="h-10" />
      ) : (
        <ul className="divide-y divide-border">
          {ORDER.map((dow) => {
            const d = days.find((x) => x.day_of_week === dow)!
            return (
              <li key={dow} className="flex flex-wrap items-center gap-3 py-2 text-sm">
                <label className="flex w-32 items-center gap-2">
                  <input type="checkbox" checked={d.is_available} onChange={(e) => set(dow, { is_available: e.target.checked })} />
                  {DAY[dow]}
                </label>
                {d.is_available ? (
                  <span className="flex items-center gap-2">
                    <label>
                      <span className="sr-only">{DAY[dow]} from</span>
                      <input type="time" className="input w-32" value={d.start_time?.slice(0, 5) ?? ''} onChange={(e) => set(dow, { start_time: e.target.value || null })} />
                    </label>
                    <span className="text-muted">to</span>
                    <label>
                      <span className="sr-only">{DAY[dow]} until</span>
                      <input type="time" className="input w-32" value={d.end_time?.slice(0, 5) ?? ''} onChange={(e) => set(dow, { end_time: e.target.value || null })} />
                    </label>
                  </span>
                ) : (
                  <span className="text-muted">Not available</span>
                )}
              </li>
            )
          })}
        </ul>
      )}
      <button className="btn-primary" onClick={save} disabled={busy || !days}>
        {confirmed ? 'Update availability' : 'Confirm availability'}
      </button>
    </section>
  )
}
