// UAE-readable date/time helpers. Everything renders in Asia/Dubai with a
// 24-hour clock regardless of the viewer's device timezone, so a manager
// travelling abroad sees the same times as the branch.
export const TZ = 'Asia/Dubai'
const LOCALE = 'en-GB'

function parse(value: string): Date {
  return value.length === 10 ? new Date(value + 'T12:00:00Z') : new Date(value)
}

/** "25 Sep 2026" for an ISO date (yyyy-mm-dd) or timestamp. */
export function fmtDate(value: string | null | undefined): string {
  if (!value) return '—'
  const d = parse(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleDateString(LOCALE, { day: '2-digit', month: 'short', year: 'numeric', timeZone: TZ })
}

/** "Thu 25 Sep" — short weekday label for schedule/attendance lists. */
export function fmtDayShort(value: string | null | undefined): string {
  if (!value) return '—'
  const d = parse(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleDateString(LOCALE, { weekday: 'short', day: '2-digit', month: 'short', timeZone: TZ })
}

/** "14:05" for a timestamp, or passthrough "HH:MM" for a time-of-day string. */
export function fmtTime(value: string | null | undefined): string {
  if (!value) return '—'
  if (/^\d{2}:\d{2}(:\d{2})?$/.test(value)) return value.slice(0, 5)
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleTimeString(LOCALE, { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: TZ })
}

/**
 * Actual clock-in/out span: "12:02–17:30". A missing side is named rather
 * than rendered as a dash ("12:02 · no clock-out", "No clock-in · out 17:30").
 */
export function fmtClockRange(clockIn: string | null | undefined, clockOut: string | null | undefined): string {
  if (!clockIn && !clockOut) return '—'
  if (!clockOut) return `${fmtTime(clockIn)} · no clock-out`
  if (!clockIn) return `No clock-in · out ${fmtTime(clockOut)}`
  return `${fmtTime(clockIn)}–${fmtTime(clockOut)}`
}

/** "25 Sep 2026, 14:05" */
export function fmtDateTime(value: string | null | undefined): string {
  if (!value) return '—'
  return `${fmtDate(value)}, ${fmtTime(value)}`
}

/** "7h 30m" for a minute count. */
export function fmtMinutes(mins: number | null | undefined): string {
  if (mins == null) return '—'
  const sign = mins < 0 ? '-' : ''
  const abs = Math.abs(Math.round(mins))
  const h = Math.floor(abs / 60)
  const m = abs % 60
  if (h === 0) return `${sign}${m}m`
  return `${sign}${h}h${m ? ` ${m}m` : ''}`
}

/** Today's date (yyyy-mm-dd) in Asia/Dubai. */
export function todayDubai(now: Date = new Date()): string {
  return now.toLocaleDateString('en-CA', { timeZone: TZ })
}

export function addDays(isoDate: string, days: number): string {
  const d = new Date(isoDate + 'T12:00:00Z')
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}

/**
 * Convert a timestamptz to a value for <input type="datetime-local">,
 * expressed in Dubai wall-clock time (UTC+4, no DST).
 */
export function toDubaiLocalInput(iso: string | null | undefined): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return new Date(d.getTime() + 4 * 60 * 60 * 1000).toISOString().slice(0, 16)
}

/** Inverse of toDubaiLocalInput: "2026-09-25T09:00" (Dubai) → ISO UTC. */
export function fromDubaiLocalInput(local: string): string | null {
  if (!local) return null
  const d = new Date(local + ':00+04:00')
  if (Number.isNaN(d.getTime())) return null
  return d.toISOString()
}

export function humanize(value: string | null | undefined): string {
  if (!value) return '—'
  const s = value.replace(/_/g, ' ')
  return s.charAt(0).toUpperCase() + s.slice(1)
}
