import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../../auth/AuthContext'
import { Alert, Drawer, Modal, Skeleton } from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import {
  cancelOffboarding,
  completeOffboarding,
  completeOffboardingTask,
  getOffboardingCase,
  startOffboardingSettlement,
  updateOffboardingDates,
  type OffboardingCase,
  type OffboardingTask,
} from '../../lib/api/offboarding'
import { OFF_OWNER_LABEL, SEPARATION_LABEL } from '../../lib/offboarding'
import { openOffboardingLetterForPrint } from '../../lib/offboardingLetter'
import { fmtDate, fmtDateTime, todayDubai } from '../../lib/format'
import { fmtMoney } from '../../lib/payroll'
import { ReasonModal, Section } from '../onboarding/shared'

export default function CaseDrawer({ caseId, onClose, onChanged }: { caseId: string | null; onClose: () => void; onChanged: () => void }) {
  const { entities, activeEntityId } = useAuth()
  const companyName = entities.find((e) => e.id === activeEntityId)?.name ?? 'the company'
  const [d, setD] = useState<OffboardingCase | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [skip, setSkip] = useState<OffboardingTask | null>(null)
  const [dates, setDates] = useState(false)
  const [finish, setFinish] = useState<'complete' | 'cancel' | null>(null)
  const today = todayDubai()

  const load = useCallback(async () => {
    if (!caseId) return
    const r = await getOffboardingCase(caseId)
    if (r.error) setError(r.error)
    setD(r.data)
  }, [caseId])
  useEffect(() => {
    setD(null)
    setError(null)
    setNotice(null)
    load()
  }, [load])

  async function act(fn: () => Promise<{ error: string | null }>, ok: string): Promise<string | null> {
    setBusy(true)
    setError(null)
    const r = await fn()
    setBusy(false)
    if (r.error) {
      setError(r.error)
      return r.error
    }
    setNotice(ok)
    await load()
    onChanged()
    return null
  }

  const c = d?.case
  const p = d?.permissions
  const open = c?.status === 'open'
  const canDo = (t: OffboardingTask) => (t.owner_role === 'location_manager' ? p?.operate : t.owner_role === 'payroll' ? p?.payroll : p?.manage)
  const openRequired = d?.tasks.filter((t) => t.is_required && t.status === 'not_started').length ?? 0
  const settlementTask = d?.tasks.find((t) => t.item_key === 'final_settlement')

  return (
    <Drawer open={Boolean(caseId)} wide title={d ? d.employee.name : 'Offboarding'} description={d ? [d.employee.position, d.employee.branch].filter(Boolean).join(' · ') : undefined} onClose={onClose}>
      {!d || !c ? (
        error ? <Alert tone="error">{error}</Alert> : <Skeleton rows={5} className="h-14" />
      ) : (
        <div className="space-y-4">
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

          <Section
            title="Leaving"
            id="off-summary"
            actions={
              p?.manage && (
                <div className="flex gap-2">
                  <button className="btn-ghost min-h-9" onClick={() => openOffboardingLetterForPrint(d, companyName)}>
                    Print letter (EN/AR)
                  </button>
                  {open && (
                    <button className="btn-secondary min-h-9" onClick={() => setDates(true)}>
                      Change dates
                    </button>
                  )}
                </div>
              )
            }
          >
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
              <dt className="text-muted">Type</dt>
              <dd className="flex items-center gap-2 text-ink">
                {SEPARATION_LABEL[c.separation_type]} <StatusBadge status={c.status} />
              </dd>
              <dt className="text-muted">Notice given</dt>
              <dd className="text-ink">
                {fmtDate(c.notice_date)} · {d.notice_days} days (minimum {c.min_notice_days}
                {c.in_probation ? ', in probation' : ''})
              </dd>
              <dt className="text-muted">Last working day</dt>
              <dd className="text-ink">{fmtDate(c.last_working_date)}</dd>
              <dt className="text-muted">Final settlement due</dt>
              <dd className={c.settlement_due_date < today && open ? 'text-brand-risk-text' : 'text-ink'}>{fmtDate(c.settlement_due_date)}</dd>
              <dt className="text-muted">Joined</dt>
              <dd className="text-ink">{fmtDate(d.employee.join_date)}</dd>
              {c.reason && (
                <>
                  <dt className="text-muted">Reason</dt>
                  <dd className="text-ink">{c.reason}</dd>
                </>
              )}
              {c.notice_shortfall_reason && (
                <>
                  <dt className="text-muted">Short notice</dt>
                  <dd className="text-ink">{c.notice_shortfall_reason}</dd>
                </>
              )}
            </dl>
            {d.future_published_shifts > 0 && (
              <Alert tone="warning">
                {d.future_published_shifts} published shift(s) after the last day.{' '}
                <Link to="/schedules" className="font-semibold underline">
                  Reassign in Schedules
                </Link>
              </Alert>
            )}
          </Section>

          <Section title="Checklist" id="off-tasks">
            <ul className="divide-y divide-border">
              {d.tasks.map((t) => (
                <li key={t.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                  <span className="min-w-0">
                    <span className={t.status === 'not_needed' ? 'text-muted line-through' : 'text-ink'}>{t.label}</span>
                    {!t.is_required && <span className="ml-1 text-xs text-muted">(optional)</span>}
                    <span className="block text-xs text-muted">
                      {OFF_OWNER_LABEL[t.owner_role]}
                      {t.status === 'not_started' && t.due_date ? ` · by ${fmtDate(t.due_date)}` : ''}
                      {t.overdue && <span className="text-brand-risk-text"> · overdue</span>}
                      {t.completed_at && ` · ${fmtDate(t.completed_at)}`}
                    </span>
                    {t.notes && <span className="block text-xs text-muted">{t.notes}</span>}
                  </span>
                  <span className="flex items-center gap-2">
                    {t.status === 'not_started' ? (
                      open &&
                      canDo(t) && (
                        <>
                          {(!t.is_required || p?.manage) && (
                            <button className="btn-ghost min-h-9" disabled={busy} onClick={() => setSkip(t)}>
                              Not needed
                            </button>
                          )}
                          <button className="btn-primary min-h-9" disabled={busy} onClick={() => act(() => completeOffboardingTask(t.id, 'done', null), `${t.label}: done.`)}>
                            Done
                          </button>
                        </>
                      )
                    ) : (
                      <>
                        <StatusBadge status={t.status === 'done' ? 'Done' : 'Not needed'} tone={t.status === 'done' ? 'success' : 'neutral'} />
                        {open && canDo(t) && (
                          <button className="btn-ghost min-h-9 text-xs" disabled={busy} onClick={() => act(() => completeOffboardingTask(t.id, 'not_started', null), 'Reopened.')}>
                            Undo
                          </button>
                        )}
                      </>
                    )}
                  </span>
                </li>
              ))}
            </ul>
          </Section>

          {d.settlement && (
            <Section
              title="Final settlement"
              id="off-settlement"
              actions={
                <Link to="/payroll" className="text-sm font-medium text-brand-blue hover:underline">
                  Open Payroll
                </Link>
              }
            >
              <p className="text-sm text-ink">
                Pay within 14 days of the last working day: by <strong>{fmtDate(d.settlement.due_date)}</strong>.
              </p>
              {d.settlement.payroll_period_id ? (
                <Alert tone={settlementTask?.status === 'done' ? 'success' : 'info'}>
                  {settlementTask?.status === 'done'
                    ? 'Paid. The checklist item completed on its own.'
                    : 'An off-cycle payroll run is open for this settlement. Add the final amounts and approve/pay it in Payroll — the checklist item completes on its own once it is paid.'}
                </Alert>
              ) : (
                open &&
                (p?.manage || p?.payroll) && (
                  <button
                    className="btn-secondary min-h-9"
                    disabled={busy}
                    onClick={() => act(() => startOffboardingSettlement(c.id, null), 'Off-cycle payroll run opened for the final settlement.')}
                  >
                    Start settlement in Payroll
                  </button>
                )
              )}
              {d.settlement.gratuity && (
                <div className="rounded-lg bg-surface-alt p-3 text-sm">
                  {d.settlement.gratuity.ok ? (
                    <>
                      <p className="font-semibold text-ink">End-of-service gratuity (estimate): {fmtMoney(d.settlement.gratuity.amount ?? 0)}</p>
                      <p className="text-muted">{d.settlement.gratuity.explanation}</p>
                      {d.settlement.gratuity.note && <p className="text-xs text-muted">{d.settlement.gratuity.note}</p>}
                    </>
                  ) : (
                    <p className="text-muted">Gratuity: {d.settlement.gratuity.reason}</p>
                  )}
                </div>
              )}
              {d.settlement.leave_balances.length > 0 && (
                <p className="text-sm text-muted">
                  Leave balances to settle: {d.settlement.leave_balances.map((b) => `${b.leave_type} ${b.balance_days} days`).join(', ')}.
                </p>
              )}
            </Section>
          )}

          {open && p?.manage && (
            <div className="flex flex-wrap gap-2">
              <button
                className="btn-primary"
                disabled={busy || openRequired > 0 || c.last_working_date > today}
                title={c.last_working_date > today ? 'After the last working day' : openRequired ? 'Finish the required checklist first' : undefined}
                onClick={() => setFinish('complete')}
              >
                Finish offboarding
              </button>
              <button className="btn-ghost text-brand-risk-text" disabled={busy} onClick={() => setFinish('cancel')}>
                Cancel (employee stays)
              </button>
              {openRequired > 0 && <span className="self-center text-xs text-muted">{openRequired} required item(s) left.</span>}
            </div>
          )}

          {d.timeline && d.timeline.length > 0 && (
            <details className="card">
              <summary className="cursor-pointer text-sm font-semibold text-ink">History ({d.timeline.length})</summary>
              <ul className="mt-2 space-y-1 text-sm">
                {d.timeline.map((h, i) => (
                  <li key={i} className="flex justify-between gap-3">
                    <span>{h.action.replace(/_/g, ' ')}</span>
                    <span className="shrink-0 text-xs text-muted">
                      {h.by ?? 'System'} · {fmtDateTime(h.at)}
                    </span>
                  </li>
                ))}
              </ul>
            </details>
          )}
        </div>
      )}

      {d && c && (
        <>
          <ReasonModal
            open={Boolean(skip)}
            title={`Not needed: ${skip?.label ?? ''}`}
            prompt="Why?"
            confirmLabel="Save"
            onCancel={() => setSkip(null)}
            onConfirm={async (r) => {
              const e = skip ? await act(() => completeOffboardingTask(skip.id, 'not_needed', r), 'Marked not needed.') : null
              if (!e) setSkip(null)
              return e
            }}
          />
          <ReasonModal
            open={finish === 'complete'}
            title={`Finish offboarding ${d.employee.name}?`}
            prompt="Closing notes"
            optional
            confirmLabel="Finish"
            onCancel={() => setFinish(null)}
            onConfirm={async (r) => {
              const e = await act(() => completeOffboarding(c.id, r || null), `${d.employee.name} is now inactive. Their login is closed.`)
              if (!e) setFinish(null)
              return e
            }}
          >
            <p>The employee becomes inactive and their login is closed. Draft future shifts are cancelled. Open onboarding and visa tracking are closed.</p>
          </ReasonModal>
          <ReasonModal
            open={finish === 'cancel'}
            title="Cancel offboarding"
            prompt="Why (e.g. resignation withdrawn)?"
            danger
            confirmLabel="Cancel offboarding"
            onCancel={() => setFinish(null)}
            onConfirm={async (r) => {
              const e = await act(() => cancelOffboarding(c.id, r), 'Offboarding cancelled. The last working day was cleared.')
              if (!e) setFinish(null)
              return e
            }}
          />
          {dates && (
            <DatesEditor
              d={d}
              onClose={() => setDates(false)}
              onSave={async (n, l, reason, shortfall) => {
                const e = await act(() => updateOffboardingDates(c.id, n, l, reason, c.row_version, shortfall || null), 'Dates updated; payroll uses the new last day.')
                if (!e) setDates(false)
                return e
              }}
            />
          )}
        </>
      )}
    </Drawer>
  )
}

function DatesEditor({ d, onClose, onSave }: { d: OffboardingCase; onClose: () => void; onSave: (n: string, l: string, r: string, s: string) => Promise<string | null> }) {
  const [n, setN] = useState(d.case.notice_date)
  const [l, setL] = useState(d.case.last_working_date)
  const [r, setR] = useState('')
  const [s, setS] = useState('')
  const [err, setErr] = useState<string | null>(null)
  return (
    <Modal
      open
      title="Change dates"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            onClick={async () => {
              if (!r.trim()) return setErr('A reason is required.')
              const e = await onSave(n, l, r.trim(), s.trim())
              if (e) setErr(e)
            }}
          >
            Save
          </button>
        </>
      }
    >
      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="label">Notice date</span>
          <input type="date" className="input" value={n} onChange={(e) => setN(e.target.value)} />
        </label>
        <label className="block">
          <span className="label">Last working day</span>
          <input type="date" className="input" value={l} min={n} onChange={(e) => setL(e.target.value)} />
        </label>
      </div>
      <label className="block">
        <span className="label">Reason *</span>
        <textarea className="input min-h-16" value={r} onChange={(e) => setR(e.target.value)} />
      </label>
      <label className="block">
        <span className="label">If the notice is now shorter than {d.case.min_notice_days} days, why?</span>
        <input className="input" value={s} onChange={(e) => setS(e.target.value)} />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}
