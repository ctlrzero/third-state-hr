import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { getPayrollPayslip } from '../../lib/api/payslips'
import { buildPayslipPdf, payslipFilename } from '../../lib/payslipPdf'
import { downloadBytes } from '../../lib/pdf'
import { fmtDate } from '../../lib/format'
import { fmtMoney } from '../../lib/payroll'

interface LegacyRun {
  id: string
  period_start: string
  period_end: string
  status: string
  payslips: { id: string; net_pay: number; employees: { full_name: string } | null }[]
}

// Payroll runs made before payroll v2. Read-only history: payslips stay
// downloadable, nothing can be edited.
export default function LegacyRuns({ entityId }: { entityId: string }) {
  const [runs, setRuns] = useState<LegacyRun[]>([])
  useEffect(() => {
    supabase
      .from('payroll_runs')
      .select('id, period_start, period_end, status, payslips(id, net_pay, employees(full_name))')
      .eq('entity_id', entityId)
      .order('period_start', { ascending: false })
      .then(({ data }) => setRuns((data ?? []) as unknown as LegacyRun[]))
  }, [entityId])
  if (runs.length === 0) return null
  return (
    <details className="card">
      <summary className="cursor-pointer text-sm font-semibold text-ink">Earlier payroll runs (before this version, read-only)</summary>
      <ul className="mt-3 space-y-3 text-sm">
        {runs.map((r) => (
          <li key={r.id}>
            <p className="font-medium">
              {fmtDate(r.period_start)} – {fmtDate(r.period_end)} · {r.status}
            </p>
            <ul className="ml-4 mt-1 space-y-1">
              {r.payslips.map((p) => (
                <li key={p.id} className="flex items-center justify-between gap-2">
                  <span>
                    {p.employees?.full_name} · {fmtMoney(p.net_pay)}
                  </span>
                  {['approved', 'paid'].includes(r.status) && (
                    <button
                      className="btn-ghost text-xs"
                      onClick={async () => {
                        const res = await getPayrollPayslip(p.id)
                        if (res.data) downloadBytes(buildPayslipPdf(res.data), payslipFilename(res.data))
                      }}
                    >
                      PDF
                    </button>
                  )}
                </li>
              ))}
              {r.payslips.length === 0 && <li className="text-muted">No payslips.</li>}
            </ul>
          </li>
        ))}
      </ul>
    </details>
  )
}
