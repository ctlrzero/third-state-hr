import { fmtDayShort, todayDubai } from '../../lib/format'
import type { Shift } from '../../types/db'

// ---------------------------------------------------------------------------
// Dates (UTC arithmetic on yyyy-mm-dd; weeks run Monday–Sunday, the same week
// the scheduling rules use for 48 h / working days).
// ---------------------------------------------------------------------------

export function isoAddDays(iso: string, days: number) {
  const d = new Date(iso + 'T00:00:00Z')
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}

export function mondayOf(iso: string) {
  const dow = new Date(iso + 'T00:00:00Z').getUTCDay()
  return isoAddDays(iso, dow === 0 ? -6 : 1 - dow)
}

export function thisMonday() {
  return mondayOf(todayDubai())
}

export function weekLabel(monday: string) {
  return `${fmtDayShort(monday)} – ${fmtDayShort(isoAddDays(monday, 6))}`
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

export type ShiftKind = 'draft' | 'published' | 'adjusted' | 'cancelled'

export function shiftKind(s: Shift, adjustedIds: Set<string>): ShiftKind {
  if (s.status === 'cancelled') return 'cancelled'
  if (!s.is_published) return 'draft'
  return adjustedIds.has(s.id) ? 'adjusted' : 'published'
}

