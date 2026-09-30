import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { NotificationRow } from '../types/db'

// Phase 2.5: shared notifications model. This component is intentionally a
// thin, read-mostly client over four RPCs (get_my_notifications,
// unread_notification_count, mark_notification_read,
// mark_all_notifications_read) — it never writes to public.notifications
// directly (there is no INSERT policy for authenticated users; the table is
// select/update-only, see README "Notifications"). Polling rather than
// realtime keeps this in line with the rest of the app, which is
// request/response throughout.
const POLL_MS = 30_000

// Best-effort destination for "View" — purely a navigation convenience, not
// an access-control decision. Every target page re-derives what the signed-in
// user is allowed to see via its own RLS-scoped query, so a stale or
// over-eager mapping here can at worst 404/empty-state, never leak data.
const TARGET_ROUTE: Record<string, string> = {
  employee_documents: '/documents',
  leave_requests: '/leave',
  shift_swap_requests: '/schedules',
  payslips: '/payroll',
  interviews: '/my-interviews',
  attendance_records: '/attendance',
  shifts: '/schedules',
  employees: '/employees',
  payroll_periods: '/payroll',
  shift_offers: '/schedules',
}

function timeAgo(iso: string): string {
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000)
  if (seconds < 60) return 'just now'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

export function NotificationBell() {
  const navigate = useNavigate()
  const [open, setOpen] = useState(false)
  const [unread, setUnread] = useState(0)
  const [rows, setRows] = useState<NotificationRow[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const containerRef = useRef<HTMLDivElement>(null)

  const loadUnreadCount = useCallback(async () => {
    const { data, error: rpcError } = await supabase.rpc('unread_notification_count')
    if (!rpcError && typeof data === 'number') setUnread(data)
  }, [])

  useEffect(() => {
    loadUnreadCount()
    const id = setInterval(loadUnreadCount, POLL_MS)
    return () => clearInterval(id)
  }, [loadUnreadCount])

  useEffect(() => {
    function onClickOutside(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onClickOutside)
    return () => document.removeEventListener('mousedown', onClickOutside)
  }, [])

  async function loadList() {
    setLoading(true)
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('get_my_notifications', {
      p_limit: 20,
      p_before: null,
      p_unread_only: false,
    })
    setLoading(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setRows((data ?? []) as NotificationRow[])
  }

  function togglePanel() {
    const next = !open
    setOpen(next)
    if (next) loadList()
  }

  async function handleMarkOne(n: NotificationRow) {
    if (n.read_at) {
      navigateToTarget(n)
      return
    }
    const { data, error: rpcError } = await supabase.rpc('mark_notification_read', { p_notification_id: n.id })
    if (!rpcError && data && (data as { ok?: boolean }).ok) {
      setRows((prev) => prev?.map((r) => (r.id === n.id ? { ...r, read_at: new Date().toISOString() } : r)) ?? prev)
      setUnread((u) => Math.max(0, u - 1))
    }
    navigateToTarget(n)
  }

  function navigateToTarget(n: NotificationRow) {
    const route = n.target_type ? TARGET_ROUTE[n.target_type] : undefined
    // A shift notice opens that shift (e.g. "can't come in" → Find cover).
    // "Can't come in" opens the Today board, where cover is found (managers and supervisors).
    const target = n.notification_type === 'absence_reported' || n.notification_type === 'no_clock_in'
      ? '/today'
      : route && n.target_id && n.target_type === 'shifts'
        ? `${route}?shift=${n.target_id}`
        : route && n.target_id && n.target_type === 'employees'
          ? `${route}/${n.target_id}`
          : route
    if (route) {
      setOpen(false)
      navigate(target ?? route)
    }
  }

  async function handleMarkAll() {
    const { error: rpcError } = await supabase.rpc('mark_all_notifications_read')
    if (!rpcError) {
      setRows((prev) => prev?.map((r) => ({ ...r, read_at: r.read_at ?? new Date().toISOString() })) ?? prev)
      setUnread(0)
    }
  }

  return (
    <div className="relative" ref={containerRef}>
      <button
        onClick={togglePanel}
        aria-label={unread > 0 ? `Notifications, ${unread} unread` : 'Notifications'}
        aria-expanded={open}
        className="relative flex h-11 w-11 items-center justify-center rounded-lg border border-border text-muted transition hover:border-brand-blue/30 hover:text-ink"
      >
        <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth={1.75}>
          <path
            d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9ZM13.73 21a2 2 0 0 1-3.46 0"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
        {unread > 0 && (
          <span className="absolute -right-1 -top-1 flex h-4 min-w-[16px] items-center justify-center rounded-full bg-brand-risk px-1 text-[10px] font-semibold text-white">
            {unread > 9 ? '9+' : unread}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 z-30 mt-2 w-[340px] max-w-[90vw] rounded-[14px] border border-border bg-surface p-3 shadow-card">
          <div className="mb-2 flex items-center justify-between">
            <h2 className="text-sm font-semibold text-ink">Notifications</h2>
            {unread > 0 && (
              <button onClick={handleMarkAll} className="text-xs font-medium text-brand-blue hover:underline">
                Mark all read
              </button>
            )}
          </div>

          {error && <p className="mb-2 rounded-lg bg-brand-risk-soft px-2 py-1.5 text-xs text-brand-risk-text">{error}</p>}

          {loading && !rows ? (
            <div className="space-y-2">
              {[0, 1, 2].map((i) => (
                <div key={i} className="h-12 animate-pulse rounded-lg bg-surface-alt" />
              ))}
            </div>
          ) : !rows || rows.length === 0 ? (
            <p className="py-4 text-center text-xs text-muted">You're all caught up.</p>
          ) : (
            <ul className="max-h-[360px] space-y-1 overflow-y-auto">
              {rows.map((n) => (
                <li key={n.id}>
                  <button
                    onClick={() => handleMarkOne(n)}
                    className={`w-full rounded-lg px-2.5 py-2 text-left text-xs transition hover:bg-surface-alt ${
                      n.read_at ? '' : 'bg-brand-blue/5'
                    }`}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <span className={`font-medium ${n.read_at ? 'text-ink' : 'text-ink'}`}>{n.title}</span>
                      {!n.read_at && <span className="mt-0.5 h-1.5 w-1.5 shrink-0 rounded-full bg-brand-blue" />}
                    </div>
                    {n.message && <p className="mt-0.5 text-muted">{n.message}</p>}
                    <p className="mt-1 text-[10px] text-muted">{timeAgo(n.created_at)}</p>
                  </button>
                </li>
              ))}
            </ul>
          )}
          <button
            onClick={() => {
              setOpen(false)
              navigate('/notifications')
            }}
            className="mt-2 flex min-h-11 w-full items-center justify-center rounded-lg text-sm font-semibold text-brand-blue hover:bg-surface-alt"
          >
            See all notifications
          </button>
        </div>
      )}
    </div>
  )
}
