import { fmtDate, todayDubai } from '../../lib/format'
import { useEffect, useMemo, useState } from 'react'
import { Alert, Modal } from '../../components/ui'
import {
  addAdjustment,
  approve,
  createExport,
  getRecordDetail,
  preparePayroll,
  publish,
  recordPayments,
  returnToDraft,
  submitForReview,
  type BulkResult,
  type PaymentMethod,
  type PayrollRow,
  type Workspace,
} from '../../lib/api/payroll'
import { buildPayslipPdf, payslipFilename } from '../../lib/payslipPdf'
import { downloadBytes } from '../../lib/pdf'
import { DEDUCTION_CODES, EARNING_CODES, PAYMENT_METHODS } from './options'
import {
  detailToPdfData,
  fmtMoney,
  isPrepared,
  newRequestKey,
  partitionForAction,
  periodLabel,
  sumBy,
  toCsv,
  type AnyRow,
  type BulkAction,
} from '../../lib/payroll'

const TITLES: Record<BulkAction, string> = {
  prepare: 'Prepare or recalculate',
  recalculate: 'Recalculate',
  adjust: 'Add earning or deduction',
  review: 'Send for review',
  approve: 'Approve payroll',
  export: 'Export payment list',
  pay: 'Record payment',
  publish: 'Publish payslips',
  return: 'Return to draft',
  download: 'Download payslips',
}

export default function BulkActionModal({
  action,
  workspace,
  rows,
  onClose,
  onDone,
}: {
  action: BulkAction
  workspace: Workspace
  rows: AnyRow[]
  onClose: () => void
  onDone: (title: string, res: BulkResult | null) => void
}) {
  const currency = workspace.entity.currency
  const reviewMode = workspace.settings.approval_mode === 'review_then_approve'
  const { included, excluded } = useMemo(() => partitionForAction(rows, action, { reviewMode }), [rows, action, reviewMode])
  const prepared = included.filter(isPrepared) as PayrollRow[]
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [serverPreview, setServerPreview] = useState<BulkResult | null>(null)

  // adjust
  const [kind, setKind] = useState<'earning' | 'deduction'>('earning')
  const [code, setCode] = useState('bonus')
  const [amount, setAmount] = useState('')
  const [mode, setMode] = useState<'per_employee' | 'distributed'>('per_employee')
  const [reason, setReason] = useState('')
  // pay
  // Default: the month's pay date, or today (Dubai) if the pay date is still ahead — payments can't be future-dated.
  const todayStr = todayDubai()
  const payDay = workspace.pay_date ?? null
  const payDayAhead = !!payDay && payDay > todayStr
  const [paidOn, setPaidOn] = useState(payDay && !payDayAhead ? payDay : todayStr)
  const [method, setMethod] = useState<PaymentMethod>(workspace.settings.default_payment_method)
  const [reference, setReference] = useState('')
  const [payStatus, setPayStatus] = useState<'recorded' | 'failed'>('recorded')
  const [failureReason, setFailureReason] = useState('')
  const [customAmount, setCustomAmount] = useState('')
  // The same key is re-sent if the user retries, so nothing is recorded twice.
  const [requestKey] = useState(newRequestKey)

  const title = TITLES[action]
  const recordIds = prepared.map((r) => r.record_id)

  // Server-side preview for money-moving actions.
  useEffect(() => {
    setServerPreview(null)
    if (action === 'approve' && prepared.length) {
      approve(prepared.map((r) => ({ record_id: r.record_id, calc_version: r.calc_version })), true).then((res) => {
        if (res.error) setErr(res.error)
        else setServerPreview(res.data)
      })
    }
  }, [action]) // eslint-disable-line react-hooks/exhaustive-deps

  async function previewAdjust() {
    const amt = Number(amount)
    if (!amt || amt <= 0) return setErr('Enter an amount above zero.')
    if (!reason.trim()) return setErr('A reason is required.')
    setErr(null)
    const res = await addAdjustment(workspace.period.id, included.map((r) => r.employee_id), { kind, code, amount: amt, mode, reason }, true)
    if (res.error) setErr(res.error)
    else setServerPreview(res.data)
  }

  async function previewPay() {
    setErr(null)
    if (payStatus === 'failed' && !failureReason.trim()) return setErr('Say why the payment failed.')
    const single = prepared.length === 1 && customAmount ? Number(customAmount) : null
    const res = await recordPayments(
      prepared.map((r) => ({ record_id: r.record_id, amount: single })),
      { paidOn, method, reference, status: payStatus, failureReason: failureReason || null, requestKey },
      true,
    )
    if (res.error) setErr(res.error)
    else setServerPreview(res.data)
  }

  async function run() {
    setBusy(true)
    setErr(null)
    let res: { data: BulkResult | null; error: string | null } = { data: null, error: null }
    switch (action) {
      case 'prepare':
      case 'recalculate':
        res = await preparePayroll(workspace.period.id, included.map((r) => r.employee_id))
        break
      case 'adjust':
        res = await addAdjustment(
          workspace.period.id,
          included.map((r) => r.employee_id),
          { kind, code, amount: Number(amount), mode, reason },
          false,
        )
        break
      case 'review':
        res = await submitForReview(recordIds)
        break
      case 'approve':
        res = await approve(prepared.map((r) => ({ record_id: r.record_id, calc_version: r.calc_version })), false)
        break
      case 'publish':
        res = await publish(recordIds)
        break
      case 'return':
        if (!reason.trim()) {
          setBusy(false)
          return setErr('A reason is required.')
        }
        res = await returnToDraft(recordIds, reason)
        break
      case 'pay': {
        const single = prepared.length === 1 && customAmount ? Number(customAmount) : null
        res = await recordPayments(
          prepared.map((r) => ({ record_id: r.record_id, amount: single })),
          { paidOn, method, reference, status: payStatus, failureReason: failureReason || null, requestKey },
          false,
        )
        break
      }
      case 'export': {
        const x = await createExport(recordIds)
        setBusy(false)
        if (x.error) return setErr(x.error)
        if (!x.data?.ok || !x.data.rows) return setErr(x.data?.reason ?? 'Nothing to export')
        const csv = toCsv(
          ['Employee', 'Branch', 'Amount to pay', 'Already paid', 'Currency', 'Record'],
          x.data.rows.map((r) => [r.name, r.branch, r.amount.toFixed(2), r.already_paid.toFixed(2), currency, r.record_id]),
        )
        downloadBytes(new TextEncoder().encode(csv), `payment-list-${workspace.period.period_start}.csv`, 'text/csv')
        return onDone('Payment list exported', { ok: true, processed: x.data.rows.length, total: x.data.total, skipped: x.data.skipped })
      }
      case 'download': {
        let n = 0
        const skipped: BulkResult['skipped'] = []
        for (const r of prepared) {
          const d = await getRecordDetail(r.record_id)
          if (d.error || !d.data) {
            skipped.push({ id: r.record_id, name: r.name, reason: d.error ?? 'Not found' })
            continue
          }
          const pdf = detailToPdfData(d.data, workspace.entity)
          downloadBytes(buildPayslipPdf(pdf), payslipFilename(pdf))
          n++
        }
        const summary = toCsv(
          ['Employee', 'Branch', 'Fixed pay', 'Extra earnings', 'Deductions', 'Net', 'Status', 'Paid', 'Outstanding'],
          prepared.map((r) => [r.name, r.branch, r.fixed_pay, r.extra_earnings, r.deductions, r.net, r.record_status, r.paid, r.outstanding ?? '']),
        )
        downloadBytes(new TextEncoder().encode(summary), `payroll-summary-${workspace.period.period_start}.csv`, 'text/csv')
        setBusy(false)
        return onDone('Payslips downloaded', { ok: true, processed: n, skipped })
      }
    }
    setBusy(false)
    if (res.error) return setErr(res.error)
    onDone(title, res.data)
  }

  const needsPreview = action === 'adjust' || action === 'pay'
  const canRun = included.length > 0 && (!needsPreview || (serverPreview?.processed ?? 0) > 0)
  const localTotal =
    action === 'pay' || action === 'export' ? sumBy(prepared, (r) => r.outstanding) : sumBy(prepared, (r) => r.net)

  return (
    <Modal
      open
      title={title}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          {needsPreview && (
            <button className="btn-secondary" onClick={action === 'adjust' ? previewAdjust : previewPay} disabled={busy || included.length === 0}>
              Preview
            </button>
          )}
          <button className="btn-primary" onClick={run} disabled={busy || !canRun}>
            {busy ? 'Working…' : confirmLabel(action, included.length)}
          </button>
        </>
      }
    >
      <p className="text-muted">{periodLabel(workspace.period)}</p>
      {err && <Alert tone="error">{err}</Alert>}

      <div className="rounded-lg bg-surface-alt p-3">
        <p>
          <strong>{included.length}</strong> of {rows.length} selected employee{rows.length === 1 ? '' : 's'} will be included
          {action !== 'adjust' && prepared.length > 0 && (
            <>
              {' '}
              · {action === 'pay' || action === 'export' ? 'outstanding' : 'net'} <strong>{fmtMoney(localTotal, currency)}</strong>
            </>
          )}
          .
        </p>
        {action === 'approve' && serverPreview && (
          <p className="mt-1 text-xs text-muted">
            Server check: {serverPreview.processed} can be approved now ({fmtMoney(serverPreview.total ?? 0, currency)}).
          </p>
        )}
      </div>

      {(excluded.length > 0 || (serverPreview?.skipped.length ?? 0) > 0) && (
        <details open className="rounded-lg border border-border p-3">
          <summary className="cursor-pointer text-sm font-semibold">Not included</summary>
          <ul className="mt-2 space-y-1 text-xs">
            {excluded.map((x) => (
              <li key={x.row.employee_id}>
                <strong>{x.row.name}</strong>: {x.reason}
              </li>
            ))}
            {serverPreview?.skipped
              .filter((s) => !excluded.some((x) => x.row.name === s.name))
              .map((s) => (
                <li key={s.id}>
                  <strong>{s.name}</strong>: {s.reason}
                </li>
              ))}
          </ul>
        </details>
      )}

      {action === 'adjust' && (
        <div className="grid gap-2 sm:grid-cols-2">
          <label>
            <span className="label">Type</span>
            <select
              className="input"
              value={kind}
              onChange={(e) => {
                const k = e.target.value as 'earning' | 'deduction'
                setKind(k)
                setCode(k === 'earning' ? 'bonus' : 'cash_shortage')
                setServerPreview(null)
              }}
            >
              <option value="earning">Earning (adds to pay)</option>
              <option value="deduction">Deduction (reduces pay)</option>
            </select>
          </label>
          <label>
            <span className="label">What for</span>
            <select className="input" value={code} onChange={(e) => (setCode(e.target.value), setServerPreview(null))}>
              {(kind === 'earning' ? EARNING_CODES : DEDUCTION_CODES).map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span className="label">Amount ({currency})</span>
            <input className="input" inputMode="decimal" value={amount} onChange={(e) => (setAmount(e.target.value), setServerPreview(null))} />
          </label>
          {included.length > 1 && (
            <fieldset>
              <legend className="label">How to apply it</legend>
              <label className="flex items-center gap-2 text-sm">
                <input type="radio" checked={mode === 'per_employee'} onChange={() => (setMode('per_employee'), setServerPreview(null))} />
                This amount for each employee
              </label>
              <label className="flex items-center gap-2 text-sm">
                <input type="radio" checked={mode === 'distributed'} onChange={() => (setMode('distributed'), setServerPreview(null))} />
                Split this total across them
              </label>
            </fieldset>
          )}
          <label className="sm:col-span-2">
            <span className="label">Reason (shown on the payslip)</span>
            <input className="input" value={reason} onChange={(e) => (setReason(e.target.value), setServerPreview(null))} />
          </label>
          {serverPreview && (
            <div className="sm:col-span-2 rounded-lg border border-border p-2 text-xs">
              <p className="font-semibold">
                Total impact: {fmtMoney(serverPreview.impact ?? 0, currency)} across {serverPreview.processed} employee(s)
              </p>
              <ul className="mt-1 max-h-32 overflow-y-auto">
                {serverPreview.items?.map((i) => (
                  <li key={i.id}>
                    {i.name}: {fmtMoney(i.amount, currency)}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}

      {action === 'pay' && (
        <div className="grid gap-2 sm:grid-cols-2">
          <label>
            <span className="label">Result</span>
            <select className="input" value={payStatus} onChange={(e) => (setPayStatus(e.target.value as 'recorded' | 'failed'), setServerPreview(null))}>
              <option value="recorded">Paid (confirmed by bank)</option>
              <option value="failed">Failed / returned</option>
            </select>
          </label>
          <label>
            <span className="label">Date paid</span>
            <input type="date" className="input" max={todayStr} value={paidOn} onChange={(e) => (setPaidOn(e.target.value), setServerPreview(null))} />
            {payDayAhead && (
              <span className="mt-1 block text-xs text-muted">
                Pay day is {fmtDate(payDay)}. Record the payment on the day the bank sends it — payments can’t be dated in the future.
              </span>
            )}
          </label>
          <label>
            <span className="label">Method</span>
            <select className="input" value={method} onChange={(e) => setMethod(e.target.value as PaymentMethod)}>
              {PAYMENT_METHODS.map((m) => (
                <option key={m.value} value={m.value}>
                  {m.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span className="label">Reference</span>
            <input className="input" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Bank / batch reference" />
          </label>
          {prepared.length === 1 && (
            <label>
              <span className="label">Amount (blank = full outstanding {fmtMoney(prepared[0].outstanding, currency)})</span>
              <input className="input" inputMode="decimal" value={customAmount} onChange={(e) => (setCustomAmount(e.target.value), setServerPreview(null))} />
            </label>
          )}
          {payStatus === 'failed' && (
            <label className="sm:col-span-2">
              <span className="label">Why it failed</span>
              <input className="input" value={failureReason} onChange={(e) => (setFailureReason(e.target.value), setServerPreview(null))} />
            </label>
          )}
          <p className="sm:col-span-2 text-xs text-muted">
            {payStatus === 'failed'
              ? 'A failed attempt is kept for the record but never counts as paid.'
              : 'Only record a payment once the money has actually left. Each employee is paid their outstanding balance.'}
          </p>
          {serverPreview && (
            <p className="sm:col-span-2 text-sm font-semibold">
              {serverPreview.processed} payment(s), {fmtMoney(serverPreview.total ?? 0, currency)}
            </p>
          )}
        </div>
      )}

      {action === 'return' && (
        <label className="block">
          <span className="label">Reason</span>
          <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="What needs changing" />
          <span className="mt-1 block text-xs text-muted">Any exported payment list containing these employees becomes void.</span>
        </label>
      )}
      {action === 'export' && (
        <p className="text-xs text-muted">
          Downloads a payment list (CSV) of outstanding amounts for your bank. This is not a WPS SIF file and does not mark anyone paid.
        </p>
      )}
      {action === 'publish' && <p className="text-xs text-muted">Employees are notified and can view and download their payslip.</p>}
    </Modal>
  )
}

function confirmLabel(action: BulkAction, n: number) {
  const who = `${n} employee${n === 1 ? '' : 's'}`
  switch (action) {
    case 'approve':
      return `Approve ${who}`
    case 'pay':
      return `Record for ${who}`
    case 'publish':
      return `Publish ${who}`
    case 'export':
      return `Export ${who}`
    case 'download':
      return `Download ${who}`
    case 'return':
      return `Return ${who} to draft`
    case 'adjust':
      return `Add to ${who}`
    case 'review':
      return `Send ${who}`
    default:
      return `Prepare ${who}`
  }
}

export function ResultSummary({ title, res, currency, onClose }: { title: string; res: BulkResult; currency: string; onClose: () => void }) {
  const tone = res.processed === 0 && res.skipped.length ? 'warning' : 'success'
  return (
    <Alert tone={tone} onDismiss={onClose}>
      <p className="font-semibold">
        {title}: {res.processed} done{res.created ? ` (${res.created} new)` : ''}
        {res.total != null && res.processed > 0 ? ` · ${fmtMoney(res.total, currency)}` : ''}
        {res.skipped.length ? ` · ${res.skipped.length} not changed` : ''}
      </p>
      {res.skipped.length > 0 && (
        <ul className="mt-1 list-disc pl-5 text-xs">
          {res.skipped.slice(0, 12).map((s, i) => (
            <li key={`${s.id}-${i}`}>
              {s.name ? <strong>{s.name}</strong> : 'Record'}: {s.reason}
            </li>
          ))}
          {res.skipped.length > 12 && <li>…and {res.skipped.length - 12} more</li>}
        </ul>
      )}
      {res.reason && <p className="text-xs">{res.reason}</p>}
    </Alert>
  )
}
