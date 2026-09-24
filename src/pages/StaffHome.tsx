import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { Skeleton } from '../components/ui'
import { getMyClockStatus, type ClockStatus } from '../lib/api/attendance'
import { CLOCK_STATE_LABEL } from '../lib/clockState'
import { fmtDayShort, fmtTime, todayDubai } from '../lib/format'
import type { LeaveBalance } from '../types/db'

// Staff home: the three things an employee checks most — today's clock
// status, upcoming shifts, and leave balance. Every query is scoped to the
// caller by RLS (self policies) or resolved from auth.uid() server-side.
export default function StaffHome() {
  const { profile } = useAuth()
  const [clock, setClock] = useState<ClockStatus | null | 'na'>(null)
  const [shifts, setShifts] = useState<{ id: string; shift_date: string; start_time: string; end_time: string; locations: { name: string } | null }[] | null>(null)
  const [balances, setBalances] = useState<LeaveBalance[] | null>(null)

  useEffect(() => {
    getMyClockStatus().then((r) => setClock(r.notAvailable || r.error ? 'na' : r.data))
    supabase
      .from('shifts')
      .select('id, shift_date, start_time, end_time, locations(name)')
      .gte('shift_date', todayDubai())
      .eq('is_published', true)
      .neq('status', 'cancelled')
      .order('shift_date')
      .order('start_time')
      .limit(5)
      .then(({ data }) => setShifts((data ?? []) as unknown as NonNullable<typeof shifts>))
    supabase
      .from('leave_balances')
      .select('*, leave_types(id, name)')
      .then(({ data }) => setBalances((data ?? []) as unknown as LeaveBalance[]))
  }, [])

  const firstName = profile?.full_name?.split(' ')[0]

  return (
    <div className="mx-auto max-w-2xl space-y-5">
      <h1 className="text-2xl font-semibold text-ink">Hi{firstName ? `, ${firstName}` : ''}</h1>

      <Link to="/clock" className="card flex items-center justify-between gap-3 transition hover:border-brand-blue/40">
        <div>
          <p className="text-sm text-muted">Today · {fmtDayShort(todayDubai())}</p>
          {clock === null ? (
            <div className="mt-1 h-6 w-32 animate-pulse rounded bg-surface-alt" />
          ) : clock === 'na' ? (
            <p className="text-lg font-semibold text-ink">Clock in / out</p>
          ) : (
            <p className="text-lg font-semibold text-ink">
              {clock.today_shift ? `${fmtTime(clock.today_shift.start_time)} – ${fmtTime(clock.today_shift.end_time)}` : 'No shift today'}
            </p>
          )}
        </div>
        <span className="flex items-center gap-2">
          {clock && clock !== 'na' && <StatusBadge status={CLOCK_STATE_LABEL[clock.state]} tone={clock.state === 'clocked_in' ? 'success' : 'neutral'} />}
          <span className="btn-primary">Open clock</span>
        </span>
      </Link>

      <section className="card" aria-labelledby="next-shifts-h">
        <div className="mb-2 flex items-center justify-between">
          <h2 id="next-shifts-h" className="text-base font-semibold text-ink">
            Next shifts
          </h2>
          <Link to="/schedules" className="text-sm font-medium text-brand-blue hover:underline">
            Full schedule
          </Link>
        </div>
        {shifts === null ? (
          <Skeleton rows={2} className="h-10" />
        ) : shifts.length === 0 ? (
          <p className="text-sm text-muted">No upcoming shifts published yet.</p>
        ) : (
          <ul className="divide-y divide-border">
            {shifts.map((s) => (
              <li key={s.id} className="flex items-center justify-between py-2.5 text-base">
                <span>{fmtDayShort(s.shift_date)}</span>
                <span className="font-medium">
                  {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                  {s.locations?.name && <span className="ml-1 text-sm font-normal text-muted">· {s.locations.name}</span>}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="card" aria-labelledby="leave-bal-h">
        <div className="mb-2 flex items-center justify-between">
          <h2 id="leave-bal-h" className="text-base font-semibold text-ink">
            Leave balance
          </h2>
          <Link to="/leave" className="text-sm font-medium text-brand-blue hover:underline">
            Request leave
          </Link>
        </div>
        {balances === null ? (
          <Skeleton rows={1} className="h-12" />
        ) : balances.length === 0 ? (
          <p className="text-sm text-muted">No leave balances yet.</p>
        ) : (
          <ul className="grid grid-cols-2 gap-3">
            {balances.map((b) => (
              <li key={b.id} className="rounded-lg bg-surface-alt p-3">
                <p className="text-sm text-muted">{b.leave_types?.name ?? 'Leave'}</p>
                <p className="text-xl font-semibold text-ink">{b.balance_days} days</p>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
