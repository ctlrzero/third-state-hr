import { useCallback, useEffect, useState } from 'react'
import { Alert, PageHeader, Skeleton } from '../../components/ui'
import { EmptyState } from '../../components/EmptyState'
import { EntityEyebrow } from '../../components/EntityEyebrow'
import { confirmHours, getHoursSheet, importAttendance, listPeriods, reasonError, setHours, type HoursSheetRow, type PeriodListItem } from '../../lib/api/payroll'
import { periodLabel } from '../../lib/payroll'

// Branch manager view: hours, overtime and confirmation for their own
// branch. No salaries or pay amounts are shown or returned by the server.
export default function HoursSheet({ entityId }: { entityId: string }) {
  const [periods, setPeriods] = useState<PeriodListItem[] | null>(null)
  const [periodId, setPeriodId] = useState<string | null>(null)
  const [rows, setRows] = useState<HoursSheetRow[] | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  useEffect(() => {
    listPeriods(entityId).then((res) => {
      if (res.error) setErr(res.error)
      setPeriods(res.data ?? [])
      if (res.data?.[0]) setPeriodId(res.data[0].id)
    })
  }, [entityId])

  const load = useCallback(async () => {
    if (!periodId) return
    const res = await getHoursSheet(periodId)
    if (res.error) setErr(res.error)
    setRows(res.data ?? [])
  }, [periodId])
  useEffect(() => {
    setRows(null)
    load()
  }, [load])

  return (
    <div className="space-y-5">
      <EntityEyebrow />
      <PageHeader title="Payroll inputs" description="Enter and confirm hours and overtime for your branch. Pay amounts are handled by the payroll admin." />
      {err && (
        <Alert tone="error" onDismiss={() => setErr(null)}>
          {err}
        </Alert>
      )}
      {msg && (
        <Alert tone="success" onDismiss={() => setMsg(null)}>
          {msg}
        </Alert>
      )}
      {periods?.length === 0 && <EmptyState title="No payroll month open" description="The payroll admin opens the month first." />}
      {periods && periods.length > 0 && (
        <div className="flex flex-wrap items-end gap-2">
          <label className="min-w-48">
            <span className="label">Month</span>
            <select className="input" value={periodId ?? ''} onChange={(e) => setPeriodId(e.target.value)}>
              {periods.map((p) => (
                <option key={p.id} value={p.id}>
                  {periodLabel(p)}
                </option>
              ))}
            </select>
          </label>
          <button
            className="btn-secondary"
            onClick={async () => {
              if (!periodId) return
              const res = await importAttendance(periodId, null)
              if (res.error) return setErr(res.error)
              setMsg(`Loaded attendance for ${res.data?.processed ?? 0} employees.`)
              load()
            }}
          >
            Load from attendance
          </button>
          {rows && rows.some((r) => r.hours?.status === 'pending') && (
            <button
              className="btn-primary"
              onClick={async () => {
                if (!periodId) return
                const res = await confirmHours(
                  periodId,
                  rows.filter((r) => r.hours?.status === 'pending').map((r) => r.employee_id),
                )
                if (res.error) return setErr(res.error)
                setMsg(`Confirmed ${res.data?.processed ?? 0}.`)
                load()
              }}
            >
              Confirm all pending
            </button>
          )}
        </div>
      )}
      {periodId && rows === null && <Skeleton rows={4} className="h-12" />}
      {rows && (
        <ul className="space-y-2">
          {rows.map((r) => (
            <HoursRowEditor key={r.employee_id} row={r} periodId={periodId!} onSaved={load} setErr={setErr} />
          ))}
        </ul>
      )}
    </div>
  )
}

function HoursRowEditor({ row, periodId, onSaved, setErr }: { row: HoursSheetRow; periodId: string; onSaved: () => void; setErr: (e: string) => void }) {
  const h = row.hours
  const locked = row.record_status === 'approved' || row.record_status === 'in_review'
  const [v, setV] = useState({
    regular: String(h?.regular_hours ?? 0),
    overtime: String(h?.overtime_hours ?? 0),
    night: String(h?.night_overtime_hours ?? 0),
    holiday: String(h?.holiday_hours ?? 0),
  })
  const f = (k: keyof typeof v, label: string) => (
    <label>
      <span className="label">{label}</span>
      <input className="input" inputMode="decimal" value={v[k]} disabled={locked} onChange={(e) => setV({ ...v, [k]: e.target.value })} />
    </label>
  )
  const save = async (confirm: boolean) => {
    const res = await setHours(
      periodId,
      row.employee_id,
      { regular: Number(v.regular) || 0, overtime: Number(v.overtime) || 0, night: Number(v.night) || 0, holiday: Number(v.holiday) || 0 },
      confirm,
      null,
    )
    const e = reasonError(res)
    if (e) return setErr(e)
    onSaved()
  }
  return (
    <li className="card">
      <p className="font-medium text-ink">
        {row.name} <span className="text-xs text-muted">· {row.branch}</span>
      </p>
      <p className="text-xs text-muted">
        {h ? `${h.source === 'attendance' ? 'From attendance' : 'Manual'} · ${h.status}` : 'No hours yet'}
        {locked ? ' · payroll approved: ask the payroll admin to change it' : ''}
      </p>
      <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4">
        {f('regular', 'Regular')}
        {f('overtime', 'Overtime')}
        {f('night', 'Night OT')}
        {f('holiday', 'Holiday')}
      </div>
      {!locked && (
        <div className="mt-2 flex gap-2">
          <button className="btn-secondary" onClick={() => save(false)}>
            Save
          </button>
          <button className="btn-primary" onClick={() => save(true)}>
            Save and confirm
          </button>
        </div>
      )}
    </li>
  )
}
