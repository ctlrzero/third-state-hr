import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { EmptyState } from '../components/EmptyState'
import { StatusBadge } from '../components/StatusBadge'
import { Alert, PageHeader, Skeleton } from '../components/ui'
import {
  NOTIFICATION_TARGET_ROUTE,
  getMyNotifications,
  markAllNotificationsRead,
  markNotificationRead,
} from '../lib/api/notifications'
import { fmtDateTime } from '../lib/format'
import type { NotificationRow } from '../types/db'

const PAGE = 30

export default function Notifications() {
  const navigate = useNavigate()
  const [rows, setRows] = useState<NotificationRow[] | null>(null)
  const [unreadOnly, setUnreadOnly] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [loadingMore, setLoadingMore] = useState(false)
  const [hasMore, setHasMore] = useState(false)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    setRows(null)
    const res = await getMyNotifications(PAGE, null, unreadOnly)
    if (res.error) setError(res.error)
    const data = res.data ?? []
    setRows(data)
    setHasMore(data.length === PAGE)
  }, [unreadOnly])

  useEffect(() => {
    load()
  }, [load])

  async function loadMore() {
    if (!rows?.length) return
    setLoadingMore(true)
    const res = await getMyNotifications(PAGE, rows[rows.length - 1].created_at, unreadOnly)
    setLoadingMore(false)
    if (res.error) return setError(res.error)
    const data = res.data ?? []
    setRows([...rows, ...data])
    setHasMore(data.length === PAGE)
  }

  async function open(n: NotificationRow) {
    if (!n.read_at) {
      const res = await markNotificationRead(n.id)
      if (!res.error) setRows((prev) => prev?.map((r) => (r.id === n.id ? { ...r, read_at: new Date().toISOString() } : r)) ?? prev)
    }
    const route = n.target_type ? NOTIFICATION_TARGET_ROUTE[n.target_type] : undefined
    // A shift notice opens that shift (e.g. "can't come in" → Find cover).
    const target = route && n.target_type === 'shifts' && n.target_id ? `${route}?shift=${n.target_id}` : route
    if (target) navigate(target)
  }

  async function markAll() {
    setBusy(true)
    const res = await markAllNotificationsRead()
    setBusy(false)
    if (res.error) return setError(res.error)
    setRows((prev) => prev?.map((r) => ({ ...r, read_at: r.read_at ?? new Date().toISOString() })) ?? prev)
  }

  const unread = rows?.filter((r) => !r.read_at).length ?? 0

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      <PageHeader
        title="Notifications"
        actions={
          <button className="btn-secondary" onClick={markAll} disabled={busy || unread === 0}>
            Mark all as read
          </button>
        }
      />
      <label className="flex min-h-11 items-center gap-2 text-sm text-ink">
        <input type="checkbox" className="h-5 w-5 accent-brand-blue" checked={unreadOnly} onChange={(e) => setUnreadOnly(e.target.checked)} />
        Show unread only
      </label>
      {error && (
        <Alert tone="error" onDismiss={() => setError(null)}>
          {error}
        </Alert>
      )}
      {rows === null ? (
        <Skeleton rows={5} />
      ) : rows.length === 0 ? (
        <EmptyState title="You're all caught up" description="New notifications will appear here." />
      ) : (
        <ul className="space-y-2">
          {rows.map((n) => (
            <li key={n.id}>
              <button
                type="button"
                onClick={() => open(n)}
                className={`card flex w-full items-start justify-between gap-3 text-left transition hover:border-brand-blue/40 ${
                  n.read_at ? '' : 'border-l-4 border-l-brand-blue'
                }`}
              >
                <span className="min-w-0">
                  <span className="block font-medium text-ink">
                    {!n.read_at && <span className="sr-only">Unread: </span>}
                    {n.title}
                  </span>
                  {n.message && <span className="mt-0.5 block text-sm text-muted">{n.message}</span>}
                  <span className="mt-1 block text-xs text-muted">{fmtDateTime(n.created_at)}</span>
                </span>
                {n.priority === 'high' && <StatusBadge status="High priority" tone="risk" />}
              </button>
            </li>
          ))}
        </ul>
      )}
      {hasMore && (
        <button className="btn-secondary w-full" onClick={loadMore} disabled={loadingMore}>
          {loadingMore ? 'Loading…' : 'Load older'}
        </button>
      )}
    </div>
  )
}
