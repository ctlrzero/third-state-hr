import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { KpiCard } from '../components/KpiCard'
import {
  Alert,
  Drawer,
  Field,
  Modal,
  PageHeader,
  ResponsiveTable,
  Skeleton,
  TabPanel,
  Tabs,
  type Column,
} from '../components/ui'
import {
  applyAttendanceAdjustment,
  correctAttendanceRecord,
  getAdjustments,
  getAttendanceExceptions,
  getAttendanceRecords,
  getLocationAttendanceOverview,
  getPayableRecords,
  getShiftsByIds,
  proposeAttendanceAdjustment,
  rejectAttendanceAdjustment,
  seedPayableShiftRecords,
  type AttendanceAdjustment,
  type OverviewRow,
  type PayableRecord,
} from '../lib/api/attendance'
import type { AttendanceException } from '../types/db'
import {
  addDays,
  fmtDateTime,
  fmtDayShort,
  fmtMinutes,
  fmtTime,
  fromDubaiLocalInput,
  todayDubai,
  toDubaiLocalInput,
} from '../lib/format'

const EXCEPTION_LABEL: Record<string, string> = {
  missing_clock_out: 'Missing clock-out',
  unmatched_shift: 'Shift never clocked',
  no_shift_match: 'Clock-in without a shift',
  late_clock_in: 'Late clock-in',
}

type TabKey = 'overview' | 'exceptions' | 'adjustments'

interface ShiftLite {
  id: string
  shift_date: string
  start_time: string
  end_time: string
}

interface RecordLite {
  id: string
  employee_id: string
  shift_id: string | null
  clock_in_at: string
  clock_out_at: string | null
  original_clock_in_at: string | null
  original_clock_out_at: string | null
  corrected: boolean
  correction_reason: string | null
}

// Manager/Admin attendance workspace. Everything is scoped by RLS/RPC to the
// caller's entity (entity_admin) or location (location_manager); the
// location picker is just whatever `locations` RLS returns.
export default function Attendance() {
  const { activeEntityId, profile } = useAuth()
  const [locations, setLocations] = useState<{ id: string; name: string }[]>([])
  const [locationId, setLocationId] = useState('')
  const [periodEnd, setPeriodEnd] = useState(todayDubai())
  const [periodStart, setPeriodStart] = useState(addDays(todayDubai(), -6))
  const [rangeError, setRangeError] = useState<string | null>(null)
  const [tab, setTab] = useState<TabKey>('overview')

  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const [overview, setOverview] = useState<OverviewRow[]>([])
  const [exceptions, setExceptions] = useState<AttendanceException[]>([])
  const [payables, setPayables] = useState<PayableRecord[]>([])
  const [adjustments, setAdjustments] = useState<AttendanceAdjustment[]>([])
  const [names, setNames] = useState<Record<string, string>>({})
  const [shifts, setShifts] = useState<Record<string, ShiftLite>>({})
  const [records, setRecords] = useState<Record<string, RecordLite>>({})

  const [correcting, setCorrecting] = useState<AttendanceException | null>(null)
  const [adjusting, setAdjusting] = useState<OverviewRow | null>(null)
  const [rejecting, setRejecting] = useState<AttendanceAdjustment | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  useEffect(() => {
    // Switching entity must never leave the previous entity's rows on screen.
    setOverview([])
    setExceptions([])
    setPayables([])
    setAdjustments([])
    let q = supabase.from('locations').select('id, name').order('name')
    if (activeEntityId) q = q.eq('entity_id', activeEntityId)
    // A location manager can only act on their own branch (RPCs enforce it).
    if (profile?.role === 'location_manager' && profile.location_id) q = q.eq('id', profile.location_id)
    q.then(({ data }) => {
      const locs = (data ?? []) as { id: string; name: string }[]
      setLocations(locs)
      setLocationId((cur) => (cur && locs.some((l) => l.id === cur) ? cur : (locs[0]?.id ?? '')))
    })
  }, [activeEntityId, profile?.role, profile?.location_id])

  const load = useCallback(async () => {
    if (!locationId) return
    if (periodEnd < periodStart) {
      setRangeError('End date must be on or after the start date.')
      return
    }
    setRangeError(null)
    setLoading(true)
    setError(null)
    const [ov, ex] = await Promise.all([
      getLocationAttendanceOverview(locationId, periodStart, periodEnd),
      getAttendanceExceptions(locationId, periodStart, periodEnd),
    ])
    if (ov.error || ex.error) setError(ov.error ?? ex.error)
    const ovRows = ov.data ?? []
    const exRows = ex.data ?? []
    setOverview(ovRows)
    setExceptions(exRows)

    const shiftIds = Array.from(new Set([...ovRows.map((r) => r.shift_id), ...exRows.map((e) => e.shift_id)].filter(Boolean) as string[]))
    const recordIds = exRows.map((e) => e.record_id).filter(Boolean) as string[]
    const empIds = Array.from(new Set([...ovRows.map((r) => r.employee_id), ...exRows.map((e) => e.employee_id)]))

    const [sh, rec, emp, pay] = await Promise.all([
      getShiftsByIds(shiftIds),
      getAttendanceRecords(recordIds),
      empIds.length
        ? supabase.from('employees').select('id, full_name, preferred_name').in('id', empIds)
        : Promise.resolve({ data: [] as { id: string; full_name: string; preferred_name: string | null }[] }),
      getPayableRecords(ovRows.map((r) => r.shift_id)),
    ])
    setShifts(Object.fromEntries(((sh.data ?? []) as ShiftLite[]).map((s) => [s.id, s])))
    setRecords(Object.fromEntries(((rec.data ?? []) as RecordLite[]).map((r) => [r.id, r])))
    const nm: Record<string, string> = {}
    for (const e of (emp.data ?? []) as { id: string; full_name: string; preferred_name: string | null }[]) {
      nm[e.id] = e.preferred_name || e.full_name
    }
    for (const e of exRows) nm[e.employee_id] = nm[e.employee_id] ?? e.employee_name
    setNames(nm)
    const payRows = pay.data ?? []
    setPayables(payRows)
    const adj = await getAdjustments(payRows.map((p) => p.id))
    setAdjustments(adj.data ?? [])
    setLoading(false)
  }, [locationId, periodStart, periodEnd])

  useEffect(() => {
    load()
  }, [load])

  const payableByShift = useMemo(() => Object.fromEntries(payables.map((p) => [p.shift_id, p])), [payables])
  const pendingAdjustments = adjustments.filter((a) => a.status === 'pending')

  async function handleSeed() {
    setBusyId('seed')
    const res = await seedPayableShiftRecords(locationId, periodStart, periodEnd)
    setBusyId(null)
    if (res.error) setError(res.error)
    else {
      setNotice('Payable time prepared from published shifts.')
      load()
    }
  }

  async function handleApply(a: AttendanceAdjustment) {
    setBusyId(a.id)
    const res = await applyAttendanceAdjustment(a.id)
    setBusyId(null)
    if (res.error) setError(res.error)
    else {
      setNotice(`Adjustment applied — payable time set to ${fmtMinutes(a.proposed_minutes)}.`)
      load()
    }
  }

  const overviewColumns: Column<OverviewRow>[] = [
    { key: 'date', header: 'Date', render: (r) => fmtDayShort(r.shift_date) },
    { key: 'emp', header: 'Employee', render: (r) => names[r.employee_id] ?? 'Employee' },
    {
      key: 'planned',
      header: 'Planned',
      render: (r) => {
        const s = shifts[r.shift_id]
        return s ? `${fmtTime(s.start_time)}–${fmtTime(s.end_time)} (${fmtMinutes(r.planned_minutes)})` : fmtMinutes(r.planned_minutes)
      },
    },
    { key: 'default', header: 'Default payable', render: (r) => fmtMinutes(r.default_payable_minutes) },
    { key: 'final', header: 'Final payable', render: (r) => fmtMinutes(r.final_payable_minutes ?? r.default_payable_minutes) },
    {
      key: 'status',
      header: 'Status',
      render: (r) => (
        <span className="flex flex-wrap gap-1">
          <StatusBadge status={r.payable_status} />
          {r.pending_adjustment && <StatusBadge status="Adjustment pending" tone="warning" />}
        </span>
      ),
    },
  ]

  const exceptionColumns: Column<AttendanceException>[] = [
    { key: 'date', header: 'Date', render: (e) => fmtDayShort(e.shift_date) },
    { key: 'emp', header: 'Employee', render: (e) => names[e.employee_id] ?? e.employee_name },
    {
      key: 'type',
      header: 'Exception',
      render: (e) => <StatusBadge status={EXCEPTION_LABEL[e.exception_type] ?? e.exception_type} tone="warning" />,
    },
    {
      key: 'planned',
      header: 'Planned',
      render: (e) => {
        const s = e.shift_id ? shifts[e.shift_id] : undefined
        return s ? `${fmtTime(s.start_time)}–${fmtTime(s.end_time)}` : '—'
      },
    },
    { key: 'actual', header: 'Actual', render: (e) => `${fmtTime(e.clock_in_at)}–${fmtTime(e.clock_out_at)}` },
  ]

  const adjustmentColumns: Column<AttendanceAdjustment>[] = [
    {
      key: 'emp',
      header: 'Employee / shift',
      render: (a) => {
        const p = payables.find((x) => x.id === a.payable_shift_record_id)
        const s = p ? shifts[p.shift_id] : undefined
        return `${p ? (names[p.employee_id] ?? 'Employee') : 'Employee'}${s ? ` · ${fmtDayShort(s.shift_date)}` : ''}`
      },
    },
    {
      key: 'change',
      header: 'Payable time',
      render: (a) => {
        const p = payables.find((x) => x.id === a.payable_shift_record_id)
        return `${fmtMinutes(p?.final_payable_minutes ?? p?.default_payable_minutes)} → ${fmtMinutes(a.proposed_minutes)}`
      },
    },
    { key: 'reason', header: 'Reason', render: (a) => a.reason },
    { key: 'when', header: 'Proposed', render: (a) => fmtDateTime(a.created_at) },
    {
      key: 'status',
      header: 'Status',
      render: (a) => (
        <span>
          <StatusBadge status={a.status} tone={a.status === 'applied' ? 'success' : a.status === 'rejected' ? 'risk' : 'warning'} />
          {a.decision_reason && <span className="ml-2 text-xs text-muted">{a.decision_reason}</span>}
        </span>
      ),
    },
  ]

  return (
    <div className="space-y-5">
      <PageHeader
        title="Attendance"
        description="Planned shifts vs actual clock-ins, exceptions and payable time."
        actions={
          profile?.role !== 'owner' ? (
            <Link to="/clock" className="btn-secondary">
              My clock
            </Link>
          ) : undefined
        }
      />

      <form
        className="card grid gap-3 sm:grid-cols-[1fr_auto_auto_auto] sm:items-end"
        onSubmit={(e) => {
          e.preventDefault()
          load()
        }}
      >
        <Field label="Branch">
          {(p) => (
            <select {...p} className="input" value={locationId} onChange={(e) => setLocationId(e.target.value)}>
              {locations.length === 0 && <option value="">No branches</option>}
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
          )}
        </Field>
        <Field label="From">
          {(p) => <input {...p} type="date" className="input" value={periodStart} onChange={(e) => setPeriodStart(e.target.value)} />}
        </Field>
        <Field label="To" error={rangeError}>
          {(p) => <input {...p} type="date" className="input" value={periodEnd} onChange={(e) => setPeriodEnd(e.target.value)} />}
        </Field>
        <button type="submit" className="btn-primary" disabled={loading || !locationId}>
          {loading ? 'Loading…' : 'Refresh'}
        </button>
      </form>

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

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <KpiCard label="Shifts in range" value={overview.length} loading={loading} />
        <KpiCard label="Exceptions" value={exceptions.length} tone={exceptions.length ? 'warning' : 'default'} loading={loading} />
        <KpiCard label="Pending adjustments" value={pendingAdjustments.length} tone={pendingAdjustments.length ? 'warning' : 'default'} loading={loading} />
        <KpiCard
          label="Final payable"
          value={fmtMinutes(overview.reduce((s, r) => s + (r.final_payable_minutes ?? r.default_payable_minutes ?? 0), 0))}
          loading={loading}
        />
      </div>

      <Tabs<TabKey>
        label="Attendance views"
        active={tab}
        onChange={setTab}
        tabs={[
          { key: 'overview', label: 'Overview' },
          { key: 'exceptions', label: 'Exceptions', badge: exceptions.length },
          { key: 'adjustments', label: 'Payable adjustments', badge: pendingAdjustments.length },
        ]}
      />

      {tab === 'overview' && (
        <TabPanel id="overview">
          {loading ? (
            <Skeleton rows={4} />
          ) : overview.length === 0 ? (
            <EmptyState
              title="No payable shifts in this range"
              description="Payable time is prepared from published shifts. Prepare it to review and adjust hours."
              action={
                <button className="btn-primary mt-2" onClick={handleSeed} disabled={busyId === 'seed' || !locationId}>
                  {busyId === 'seed' ? 'Preparing…' : 'Prepare payable time'}
                </button>
              }
            />
          ) : (
            <ResponsiveTable
              caption="Attendance overview"
              columns={overviewColumns}
              rows={overview}
              rowKey={(r) => r.shift_id}
              actions={(r) => {
                const p = payableByShift[r.shift_id]
                const locked = r.payable_status === 'materialized'
                return (
                  <button
                    className="btn-secondary"
                    disabled={!p || locked || r.pending_adjustment}
                    title={locked ? 'Already in payroll' : r.pending_adjustment ? 'An adjustment is already pending' : undefined}
                    onClick={() => setAdjusting(r)}
                  >
                    Adjust time
                  </button>
                )
              }}
            />
          )}
        </TabPanel>
      )}

      {tab === 'exceptions' && (
        <TabPanel id="exceptions">
          {loading ? (
            <Skeleton rows={4} />
          ) : exceptions.length === 0 ? (
            <EmptyState title="No exceptions" description="Every clock-in in this range matches a shift." />
          ) : (
            <ResponsiveTable
              caption="Attendance exceptions"
              columns={exceptionColumns}
              rows={exceptions}
              rowKey={(e) => `${e.exception_type}-${e.record_id ?? e.shift_id}-${e.employee_id}`}
              actions={(e) =>
                e.record_id ? (
                  <button className="btn-secondary" onClick={() => setCorrecting(e)}>
                    Correct
                  </button>
                ) : (
                  <span className="text-xs text-muted">No clock-in to correct</span>
                )
              }
            />
          )}
        </TabPanel>
      )}

      {tab === 'adjustments' && (
        <TabPanel id="adjustments">
          {loading ? (
            <Skeleton rows={3} />
          ) : adjustments.length === 0 ? (
            <EmptyState title="No payable-time adjustments" description="Proposed adjustments for this range will appear here." />
          ) : (
            <ResponsiveTable
              caption="Payable time adjustments"
              columns={adjustmentColumns}
              rows={adjustments}
              rowKey={(a) => a.id}
              actions={(a) =>
                a.status === 'pending' ? (
                  <>
                    <button className="btn-primary" disabled={busyId === a.id} onClick={() => handleApply(a)}>
                      {busyId === a.id ? 'Applying…' : 'Apply'}
                    </button>
                    <button className="btn-secondary" disabled={busyId === a.id} onClick={() => setRejecting(a)}>
                      Reject
                    </button>
                  </>
                ) : null
              }
            />
          )}
        </TabPanel>
      )}

      {correcting && (
        <CorrectionDrawer
          exception={correcting}
          record={correcting.record_id ? records[correcting.record_id] : undefined}
          shift={correcting.shift_id ? shifts[correcting.shift_id] : undefined}
          employeeName={names[correcting.employee_id] ?? correcting.employee_name}
          onClose={() => setCorrecting(null)}
          onSaved={() => {
            setCorrecting(null)
            setNotice('Attendance record corrected. The original times are kept in the audit trail.')
            load()
          }}
        />
      )}

      {adjusting && payableByShift[adjusting.shift_id] && (
        <AdjustmentDrawer
          row={adjusting}
          payable={payableByShift[adjusting.shift_id]}
          employeeName={names[adjusting.employee_id] ?? 'Employee'}
          shift={shifts[adjusting.shift_id]}
          onClose={() => setAdjusting(null)}
          onSaved={() => {
            setAdjusting(null)
            setNotice('Adjustment proposed. It needs to be applied before it affects payroll.')
            load()
          }}
        />
      )}

      {rejecting && (
        <RejectAdjustmentModal
          adjustment={rejecting}
          onClose={() => setRejecting(null)}
          onDone={() => {
            setRejecting(null)
            setNotice('Adjustment rejected.')
            load()
          }}
        />
      )}
    </div>
  )
}

function CorrectionDrawer({
  exception,
  record,
  shift,
  employeeName,
  onClose,
  onSaved,
}: {
  exception: AttendanceException
  record?: RecordLite
  shift?: ShiftLite
  employeeName: string
  onClose: () => void
  onSaved: () => void
}) {
  const actualIn = record?.clock_in_at ?? exception.clock_in_at
  const actualOut = record?.clock_out_at ?? exception.clock_out_at
  const [newIn, setNewIn] = useState(toDubaiLocalInput(actualIn))
  const [newOut, setNewOut] = useState(toDubaiLocalInput(actualOut))
  const [reason, setReason] = useState('')
  const [errors, setErrors] = useState<{ in?: string; out?: string; reason?: string }>({})
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)

  const newInIso = fromDubaiLocalInput(newIn)
  const newOutIso = fromDubaiLocalInput(newOut)
  const changedIn = Boolean(newInIso) && newInIso !== (actualIn ? new Date(actualIn).toISOString() : null)
  const changedOut = Boolean(newOutIso) && newOutIso !== (actualOut ? new Date(actualOut).toISOString() : null)

  function validate() {
    const e: typeof errors = {}
    if (!newInIso) e.in = 'Clock-in time is required.'
    if (newInIso && newOutIso && newOutIso <= newInIso) e.out = 'Clock-out must be after clock-in.'
    if ((newInIso && newInIso > new Date().toISOString()) || (newOutIso && newOutIso > new Date().toISOString()))
      e.out = 'Times cannot be in the future.'
    if (!reason.trim()) e.reason = 'A reason is required for every correction.'
    if (!changedIn && !changedOut) e.in = 'Change at least one time.'
    setErrors(e)
    return Object.keys(e).length === 0
  }

  async function save() {
    if (!exception.record_id) return
    setSaving(true)
    setServerError(null)
    // NULL = keep the current value (API contract), so only send what changed.
    const res = await correctAttendanceRecord(
      exception.record_id,
      changedIn ? newInIso : null,
      changedOut ? newOutIso : null,
      reason.trim()
    )
    setSaving(false)
    if (res.error) {
      setServerError(res.error)
      setConfirming(false)
      return
    }
    onSaved()
  }

  const rowCls = 'grid grid-cols-[7rem_1fr_1fr] gap-2 py-1.5 text-sm'

  return (
    <Drawer
      open
      title="Correct attendance"
      description={`${employeeName} · ${fmtDayShort(exception.shift_date)} · ${EXCEPTION_LABEL[exception.exception_type] ?? exception.exception_type}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            disabled={saving}
            onClick={() => {
              if (validate()) setConfirming(true)
            }}
          >
            Review changes
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="rounded-lg bg-surface-alt p-3">
          <div className={`${rowCls} border-b border-border font-semibold text-muted`}>
            <span />
            <span>Clock-in</span>
            <span>Clock-out</span>
          </div>
          <div className={rowCls}>
            <span className="text-muted">Planned</span>
            <span>{shift ? fmtTime(shift.start_time) : '—'}</span>
            <span>{shift ? fmtTime(shift.end_time) : '—'}</span>
          </div>
          <div className={rowCls}>
            <span className="text-muted">Actual</span>
            <span>{fmtDateTime(actualIn)}</span>
            <span>{fmtDateTime(actualOut)}</span>
          </div>
          {record?.corrected && (
            <div className={rowCls}>
              <span className="text-muted">Original</span>
              <span>{fmtDateTime(record.original_clock_in_at)}</span>
              <span>{fmtDateTime(record.original_clock_out_at)}</span>
            </div>
          )}
        </div>

        <Field label="New clock-in (Dubai time)" error={errors.in} required>
          {(p) => <input {...p} type="datetime-local" className="input" value={newIn} onChange={(e) => setNewIn(e.target.value)} data-autofocus />}
        </Field>
        <Field label="New clock-out (Dubai time)" error={errors.out} hint="Clearing this keeps the current clock-out. You cannot correct your own record.">
          {(p) => <input {...p} type="datetime-local" className="input" value={newOut} onChange={(e) => setNewOut(e.target.value)} />}
        </Field>
        <Field label="Reason" error={errors.reason} required hint="Recorded in the audit trail and shown to the employee.">
          {(p) => <textarea {...p} rows={3} className="input" value={reason} onChange={(e) => setReason(e.target.value)} />}
        </Field>
        {serverError && <Alert tone="error">{serverError}</Alert>}
      </div>

      <Modal
        open={confirming}
        title="Save this correction?"
        onClose={() => setConfirming(false)}
        footer={
          <>
            <button className="btn-secondary" onClick={() => setConfirming(false)}>
              Back
            </button>
            <button className="btn-primary" onClick={save} disabled={saving}>
              {saving ? 'Saving…' : 'Save correction'}
            </button>
          </>
        }
      >
        <dl className="space-y-1">
          <div className="flex justify-between gap-3">
            <dt className="text-muted">Clock-in</dt>
            <dd>
              {fmtDateTime(actualIn)} → <strong>{changedIn ? fmtDateTime(newInIso) : 'unchanged'}</strong>
            </dd>
          </div>
          <div className="flex justify-between gap-3">
            <dt className="text-muted">Clock-out</dt>
            <dd>
              {fmtDateTime(actualOut)} → <strong>{changedOut ? fmtDateTime(newOutIso) : 'unchanged'}</strong>
            </dd>
          </div>
          <div className="flex justify-between gap-3">
            <dt className="text-muted">Reason</dt>
            <dd className="text-right">{reason}</dd>
          </div>
        </dl>
      </Modal>
    </Drawer>
  )
}

function AdjustmentDrawer({
  row,
  payable,
  employeeName,
  shift,
  onClose,
  onSaved,
}: {
  row: OverviewRow
  payable: PayableRecord
  employeeName: string
  shift?: ShiftLite
  onClose: () => void
  onSaved: () => void
}) {
  const current = payable.final_payable_minutes ?? payable.default_payable_minutes
  const [hours, setHours] = useState(String(Math.floor(current / 60)))
  const [mins, setMins] = useState(String(current % 60))
  const [reason, setReason] = useState('')
  const [errors, setErrors] = useState<{ time?: string; reason?: string }>({})
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)

  const proposed = Number(hours || 0) * 60 + Number(mins || 0)

  async function submit() {
    const e: typeof errors = {}
    if (!Number.isInteger(proposed) || proposed < 0 || Number(mins) >= 60) e.time = 'Enter whole hours and minutes (0–59).'
    else if (proposed === current) e.time = 'The proposed time is the same as the current payable time.'
    if (!reason.trim()) e.reason = 'A reason is required.'
    setErrors(e)
    if (Object.keys(e).length) return
    setSaving(true)
    setServerError(null)
    const res = await proposeAttendanceAdjustment(payable.id, proposed, reason.trim())
    setSaving(false)
    if (res.error) {
      setServerError(res.error)
      return
    }
    onSaved()
  }

  return (
    <Drawer
      open
      title="Adjust payable time"
      description={`${employeeName} · ${fmtDayShort(row.shift_date)}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={saving}>
            {saving ? 'Submitting…' : 'Propose adjustment'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <dl className="grid grid-cols-2 gap-3 rounded-lg bg-surface-alt p-3 text-sm">
          <div>
            <dt className="text-muted">Planned</dt>
            <dd className="font-medium">
              {shift ? `${fmtTime(shift.start_time)}–${fmtTime(shift.end_time)} · ` : ''}
              {fmtMinutes(payable.planned_minutes)}
            </dd>
          </div>
          <div>
            <dt className="text-muted">Break</dt>
            <dd className="font-medium">{fmtMinutes(payable.planned_break_minutes)}</dd>
          </div>
          <div>
            <dt className="text-muted">Default payable</dt>
            <dd className="font-medium">{fmtMinutes(payable.default_payable_minutes)}</dd>
          </div>
          <div>
            <dt className="text-muted">Current payable</dt>
            <dd className="font-medium">{fmtMinutes(current)}</dd>
          </div>
        </dl>
        <fieldset>
          <legend className="label">New payable time</legend>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Hours" error={errors.time}>
              {(p) => <input {...p} type="number" min={0} inputMode="numeric" className="input" value={hours} onChange={(e) => setHours(e.target.value)} data-autofocus />}
            </Field>
            <Field label="Minutes">
              {(p) => <input {...p} type="number" min={0} max={59} inputMode="numeric" className="input" value={mins} onChange={(e) => setMins(e.target.value)} />}
            </Field>
          </div>
        </fieldset>
        <p className="rounded-lg bg-brand-info-soft px-3 py-2 text-sm text-brand-info-text">
          {fmtMinutes(current)} → <strong>{fmtMinutes(proposed)}</strong> ({proposed - current >= 0 ? '+' : ''}
          {fmtMinutes(proposed - current)})
        </p>
        <Field label="Reason" error={errors.reason} required>
          {(p) => <textarea {...p} rows={3} className="input" value={reason} onChange={(e) => setReason(e.target.value)} />}
        </Field>
        {serverError && <Alert tone="error">{serverError}</Alert>}
      </div>
    </Drawer>
  )
}

function RejectAdjustmentModal({
  adjustment,
  onClose,
  onDone,
}: {
  adjustment: AttendanceAdjustment
  onClose: () => void
  onDone: () => void
}) {
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  async function submit() {
    if (!reason.trim()) {
      setErr('A reason is required.')
      return
    }
    setSaving(true)
    const res = await rejectAttendanceAdjustment(adjustment.id, reason.trim())
    setSaving(false)
    if (res.error) {
      setErr(res.error)
      return
    }
    onDone()
  }
  return (
    <Modal
      open
      title="Reject adjustment"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-danger" onClick={submit} disabled={saving}>
            {saving ? 'Rejecting…' : 'Reject'}
          </button>
        </>
      }
    >
      <p>
        Proposed {fmtMinutes(adjustment.proposed_minutes)} — “{adjustment.reason}”
      </p>
      <Field label="Reason for rejecting" error={err} required>
        {(p) => <textarea {...p} rows={3} className="input" value={reason} onChange={(e) => setReason(e.target.value)} data-autofocus />}
      </Field>
    </Modal>
  )
}
