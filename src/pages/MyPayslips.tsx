import { useEffect, useState } from 'react'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { Alert, Drawer, PageHeader, Skeleton } from '../components/ui'
import { getMyPayslip, getMyPayslips, type MyPayslipDetail, type MyPayslipListRow } from '../lib/api/payslips'
import { buildPayslipPdf, lineLabel, money, payslipFilename } from '../lib/payslipPdf'
import { downloadBytes } from '../lib/pdf'
import { fmtDate } from '../lib/format'
import { getMyPayslipV2, getMyPayslipsV2 } from '../lib/api/payroll'
import { myV2ToPdfData } from '../lib/payroll'

// Staff "Payslips": own published payslips only (get_my_payslips /
// get_my_payslip resolve the employee from auth.uid()). PDFs are generated
// in the browser from the RPC data — there is no stored payslip file.
interface ListItem {
  key: string
  source: 'v1' | 'v2'
  id: string
  period_start: string
  period_end: string
  label: string | null
  badges: { text: string; tone?: 'info' | 'neutral' }[]
  net: number
  currency: string
}

// Staff "Payslips": own published payslips only. Payroll v2 records
// (payroll_my_payslips) and earlier runs (get_my_payslips) are listed
// together; both resolve the employee from auth.uid(). PDFs are generated
// in the browser from the RPC data — there is no stored payslip file.
export default function MyPayslips() {
  const [rows, setRows] = useState<ListItem[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState<ListItem | null>(null)

  useEffect(() => {
    Promise.all([getMyPayslipsV2(), getMyPayslips()]).then(([v2, v1]) => {
      if (v2.error && v1.error) setError(v2.error)
      // A payslip replaced by a correction is hidden here: the employee only sees the current one.
      // The replaced record is kept (audit / WPS) and stays visible to payroll in the workspace.
      const a: ListItem[] = (v2.data ?? []).filter((p) => !p.superseded).map((p) => ({
        key: `v2-${p.record_id}`,
        source: 'v2',
        id: p.record_id,
        period_start: p.period_start,
        period_end: p.period_end,
        // Staff see the salary month ("September 2026"), never the admin's run title.
        label: p.title ?? (p.kind === 'off_cycle' ? p.label : null),
        badges: [...(p.is_correction ? [{ text: 'Corrected', tone: 'info' as const }] : [])],
        net: p.net,
        currency: p.currency,
      }))
      const b: ListItem[] = (v1.data ?? []).filter((p: MyPayslipListRow) => !p.superseded).map((p: MyPayslipListRow) => ({
        key: `v1-${p.payslip_id}`,
        source: 'v1',
        id: p.payslip_id,
        period_start: p.period_start,
        period_end: p.period_end,
        label: null,
        badges: [...(p.is_revision ? [{ text: 'Updated', tone: 'info' as const }] : [])],
        net: p.net_pay,
        currency: p.currency,
      }))
      setRows([...a, ...b].sort((x, y) => y.period_start.localeCompare(x.period_start)))
    })
  }, [])

  return (
    <div className="mx-auto max-w-2xl space-y-5">
      <PageHeader title="My payslips" description="Published payslips. Download any of them as a PDF." />
      {error && <Alert tone="error">{error}</Alert>}
      {rows === null ? (
        <Skeleton rows={3} className="h-20" />
      ) : rows.length === 0 ? (
        <EmptyState title="No payslips yet" description="Your payslip appears here once payroll for the period is approved and published." />
      ) : (
        <ul className="space-y-3">
          {rows.map((p) => (
            <li key={p.key}>
              <button
                type="button"
                onClick={() => setOpen(p)}
                className="card flex w-full flex-wrap items-center justify-between gap-3 text-left transition hover:border-brand-blue/40"
              >
                <span>
                  <span className="block font-semibold text-ink">
                    {p.label ?? `${fmtDate(p.period_start)} – ${fmtDate(p.period_end)}`}
                  </span>
                  {p.badges.length > 0 && (
                    <span className="mt-1 flex flex-wrap gap-1">
                      {p.badges.map((b) => (
                        <StatusBadge key={b.text} status={b.text} tone={b.tone} />
                      ))}
                    </span>
                  )}
                </span>
                <span className="text-right">
                  <span className="block text-xs text-muted">Net pay</span>
                  <span className="text-lg font-semibold text-ink">{money(p.net, p.currency)}</span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {open && (
        <PayslipDrawer
          load={async () => {
            if (open.source === 'v1') return getMyPayslip(open.id)
            const res = await getMyPayslipV2(open.id)
            return { data: res.data ? myV2ToPdfData(res.data) : null, error: res.error }
          }}
          onClose={() => setOpen(null)}
        />
      )}
    </div>
  )
}

function PayslipDrawer({
  load,
  onClose,
}: {
  load: () => Promise<{ data: MyPayslipDetail | null; error: string | null }>
  onClose: () => void
}) {
  const [detail, setDetail] = useState<MyPayslipDetail | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    load().then((res) => {
      if (res.error) setError(res.error)
      else setDetail(res.data)
    })
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

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
      description={
        detail
          ? detail.title
            ? `${detail.title}${detail.pay_date ? ` · pay date ${fmtDate(detail.pay_date)}` : ''}`
            : `${fmtDate(detail.period_start)} – ${fmtDate(detail.period_end)}`
          : undefined
      }
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
          {detail.superseded && <Alert tone="warning">This payslip was replaced by a later correction.</Alert>}
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
