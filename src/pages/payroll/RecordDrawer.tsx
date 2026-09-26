import { useCallback, useEffect, useState } from 'react'
import { Alert, Drawer, Skeleton } from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import {
  addAdjustment,
  addComponent,
  approve,
  createCorrection,
  endComponent,
  getRecordDetail,
  gratuityPreview,
  importAttendance,
  publish,
  reasonError,
  recalculate,
  returnToDraft,
  setCompensation,
  setHours,
  setLastWorkingDate,
  submitForReview,
  voidAdjustment,
  type BulkResult,
  type RecordDetail,
  type Workspace,
} from '../../lib/api/payroll'
import { buildPayslipPdf, payslipFilename } from '../../lib/payslipPdf'
import { downloadBytes } from '../../lib/pdf'
import { detailToPdfData, fmtMoney, PAYMENT_STATUS_LABEL, periodLabel, RECORD_STATUS_LABEL } from '../../lib/payroll'
import { fmtDate, fmtDateTime, humanize } from '../../lib/format'
import BulkActionModal, { ResultSummary } from './BulkActionModal'
import { DEDUCTION_CODES, EARNING_CODES } from './options'

const ALLOWANCE_CODES = [
  { value: 'housing', label: 'Housing allowance', kind: 'earning' },
  { value: 'transport', label: 'Transport allowance', kind: 'earning' },
  { value: 'food', label: 'Food allowance', kind: 'earning' },
  { value: 'phone', label: 'Phone allowance', kind: 'earning' },
  { value: 'other_allowance', label: 'Other allowance', kind: 'earning' },
  { value: 'accommodation_deduction', label: 'Accommodation deduction', kind: 'deduction' },
  { value: 'other_deduction', label: 'Other recurring deduction', kind: 'deduction' },
] as const

export default function RecordDrawer({
  recordId,
  workspace,
  onClose,
  onChanged,
  onOpenRecord,
}: {
  recordId: string
  workspace: Workspace
  onClose: () => void
  onChanged: () => void
  onOpenRecord: (id: string) => void
}) {
  const [d, setD] = useState<RecordDetail | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ title: string; res: BulkResult } | null>(null)
  const [busy, setBusy] = useState(false)
  const [paying, setPaying] = useState(false)
  const [prompt, setPrompt] = useState<null | { kind: 'return' | 'correct' | 'void'; id?: string }>(null)
  const [promptText, setPromptText] = useState('')
  const cur = workspace.entity.currency
  const perms = workspace.permissions
  const reviewMode = workspace.settings.approval_mode === 'review_then_approve'

  const load = useCallback(async () => {
    const res = await getRecordDetail(recordId)
    if (res.error) setErr(res.error)
    else setD(res.data)
  }, [recordId])
  useEffect(() => {
    setD(null)
    load()
  }, [load])

  async function act(title: string, p: Promise<{ data: BulkResult | null; error: string | null }>) {
    setBusy(true)
    setErr(null)
    const res = await p
    setBusy(false)
    if (res.error) return setErr(res.error)
    if (res.data) setNotice({ title, res: res.data })
    await load()
    onChanged()
  }

  if (!d) {
    return (
      <Drawer open wide title="Loading…" onClose={onClose}>
        {err ? <Alert tone="error">{err}</Alert> : <Skeleton rows={6} className="h-10" />}
      </Drawer>
    )
  }

  const r = d.row
  const draft = r.record_status === 'draft'
  const blocking = r.attention.filter((a) => a.severity === 'blocking')
  const earnings = d.lines.filter((l) => l.kind === 'earning')
  const deductions = d.lines.filter((l) => l.kind === 'deduction')
  const info = d.lines.filter((l) => l.kind === 'info')

  // Why an action is unavailable, in plain words (null = available).
  const approveBlock = !perms.approve
    ? 'You do not have approval permission.'
    : r.record_status === 'approved'
      ? 'Already approved.'
      : reviewMode && r.record_status !== 'in_review'
        ? 'Send it for review first.'
        : blocking.length
          ? 'Fix the items marked “Fix needed” first.'
          : null
  const returnBlock = !perms.prepare
    ? 'You do not have permission to change payroll.'
    : draft
      ? null
      : r.paid > 0
        ? 'A payment is recorded, so it cannot go back to draft. Create a correction instead.'
        : null

  return (
    <Drawer
      open
      wide
      title={d.employee.name}
      description={`${periodLabel(d.period)} · ${r.branch ?? 'No branch'}${r.position ? ` · ${r.position}` : ''}`}
      onClose={onClose}
      footer={
        <>
          <button
            className="btn-secondary"
            onClick={() => {
              const pdf = detailToPdfData(d, workspace.entity)
              downloadBytes(buildPayslipPdf(pdf), payslipFilename(pdf))
            }}
          >
            Download payslip
          </button>
          {perms.prepare && draft && (
            <button className="btn-secondary" disabled={busy} onClick={() => act('Recalculated', recalculate([r.record_id]))}>
              Recalculate
            </button>
          )}
          {perms.prepare && reviewMode && draft && (
            <button className="btn-secondary" disabled={busy || blocking.length > 0} onClick={() => act('Sent for review', submitForReview([r.record_id]))}>
              Send for review
            </button>
          )}
          {perms.prepare && r.record_status !== 'draft' && (
            <button className="btn-secondary" disabled={busy || !!returnBlock} title={returnBlock ?? undefined} onClick={() => setPrompt({ kind: 'return' })}>
              Return to draft
            </button>
          )}
          {perms.prepare && r.record_status === 'approved' && r.paid > 0 && (
            <button className="btn-secondary" disabled={busy} onClick={() => setPrompt({ kind: 'correct' })}>
              Create correction
            </button>
          )}
          {perms.approve && r.record_status === 'approved' && !r.published_at && (
            <button className="btn-secondary" disabled={busy} onClick={() => act('Published', publish([r.record_id]))}>
              Publish payslip
            </button>
          )}
          {perms.pay && r.record_status === 'approved' && (r.outstanding ?? 0) > 0 && (
            <button className="btn-secondary" onClick={() => setPaying(true)}>
              Record payment
            </button>
          )}
          {r.record_status !== 'approved' && (
            <button
              className="btn-primary"
              disabled={busy || !!approveBlock}
              title={approveBlock ?? undefined}
              onClick={() => act('Approved', approve([{ record_id: r.record_id, calc_version: r.calc_version }], false))}
            >
              Approve
            </button>
          )}
        </>
      }
    >
      <div className="space-y-5">
        {err && (
          <Alert tone="error" onDismiss={() => setErr(null)}>
            {err}
          </Alert>
        )}
        {notice && <ResultSummary title={notice.title} res={notice.res} currency={cur} onClose={() => setNotice(null)} />}

        {/* --------------------------------------------------- headline */}
        <section className="flex flex-wrap items-center gap-2">
          <StatusBadge status={RECORD_STATUS_LABEL[r.record_status]} tone={r.record_status === 'approved' ? 'success' : 'neutral'} />
          {r.record_status === 'approved' && PAYMENT_STATUS_LABEL[r.payment_status] && (
            <StatusBadge status={PAYMENT_STATUS_LABEL[r.payment_status]} tone={r.payment_status === 'paid' ? 'success' : 'warning'} />
          )}
          {r.published_at && <StatusBadge status="Published" tone="info" />}
          {r.is_correction && <StatusBadge status="Correction" tone="info" />}
          <span className="ml-auto text-right">
            <span className="block text-xs text-muted">Net pay</span>
            <span className="text-xl font-semibold tabular-nums text-ink">{fmtMoney(r.net, cur)}</span>
            {r.record_status === 'approved' && (
              <span className="block text-xs text-muted">
                Paid {fmtMoney(r.paid, cur)} · outstanding {fmtMoney(r.outstanding, cur)}
              </span>
            )}
          </span>
        </section>
        {d.record.correction_reason && <Alert tone="info">Correction: {d.record.correction_reason}. Payments already made count toward it.</Alert>}
        {r.returned_reason && draft && <Alert tone="info">Returned to draft: {r.returned_reason}</Alert>}
        {!draft && <p className="text-xs text-muted">This record is frozen. Return it to draft (or create a correction once paid) to change it.</p>}

        {r.attention.length > 0 && (
          <section aria-label="Needs attention" className="space-y-1">
            {r.attention.map((a, i) => (
              <Alert key={i} tone={a.severity === 'blocking' ? 'error' : a.severity === 'warning' ? 'warning' : 'info'}>
                {a.message}
              </Alert>
            ))}
          </section>
        )}

        {/* ------------------------------------------------------ lines */}
        <LineTable title="Earnings" lines={earnings} currency={cur} total={r.gross} />
        <LineTable title="Deductions" lines={deductions} currency={cur} total={r.deductions} negative />
        {info.length > 0 && <LineTable title="For information (not in net pay)" lines={info} currency={cur} />}
        <p className="flex justify-between border-t border-border pt-2 text-sm font-semibold">
          <span>Net pay = earnings − deductions</span>
          <span className="tabular-nums">{fmtMoney(r.net, cur)}</span>
        </p>

        {/* ------------------------------------------------------ hours */}
        {perms.prepare && <HoursEditor d={d} disabled={!draft} onSaved={() => (load(), onChanged())} setErr={setErr} periodId={workspace.period.id} />}

        {/* ------------------------------------------------ adjustments */}
        <section>
          <h3 className="mb-2 text-sm font-semibold text-ink">One-off earnings and deductions</h3>
          {d.adjustments.length === 0 && <p className="text-sm text-muted">None this month.</p>}
          <ul className="space-y-1 text-sm">
            {d.adjustments.map((a) => (
              <li key={a.id} className={`flex items-center justify-between gap-2 ${a.voided_at ? 'text-muted line-through' : ''}`}>
                <span>
                  {humanize(a.code)} · {a.reason}
                  {a.voided_at && <span className="no-underline"> (removed: {a.void_reason})</span>}
                </span>
                <span className="flex items-center gap-2 tabular-nums">
                  {a.kind === 'deduction' ? '−' : '+'}
                  {fmtMoney(a.amount, cur)}
                  {!a.voided_at && draft && perms.prepare && (
                    <button className="btn-ghost text-xs" onClick={() => setPrompt({ kind: 'void', id: a.id })}>
                      Remove
                    </button>
                  )}
                </span>
              </li>
            ))}
          </ul>
          {perms.prepare && draft && (
            <QuickAdjust
              onAdd={async (a) => {
                const res = await addAdjustment(workspace.period.id, [d.employee.id], { ...a, mode: 'individual' }, false)
                if (res.error) return setErr(res.error)
                await load()
                onChanged()
              }}
              currency={cur}
            />
          )}
        </section>

        {/* ---------------------------------------------------- pay setup */}
        {perms.settings && <PaySetup d={d} currency={cur} onSaved={() => (load(), onChanged())} setErr={setErr} />}

        {/* ------------------------------------------- leaving / gratuity */}
        {perms.prepare && <LeavingSection d={d} currency={cur} onSaved={() => (load(), onChanged())} setErr={setErr} />}

        {/* ---------------------------------------------------- advances */}
        {d.advances.length > 0 && (
          <section>
            <h3 className="mb-2 text-sm font-semibold text-ink">Advances</h3>
            <ul className="space-y-1 text-sm">
              {d.advances.map((a) => (
                <li key={a.id}>
                  {fmtMoney(a.amount, cur)} paid {fmtDate(a.disbursed_on)} · {a.instalments} × {fmtMoney(a.instalment_amount, cur)} from{' '}
                  {fmtDate(a.repayment_start)} · <strong>{fmtMoney(a.outstanding, cur)} outstanding</strong> ({a.status})
                </li>
              ))}
            </ul>
          </section>
        )}

        {/* ---------------------------------------------------- payments */}
        <section>
          <h3 className="mb-2 text-sm font-semibold text-ink">Payment history</h3>
          {d.payments.length === 0 ? (
            <p className="text-sm text-muted">No payments recorded.</p>
          ) : (
            <ul className="space-y-1 text-sm">
              {d.payments.map((p) => (
                <li key={p.id} className={p.status === 'failed' ? 'text-brand-risk-text' : ''}>
                  {fmtDate(p.paid_on)} · {humanize(p.method)} · {fmtMoney(p.amount, cur)} {p.reference ? `· ${p.reference}` : ''}
                  {p.status === 'failed' ? ` · FAILED: ${p.failure_reason}` : ''}
                </li>
              ))}
            </ul>
          )}
        </section>

        {d.history.length > 1 && (
          <section>
            <h3 className="mb-2 text-sm font-semibold text-ink">Versions</h3>
            <ul className="space-y-1 text-sm">
              {d.history.map((h, i) => (
                <li key={h.id}>
                  {i === 0 ? 'Current' : `Earlier (${h.status})`} · {fmtMoney(h.net, cur)}
                  {h.correction_reason ? ` · ${h.correction_reason}` : ''}
                  {i > 0 && (
                    <span className="text-muted"> · approved {fmtDateTime(h.approved_at)}</span>
                  )}
                  {i > 0 && h.id !== d.record.id && (
                    <button className="btn-ghost ml-1 text-xs" onClick={() => onOpenRecord(h.id)}>
                      View
                    </button>
                  )}
                </li>
              ))}
            </ul>
          </section>
        )}

        {d.audit.length > 0 && (
          <details>
            <summary className="cursor-pointer text-sm font-semibold text-ink">Activity</summary>
            <ul className="mt-2 space-y-1 text-xs text-muted">
              {d.audit.map((a, i) => (
                <li key={i}>
                  {fmtDateTime(a.at)} · {humanize(a.action.replace(/^payroll_/, ''))}
                  {a.by ? ` · ${a.by}` : ''}
                </li>
              ))}
            </ul>
          </details>
        )}
      </div>

      {prompt && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink/40 px-4" role="dialog" aria-modal="true" aria-label="Reason">
          <div className="w-full max-w-md rounded-[14px] border border-border bg-surface p-5 shadow-card">
            <h2 className="mb-2 text-base font-semibold">
              {prompt.kind === 'return' ? 'Return to draft' : prompt.kind === 'correct' ? 'Create a correction' : 'Remove adjustment'}
            </h2>
            <p className="mb-2 text-sm text-muted">
              {prompt.kind === 'correct'
                ? 'The paid record is kept unchanged. A new draft is created; after approval only the difference is outstanding.'
                : prompt.kind === 'return'
                  ? 'Approval is undone and any exported payment list with this employee becomes void.'
                  : 'The adjustment is kept in history and no longer counts.'}
            </p>
            <label className="block">
              <span className="label">Reason</span>
              <input className="input" value={promptText} onChange={(e) => setPromptText(e.target.value)} autoFocus />
            </label>
            <div className="mt-4 flex justify-end gap-2">
              <button className="btn-secondary" onClick={() => (setPrompt(null), setPromptText(''))}>
                Cancel
              </button>
              <button
                className="btn-primary"
                disabled={!promptText.trim() || busy}
                onClick={async () => {
                  const text = promptText
                  const p = prompt
                  setPrompt(null)
                  setPromptText('')
                  if (p.kind === 'return') return act('Returned to draft', returnToDraft([r.record_id], text))
                  if (p.kind === 'void' && p.id) {
                    const e = reasonError(await voidAdjustment(p.id, text))
                    if (e) setErr(e)
                    await load()
                    return onChanged()
                  }
                  const res = await createCorrection(r.record_id, text)
                  const e = reasonError(res)
                  if (e) return setErr(e)
                  onChanged()
                  if (res.data?.record_id) onOpenRecord(res.data.record_id)
                }}
              >
                Confirm
              </button>
            </div>
          </div>
        </div>
      )}

      {paying && (
        <BulkActionModal
          action="pay"
          workspace={workspace}
          rows={[r]}
          onClose={() => setPaying(false)}
          onDone={async (title, res) => {
            setPaying(false)
            if (res) setNotice({ title, res })
            await load()
            onChanged()
          }}
        />
      )}
    </Drawer>
  )
}

function LineTable({
  title,
  lines,
  currency,
  total,
  negative,
}: {
  title: string
  lines: RecordDetail['lines']
  currency: string
  total?: number
  negative?: boolean
}) {
  return (
    <section>
      <h3 className="mb-2 text-sm font-semibold text-ink">{title}</h3>
      {lines.length === 0 ? (
        <p className="text-sm text-muted">None.</p>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {lines.map((l) => (
            <li key={l.id} className="px-3 py-2">
              <div className="flex justify-between gap-3 text-sm">
                <span className="font-medium text-ink">{l.label}</span>
                <span className="tabular-nums">
                  {negative ? '− ' : ''}
                  {fmtMoney(l.amount, currency)}
                </span>
              </div>
              <p className="mt-0.5 text-xs text-muted">{l.explanation}</p>
            </li>
          ))}
        </ul>
      )}
      {total != null && lines.length > 0 && (
        <p className="mt-1 flex justify-between text-sm text-muted">
          <span>Total {title.toLowerCase()}</span>
          <span className="tabular-nums">{fmtMoney(total, currency)}</span>
        </p>
      )}
    </section>
  )
}

function HoursEditor({
  d,
  disabled,
  onSaved,
  setErr,
  periodId,
}: {
  d: RecordDetail
  disabled: boolean
  onSaved: () => void
  setErr: (e: string | null) => void
  periodId: string
}) {
  const h = d.hours
  const [v, setV] = useState({
    regular: String(h?.regular_hours ?? 0),
    overtime: String(h?.overtime_hours ?? 0),
    night: String(h?.night_overtime_hours ?? 0),
    holiday: String(h?.holiday_hours ?? 0),
  })
  const [confirm, setConfirm] = useState(h?.status === 'confirmed')
  const [saving, setSaving] = useState(false)
  const field = (k: keyof typeof v, label: string) => (
    <label>
      <span className="label">{label}</span>
      <input className="input" inputMode="decimal" value={v[k]} disabled={disabled} onChange={(e) => setV({ ...v, [k]: e.target.value })} />
    </label>
  )
  return (
    <section>
      <h3 className="mb-1 text-sm font-semibold text-ink">Hours this month</h3>
      <p className="mb-2 text-xs text-muted">
        {h ? `${h.source === 'attendance' ? 'From attendance' : 'Entered manually'} · ${h.status}` : 'No hours entered.'}{' '}
        {d.row.pay_type === 'monthly' ? 'Monthly staff are paid their salary without a timesheet; enter hours only for overtime.' : ''}
      </p>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        {d.row.pay_type === 'hourly' && field('regular', 'Regular hours')}
        {field('overtime', 'Overtime')}
        {field('night', 'Night OT (10pm–4am)')}
        {field('holiday', 'Rest day / holiday')}
      </div>
      {!disabled && (
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={confirm} onChange={(e) => setConfirm(e.target.checked)} /> Hours confirmed
          </label>
          <button
            className="btn-secondary"
            disabled={saving}
            onClick={async () => {
              setSaving(true)
              const res = await setHours(
                periodId,
                d.employee.id,
                { regular: Number(v.regular) || 0, overtime: Number(v.overtime) || 0, night: Number(v.night) || 0, holiday: Number(v.holiday) || 0 },
                confirm,
                null,
              )
              setSaving(false)
              const e = reasonError(res)
              if (e) return setErr(e)
              onSaved()
            }}
          >
            Save hours
          </button>
          <button
            className="btn-ghost"
            onClick={async () => {
              const res = await importAttendance(periodId, [d.employee.id])
              if (res.error) return setErr(res.error)
              if (res.data && res.data.processed === 0) setErr(res.data.skipped[0]?.reason ?? 'No approved attendance for this month.')
              onSaved()
            }}
          >
            Load from attendance
          </button>
        </div>
      )}
    </section>
  )
}

function QuickAdjust({
  onAdd,
  currency,
}: {
  onAdd: (a: { kind: 'earning' | 'deduction'; code: string; amount: number; reason: string }) => Promise<void>
  currency: string
}) {
  const [kind, setKind] = useState<'earning' | 'deduction'>('earning')
  const [code, setCode] = useState('bonus')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  return (
    <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-5">
      <select
        className="input"
        aria-label="Type"
        value={kind}
        onChange={(e) => {
          const k = e.target.value as 'earning' | 'deduction'
          setKind(k)
          setCode(k === 'earning' ? 'bonus' : 'cash_shortage')
        }}
      >
        <option value="earning">Add</option>
        <option value="deduction">Deduct</option>
      </select>
      <select className="input" aria-label="What for" value={code} onChange={(e) => setCode(e.target.value)}>
        {(kind === 'earning' ? EARNING_CODES : DEDUCTION_CODES).map((c) => (
          <option key={c.value} value={c.value}>
            {c.label}
          </option>
        ))}
      </select>
      <input className="input" aria-label={`Amount (${currency})`} placeholder="Amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
      <input className="input" aria-label="Reason" placeholder="Reason" value={reason} onChange={(e) => setReason(e.target.value)} />
      <button
        className="btn-secondary"
        disabled={!Number(amount) || !reason.trim()}
        onClick={async () => {
          await onAdd({ kind, code, amount: Number(amount), reason })
          setAmount('')
          setReason('')
        }}
      >
        Add
      </button>
    </div>
  )
}

function PaySetup({ d, currency, onSaved, setErr }: { d: RecordDetail; currency: string; onSaved: () => void; setErr: (e: string | null) => void }) {
  const cur = d.compensation[0]
  const [open, setOpen] = useState(false)
  const [from, setFrom] = useState(d.period.period_start)
  const [type, setType] = useState<'monthly' | 'hourly'>(cur?.pay_type ?? 'monthly')
  const [rate, setRate] = useState(String(cur?.basic_monthly ?? cur?.hourly_rate ?? ''))
  const [ot, setOt] = useState(cur?.overtime_eligible ?? true)
  const [reason, setReason] = useState('')
  const [comp, setComp] = useState({ code: 'housing', amount: '', from: d.period.period_start })
  return (
    <section>
      <h3 className="mb-2 text-sm font-semibold text-ink">Pay and allowances</h3>
      {d.compensation.length === 0 ? (
        <Alert tone="warning">No pay set.</Alert>
      ) : (
        <ul className="space-y-1 text-sm">
          {d.compensation.map((c, i) => (
            <li key={c.id} className={i > 0 ? 'text-muted' : ''}>
              From {fmtDate(c.effective_from)}:{' '}
              {c.pay_type === 'monthly' ? `${fmtMoney(c.basic_monthly, currency)} a month basic` : `${fmtMoney(c.hourly_rate, currency)} an hour`} ·{' '}
              {c.overtime_eligible ? 'overtime eligible' : 'no overtime'}
              {c.reason ? ` · ${c.reason}` : ''}
            </li>
          ))}
        </ul>
      )}
      {d.components.length > 0 && (
        <ul className="mt-2 space-y-1 text-sm">
          {d.components.map((c) => (
            <li key={c.id} className="flex items-center justify-between gap-2">
              <span>
                {c.label}: {c.kind === 'deduction' ? '−' : '+'}
                {fmtMoney(c.monthly_amount, currency)} a month from {fmtDate(c.effective_from)}
                {c.effective_to ? ` to ${fmtDate(c.effective_to)}` : ''}
              </span>
              {!c.effective_to && (
                <button
                  className="btn-ghost text-xs"
                  onClick={async () => {
                    const res = await endComponent(c.id, d.period.period_end, 'Ended from payroll')
                    if (res.error) return setErr(res.error)
                    onSaved()
                  }}
                >
                  End after this month
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
      <button className="btn-ghost mt-1 text-sm" onClick={() => setOpen(!open)}>
        {open ? 'Close' : 'Change pay or add an allowance'}
      </button>
      {open && (
        <div className="mt-2 space-y-3 rounded-lg border border-border p-3">
          <div className="grid gap-2 sm:grid-cols-2">
            <label>
              <span className="label">Takes effect from</span>
              <input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} />
            </label>
            <label>
              <span className="label">Pay type</span>
              <select className="input" value={type} onChange={(e) => setType(e.target.value as 'monthly' | 'hourly')}>
                <option value="monthly">Monthly salary</option>
                <option value="hourly">Hourly</option>
              </select>
            </label>
            <label>
              <span className="label">{type === 'monthly' ? `Basic salary a month (${currency})` : `Rate an hour (${currency})`}</span>
              <input className="input" inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} />
            </label>
            <label className="flex items-center gap-2 self-end text-sm">
              <input type="checkbox" checked={ot} onChange={(e) => setOt(e.target.checked)} /> Eligible for overtime pay
            </label>
            <label className="sm:col-span-2">
              <span className="label">Reason</span>
              <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Annual increase" />
            </label>
          </div>
          <button
            className="btn-secondary"
            onClick={async () => {
              const res = await setCompensation({
                employeeId: d.employee.id,
                effectiveFrom: from,
                payType: type,
                basicMonthly: type === 'monthly' ? Number(rate) : null,
                hourlyRate: type === 'hourly' ? Number(rate) : null,
                overtimeEligible: ot,
                reason: reason || null,
              })
              if (res.error) return setErr(res.error)
              setOpen(false)
              onSaved()
            }}
          >
            Save pay
          </button>
          <div className="grid gap-2 border-t border-border pt-3 sm:grid-cols-4">
            <select className="input" aria-label="Allowance" value={comp.code} onChange={(e) => setComp({ ...comp, code: e.target.value })}>
              {ALLOWANCE_CODES.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
            </select>
            <input className="input" aria-label="Monthly amount" placeholder="Monthly amount" inputMode="decimal" value={comp.amount} onChange={(e) => setComp({ ...comp, amount: e.target.value })} />
            <input type="date" className="input" aria-label="From" value={comp.from} onChange={(e) => setComp({ ...comp, from: e.target.value })} />
            <button
              className="btn-secondary"
              disabled={!Number(comp.amount)}
              onClick={async () => {
                const def = ALLOWANCE_CODES.find((c) => c.value === comp.code)!
                const res = await addComponent({
                  employeeId: d.employee.id,
                  kind: def.kind,
                  code: def.value,
                  label: def.label,
                  amount: Number(comp.amount),
                  prorate: true,
                  from: comp.from,
                  to: null,
                  reason: null,
                })
                if (res.error) return setErr(res.error)
                setComp({ ...comp, amount: '' })
                onSaved()
              }}
            >
              Add recurring item
            </button>
          </div>
        </div>
      )}
    </section>
  )
}

function LeavingSection({ d, currency, onSaved, setErr }: { d: RecordDetail; currency: string; onSaved: () => void; setErr: (e: string | null) => void }) {
  const [date, setDate] = useState(d.employee.last_working_date ?? '')
  const [grat, setGrat] = useState<{ amount?: number; explanation?: string; note?: string; reason?: string } | null>(null)
  return (
    <section>
      <h3 className="mb-1 text-sm font-semibold text-ink">Leaving (final settlement)</h3>
      <p className="mb-2 text-xs text-muted">
        Setting a last working day prorates this month. Final pay must be settled within 14 days of the contract ending (Decree-Law 33/2021 Art. 53).
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <label>
          <span className="label">Last working day</span>
          <input type="date" className="input" value={date} onChange={(e) => setDate(e.target.value)} />
        </label>
        <button
          className="btn-secondary"
          onClick={async () => {
            const res = await setLastWorkingDate(d.employee.id, date || null, 'Set from payroll')
            if (res.error) return setErr(res.error)
            onSaved()
          }}
        >
          Save
        </button>
        <button
          className="btn-ghost"
          disabled={!date}
          onClick={async () => {
            const res = await gratuityPreview(d.employee.id, date)
            if (res.error) return setErr(res.error)
            setGrat(res.data)
          }}
        >
          Estimate gratuity
        </button>
      </div>
      {grat && (
        <Alert tone="info">
          {grat.reason ?? (
            <>
              <strong>Gratuity estimate: {fmtMoney(grat.amount, currency)}</strong>. {grat.explanation} {grat.note} Add it as a “End-of-service
              gratuity” earning after checking the contract.
            </>
          )}
        </Alert>
      )}
    </section>
  )
}
