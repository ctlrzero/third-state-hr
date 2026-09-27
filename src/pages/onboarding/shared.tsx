import { useEffect, useState, type ReactNode } from 'react'
import { Modal } from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import type { OnboardingStatus, Readiness, TaskStatus } from '../../lib/api/onboarding'
import {
  groupBlockersByOwner,
  STATUS_LABEL,
  STATUS_TONE,
  TASK_STATUS_LABEL,
  TASK_STATUS_TONE,
} from '../../lib/onboarding'
import { fmtDate } from '../../lib/format'

export function OnboardingStatusBadge({ status }: { status: OnboardingStatus }) {
  return <StatusBadge status={STATUS_LABEL[status]} tone={STATUS_TONE[status]} />
}

export function TaskStatusBadge({ status }: { status: TaskStatus }) {
  return <StatusBadge status={TASK_STATUS_LABEL[status]} tone={TASK_STATUS_TONE[status]} />
}

export function ProgressBar({ percent, label }: { percent: number; label: string }) {
  const p = Math.max(0, Math.min(100, Math.round(percent)))
  return (
    <div>
      <div className="mb-1 flex justify-between text-xs text-muted">
        <span>{label}</span>
        <span>{p}%</span>
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-surface-alt" role="progressbar" aria-valuenow={p} aria-valuemin={0} aria-valuemax={100} aria-label={label}>
        <div className={`h-full rounded-full ${p === 100 ? 'bg-brand-action' : 'bg-brand-blue'}`} style={{ width: `${p}%` }} />
      </div>
    </div>
  )
}

/** Server-calculated readiness: what blocks activation, grouped by who must act. */
export function ReadinessPanel({ readiness, onTask }: { readiness: Readiness; onTask?: (taskId: string) => void }) {
  const groups = groupBlockersByOwner(readiness.blockers)
  return (
    <section className="card space-y-3" aria-labelledby="readiness-h">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 id="readiness-h" className="text-sm font-semibold text-ink">
          Ready to activate?
        </h3>
        {readiness.ready ? (
          <StatusBadge status="Ready" tone="success" />
        ) : (
          <StatusBadge status={`${readiness.blocking_count} blocking`} tone="risk" />
        )}
      </div>
      <ProgressBar percent={readiness.percent} label={`${readiness.required_done} of ${readiness.required_total} required items done`} />
      {readiness.next_action && <p className="text-sm text-ink">{readiness.next_action}</p>}
      {groups.map((g) => (
        <div key={g.owner}>
          <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">{g.label}</p>
          <ul className="space-y-1">
            {g.items.map((b, i) => (
              <li key={`${b.code}-${i}`} className="flex items-start justify-between gap-2 text-sm">
                <span className="text-ink">
                  <span aria-hidden="true" className="mr-1 text-brand-risk">
                    ●
                  </span>
                  {b.message}
                  {b.due_date && <span className="ml-1 text-xs text-muted">· due {fmtDate(b.due_date)}</span>}
                </span>
                {b.task_id && onTask && (
                  <button type="button" className="shrink-0 text-xs font-semibold text-brand-blue hover:underline" onClick={() => onTask(b.task_id!)}>
                    Open
                  </button>
                )}
              </li>
            ))}
          </ul>
        </div>
      ))}
      {readiness.warnings.length > 0 && (
        <div>
          <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Warnings</p>
          <ul className="space-y-1">
            {readiness.warnings.map((w, i) => (
              <li key={`${w.code}-${i}`} className="text-sm text-brand-warning-solid">
                {w.message}
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  )
}

/**
 * Asks for a reason (required unless `optional`) before an action. Used for
 * every decision the server audits with a reason.
 */
export function ReasonModal({
  open,
  title,
  prompt,
  confirmLabel,
  danger,
  optional,
  onCancel,
  onConfirm,
  children,
}: {
  open: boolean
  title: string
  prompt: string
  confirmLabel: string
  danger?: boolean
  optional?: boolean
  onCancel: () => void
  onConfirm: (reason: string) => Promise<string | null>
  children?: ReactNode
}) {
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    if (open) {
      setReason('')
      setError(null)
    }
  }, [open])
  async function go() {
    if (!optional && !reason.trim()) return setError('A reason is required.')
    setBusy(true)
    const err = await onConfirm(reason.trim())
    setBusy(false)
    if (err) setError(err)
  }
  return (
    <Modal
      open={open}
      title={title}
      onClose={onCancel}
      footer={
        <>
          <button className="btn-secondary" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          <button className={danger ? 'btn-danger' : 'btn-primary'} onClick={go} disabled={busy}>
            {busy ? 'Saving…' : confirmLabel}
          </button>
        </>
      }
    >
      {children}
      <label className="block">
        <span className="label">
          {prompt}
          {!optional && <span className="text-brand-risk"> *</span>}
        </span>
        <textarea className="input min-h-20" value={reason} onChange={(e) => setReason(e.target.value)} data-autofocus aria-invalid={Boolean(error)} />
      </label>
      {error && <p className="text-xs font-medium text-brand-risk-text">{error}</p>}
    </Modal>
  )
}

export function Section({ title, actions, children, id }: { title: string; actions?: ReactNode; children: ReactNode; id: string }) {
  return (
    <section className="card space-y-3" aria-labelledby={id}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 id={id} className="text-sm font-semibold text-ink">
          {title}
        </h3>
        {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
      </div>
      {children}
    </section>
  )
}
