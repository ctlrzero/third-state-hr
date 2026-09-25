import { useEffect, useState } from 'react'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { Alert, Drawer, PageHeader, Skeleton } from '../components/ui'
import { getMyPayslip, getMyPayslips, type MyPayslipDetail, type MyPayslipListRow } from '../lib/api/payslips'
import { buildPayslipPdf, lineLabel, money, payslipFilename } from '../lib/payslipPdf'
import { downloadBytes } from '../lib/pdf'
import { fmtDate } from '../lib/format'

// Staff "Payslips": own published payslips only (get_my_payslips /
// get_my_payslip resolve the employee from auth.uid()). PDFs are generated
// in the browser from the RPC data — there is no stored payslip file.
export default function MyPayslips() {
  const [rows, setRows] = useState<MyPayslipListRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [openId, setOpenId] = useState<string | null>(null)

  useEffect(() => {
    getMyPayslips().then((res) => {
      if (res.error) setError(res.error)
      setRows(res.data ?? [])
    })
  }, [])

  return (
    <div className="mx-auto max-w-2xl space-y-5">
      <PageHeader title="My payslips" description="Published payslips. Download any of them as a PDF." />
      {error && <Alert tone="error">{error}</Alert>}
      {rows === null ? (
        <Skeleton rows={3} className="h-20" />
      ) : rows.length === 0 ? (
        <EmptyState title="No payslips yet" description="Your payslip appears here once payroll for the period is approved." />
      ) : (
        <ul className="space-y-3">
          {rows.map((p) => (
            <li key={p.payslip_id}>
              <button
                type="button"
                onClick={() => setOpenId(p.payslip_id)}
                className="card flex w-full flex-wrap items-center justify-between gap-3 text-left transition hover:border-brand-blue/40"
              >
                <span>
                  <span className="block font-semibold text-ink">
                    {fmtDate(p.period_start)} – {fmtDate(p.period_end)}
                  </span>
                  <span className="mt-1 flex flex-wrap gap-1">
                    <StatusBadge status={p.run_status} />
                    {p.is_revision && <StatusBadge status={`Revision v${p.version}`} tone="info" />}
                    {p.superseded && <StatusBadge status="Superseded" tone="neutral" />}
                  </span>
                </span>
                <span className="text-right">
                  <span className="block text-xs text-muted">Net pay</span>
                  <span className="text-lg font-semibold text-ink">{money(p.net_pay, p.currency)}</span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {openId && <PayslipDrawer payslipId={openId} onClose={() => setOpenId(null)} />}
    </div>
  )
}

function PayslipDrawer({ payslipId, onClose }: { payslipId: string; onClose: () => void }) {
  const [detail, setDetail] = useState<MyPayslipDetail | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    getMyPayslip(payslipId).then((res) => {
      if (res.error) setError(res.error)
      else setDetail(res.data)
    })
  }, [payslipId])

  function download() {
    if (!detail) return
    downloadBytes(buildPayslipPdf(detail), payslipFilename(detail))
  }

  function openForPrint() {
    if (!detail) return
    const blob = new Blob([buildPayslipPdf(detail) as BlobPart], { type: 'application/pdf' })
    const url = URL.createObjectURL(blob)
    window.open(url, '_blank', 'noopener')
    setTimeout(() => URL.revokeObjectURL(url), 60_000)
  }

  const cur = detail?.currency ?? 'AED'

  return (
    <Drawer
      open
      wide
      title="Payslip"
      description={detail ? `${fmtDate(detail.period_start)} – ${fmtDate(detail.period_end)}` : undefined}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={openForPrint} disabled={!detail}>
            Open to print
          </button>
          <button className="btn-primary" onClick={download} disabled={!detail}>
            Download PDF
          </button>
        </>
      }
    >
      {error ? (
        <Alert tone="error">{error}</Alert>
      ) : !detail ? (
        <Skeleton rows={4} />
      ) : (
        <div className="space-y-4 text-sm">
          {detail.superseded && <Alert tone="warning">This payslip was replaced by a later revision.</Alert>}
          <dl className="grid grid-cols-2 gap-3">
            <div>
              <dt className="text-muted">Employer</dt>
              <dd className="font-medium">{detail.employer?.name}</dd>
            </div>
            <div>
              <dt className="text-muted">Employee</dt>
              <dd className="font-medium">{detail.employee?.full_name}</dd>
            </div>
            <div>
              <dt className="text-muted">Position</dt>
              <dd>{detail.employee?.position_title ?? '—'}</dd>
            </div>
            <div>
              <dt className="text-muted">Branch</dt>
              <dd>{detail.employee?.location_name ?? '—'}</dd>
            </div>
          </dl>
          <LineTable title="Earnings" lines={detail.earnings ?? []} currency={cur} />
          {(detail.allowances ?? []).length > 0 && <LineTable title="Allowances" lines={detail.allowances} currency={cur} />}
          <LineTable title="Deductions" lines={detail.deductions ?? []} currency={cur} negative />
          <dl className="space-y-1 rounded-lg bg-surface-alt p-3">
            <div className="flex justify-between">
              <dt className="text-muted">Gross pay</dt>
              <dd>{money(detail.gross_pay, cur)}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-muted">Total deductions</dt>
              <dd>{money(detail.total_deductions, cur)}</dd>
            </div>
            <div className="flex justify-between border-t border-border pt-1 text-base font-semibold">
              <dt>Net pay</dt>
              <dd>{money(detail.net_pay, cur)}</dd>
            </div>
          </dl>
        </div>
      )}
    </Drawer>
  )
}

function LineTable({ title, lines, currency, negative }: { title: string; lines: MyPayslipDetail['earnings']; currency: string; negative?: boolean }) {
  return (
    <section>
      <h3 className="mb-1 font-semibold text-ink">{title}</h3>
      {lines.length === 0 ? (
        <p className="text-muted">None</p>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {lines.map((l, i) => (
            <li key={i} className="flex justify-between gap-3 px-3 py-2">
              <span>
                {lineLabel(l)}
                {l.notes && <span className="block text-xs text-muted">{l.notes}</span>}
              </span>
              <span className={negative ? 'text-brand-risk-text' : ''}>
                {negative ? '− ' : ''}
                {money(l.amount, currency)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
