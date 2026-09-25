import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, Field, Modal } from './ui'
import { CHANGE_FIELD_LABEL, decideEmployeeChangeRequest, listPendingChangeRequests } from '../lib/api/employees'
import { fmtDate, humanize } from '../lib/format'
import type { EmployeeChangeRequest } from '../types/db'

// Manager/admin queue of staff-submitted contact change requests across the
// caller's RLS scope. Decisions go through decide_employee_change_request(),
// which re-checks authority and that the request is still pending.
export function ChangeRequestQueue() {
  const [rows, setRows] = useState<EmployeeChangeRequest[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [rejecting, setRejecting] = useState<EmployeeChangeRequest | null>(null)
  const [reason, setReason] = useState('')
  const [expanded, setExpanded] = useState(false)

  const load = useCallback(async () => {
    const res = await listPendingChangeRequests()
    if (res.error) setError(res.error)
    setRows(res.data ?? [])
  }, [])
  useEffect(() => {
    load()
  }, [load])

  async function decide(r: EmployeeChangeRequest, action: 'approve' | 'reject', why: string | null) {
    setBusyId(r.id)
    const res = await decideEmployeeChangeRequest(r.id, action, why)
    setBusyId(null)
    if (res.error) return setError(res.error)
    setNotice(action === 'approve' ? `Change applied for ${r.employees?.full_name ?? 'employee'}.` : 'Change request rejected.')
    setRejecting(null)
    setReason('')
    load()
  }

  if (!rows || rows.length === 0) return null
  const visible = expanded ? rows : rows.slice(0, 3)

  return (
    <section className="card space-y-3" aria-labelledby="cr-queue-h">
      <div className="flex items-center justify-between gap-2">
        <h2 id="cr-queue-h" className="text-sm font-semibold text-ink">
          Contact change requests <span className="ml-1 rounded-full bg-brand-warning-soft px-2 py-0.5 text-xs text-brand-warning-solid">{rows.length} pending</span>
        </h2>
        {rows.length > 3 && (
          <button className="btn-ghost" onClick={() => setExpanded((v) => !v)} aria-expanded={expanded}>
            {expanded ? 'Show fewer' : `Show all ${rows.length}`}
          </button>
        )}
      </div>
      {error && (
        <Alert tone="error" onDismiss={() => setError(null)}>
          {error}
        </Alert>
      )}
      {notice && (
        <Alert tone="success" onDismiss={() => setNotice(null)}>
          {notice}
        </Alert>
      )}
      <ul className="space-y-2">
        {visible.map((r) => (
          <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
            <span className="min-w-0">
              <Link to={`/employees/${r.employee_id}`} className="font-medium text-brand-blue hover:underline">
                {r.employees?.full_name ?? 'Employee'}
              </Link>{' '}
              · {CHANGE_FIELD_LABEL[r.field_name] ?? humanize(r.field_name)}: {r.old_value ?? '—'} → <strong>{r.new_value}</strong>
              <span className="block text-xs text-muted">
                Requested {fmtDate(r.requested_at)}
                {r.reason ? ` · “${r.reason}”` : ''}
              </span>
            </span>
            <span className="flex gap-2">
              <button className="btn-primary" disabled={busyId === r.id} onClick={() => decide(r, 'approve', null)}>
                Approve
              </button>
              <button className="btn-secondary" disabled={busyId === r.id} onClick={() => setRejecting(r)}>
                Reject
              </button>
            </span>
          </li>
        ))}
      </ul>
      <Modal
        open={Boolean(rejecting)}
        title="Reject change request?"
        onClose={() => setRejecting(null)}
        footer={
          <>
            <button className="btn-secondary" onClick={() => setRejecting(null)}>
              Cancel
            </button>
            <button className="btn-danger" disabled={!reason.trim() || busyId !== null} onClick={() => rejecting && decide(rejecting, 'reject', reason.trim())}>
              Reject
            </button>
          </>
        }
      >
        <Field label="Reason (shared with the employee)" required>
          {(p) => <textarea {...p} rows={3} className="input" value={reason} onChange={(e) => setReason(e.target.value)} data-autofocus />}
        </Field>
      </Modal>
    </section>
  )
}
