import { useCallback, useEffect, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { Alert, Drawer, Field, Modal, Skeleton, TabPanel, Tabs, type TabDef } from '../components/ui'
import { completenessItemLabel, docTypeLabel, expiryStatus } from '../lib/documents'
import {
  CHANGE_FIELD_LABEL,
  allowedStatusMoves,
  decideEmployeeChangeRequest,
  editableFieldsFor,
  diffEmployeeChanges,
  getEmployeeCompleteness,
  listEmployeeAudit,
  setEmployeeStatus,
  updateEmployeeDetails,
  type AuditRow,
  type Completeness,
} from '../lib/api/employees'
import { fmtClockRange, fmtDate, fmtDateTime, fmtDayShort, fmtMinutes, fmtTime, humanize, todayDubai, addDays } from '../lib/format'
import type { Employee, EmployeeChangeRequest, EmployeeDocument, EmployeeStatus, LeaveBalance, LeaveRequest } from '../types/db'

const EXPIRY_DOCS: { key: 'passport_exp' | 'visa_exp' | 'labor_card_exp' | 'health_card_exp'; label: string }[] = [
  { key: 'passport_exp', label: 'Passport' },
  { key: 'visa_exp', label: 'Visa' },
  { key: 'labor_card_exp', label: 'Labour card' },
  { key: 'health_card_exp', label: 'Health card' },
]

const EXPIRY_TONE: Record<string, 'neutral' | 'warning' | 'risk' | 'success'> = {
  expired: 'risk',
  expiring: 'warning',
  current: 'success',
  non_expiring: 'neutral',
}

const STATUS_ACTION_LABEL: Record<EmployeeStatus, string> = {
  candidate: 'Move to candidate',
  pre_boarding: 'Start pre-boarding',
  active: 'Activate',
  inactive: 'Inactivate',
}

type TabKey = 'overview' | 'employment' | 'documents' | 'schedule' | 'attendance' | 'leave' | 'payslips' | 'audit'

type FullEmployee = Employee

interface Compensation {
  employee_id: string
  pay_type: string
  pay_rate: number | null
  overtime_multiplier: number
  holiday_multiplier: number
  updated_at: string | null
}

interface IdentityDocs {
  employee_id: string
  national_id_no: string | null
  passport_no: string | null
  visa_no: string | null
  labor_card_no: string | null
  health_card_no: string | null
  bank_name: string | null
  bank_iban: string | null
  updated_at: string
}

// Employee profile (/employees/:id). RLS (employees_select) decides which
// ids resolve at all — a location_manager opening an out-of-location id gets
// the same "not found" as a non-existent id. Payslips and compensation are
// owner/entity_admin only: for location_manager the Payslips tab is not
// rendered at all (not just hidden) and its query never runs.
export default function EmployeeProfile() {
  const { id } = useParams<{ id: string }>()
  const { profile } = useAuth()
  const [params, setParams] = useSearchParams()
  const isAdmin = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const [employee, setEmployee] = useState<FullEmployee | null>(null)
  const [loading, setLoading] = useState(true)
  const [notFound, setNotFound] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [completeness, setCompleteness] = useState<Completeness | null>(null)
  const [statusTarget, setStatusTarget] = useState<EmployeeStatus | null>(null)
  const [editing, setEditing] = useState(false)

  const tabs: TabDef<TabKey>[] = [
    { key: 'overview', label: 'Overview' },
    { key: 'employment', label: 'Employment' },
    { key: 'documents', label: 'Documents' },
    { key: 'schedule', label: 'Schedule' },
    { key: 'attendance', label: 'Attendance' },
    { key: 'leave', label: 'Leave' },
    ...(isAdmin ? [{ key: 'payslips' as const, label: 'Payslips' }] : []),
    { key: 'audit', label: 'Audit' },
  ]
  const requested = params.get('tab') as TabKey | null
  const tab: TabKey = requested && tabs.some((t) => t.key === requested) ? requested : 'overview'
  const setTab = (k: TabKey) => setParams({ tab: k }, { replace: true })

  const load = useCallback(async () => {
    if (!id) return
    setLoading(true)
    setError(null)
    setNotFound(false)
    const empRes = await supabase
      .from('employees')
      .select(
        'id, entity_id, home_location_id, position_id, auth_user_id, full_name, preferred_name, photo_url, dob, gender, nationality, phone, email, emergency_contact_name, emergency_contact_phone, passport_exp, visa_exp, labor_card_exp, health_card_exp, employment_type, employment_status, join_date, probation_end_date, notes, created_at, updated_at, locations(id, name), positions(id, title, department)'
      )
      .eq('id', id)
      .maybeSingle()
    if (empRes.error) {
      setError(empRes.error.message)
    } else if (!empRes.data) {
      setNotFound(true)
    } else {
      setEmployee(empRes.data as unknown as FullEmployee)
    }
    setLoading(false)
    const c = await getEmployeeCompleteness(id)
    // Not-yet-deployed RPC → simply no completeness bar.
    if (!c.error) setCompleteness(c.data)
  }, [id])

  useEffect(() => {
    load()
  }, [load])

  if (loading) {
    return (
      <div className="space-y-3">
        <Skeleton rows={1} className="h-24" />
        <Skeleton rows={2} className="h-40" />
      </div>
    )
  }

  if (notFound || !employee) {
    return (
      <div className="space-y-5">
        <Link to="/employees" className="text-sm font-medium text-brand-blue hover:underline">
          ← Back to People
        </Link>
        {error ? <Alert tone="error">{error}</Alert> : <EmptyState title="Employee not found" description="This record doesn't exist, or you don't have access to it." />}
      </div>
    )
  }

  const status = (employee.employment_status ?? 'candidate') as EmployeeStatus
  const canEdit = editableFieldsFor(profile?.role).length > 0

  return (
    <div className="space-y-5">
      <Link to="/employees" className="text-sm font-medium text-brand-blue hover:underline">
        ← Back to People
      </Link>

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

      <header className="card space-y-3">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold text-ink">{employee.preferred_name || employee.full_name}</h1>
            {employee.preferred_name && <p className="text-sm text-muted">{employee.full_name}</p>}
            <p className="text-sm text-muted">
              {employee.positions?.title ?? 'No role set'} · {employee.locations?.name ?? 'No branch set'}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <StatusBadge status={status} />
            {canEdit && (
              <>
                <button className="btn-secondary" onClick={() => setEditing(true)}>
                  Edit details
                </button>
                {(allowedStatusMoves(profile?.role, status) as EmployeeStatus[]).map((s) => (
                  <button key={s} className={s === 'inactive' ? 'btn-secondary text-brand-risk' : 'btn-primary'} onClick={() => setStatusTarget(s)}>
                    {STATUS_ACTION_LABEL[s]}
                  </button>
                ))}
              </>
            )}
          </div>
        </div>
        {completeness ? (
          <div>
            <div className="flex items-center justify-between text-sm">
              <span className="font-medium text-ink">Profile completeness</span>
              <span className="text-muted">{Math.round(completeness.percent)}%</span>
            </div>
            <div
              className="mt-1 h-2 overflow-hidden rounded-full bg-surface-alt"
              role="progressbar"
              aria-label="Profile completeness"
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={Math.round(completeness.percent)}
            >
              <div
                className={`h-full rounded-full ${completeness.percent >= 100 ? 'bg-brand-action' : completeness.percent >= 60 ? 'bg-brand-info' : 'bg-brand-warning'}`}
                style={{ width: `${Math.min(100, Math.max(0, completeness.percent))}%` }}
              />
            </div>
            {completeness.missing?.length > 0 && (
              <p className="mt-1 text-xs text-muted">Missing: {completeness.missing.map(completenessItemLabel).join(', ')}</p>
            )}
          </div>
        ) : null}
      </header>

      <Tabs<TabKey> label="Employee sections" tabs={tabs} active={tab} onChange={setTab} />

      <TabPanel id={tab}>
        {tab === 'overview' && <OverviewTab employee={employee} onChanged={load} onNotice={setNotice} onError={setError} />}
        {tab === 'employment' && <EmploymentTab employee={employee} canReveal={isAdmin} />}
        {tab === 'documents' && <DocumentsTab employee={employee} />}
        {tab === 'schedule' && <ScheduleTab employeeId={employee.id} />}
        {tab === 'attendance' && <AttendanceTab employeeId={employee.id} />}
        {tab === 'leave' && <LeaveTab employeeId={employee.id} />}
        {tab === 'payslips' && isAdmin && <PayslipsTab employeeId={employee.id} />}
        {tab === 'audit' && <AuditTab employeeId={employee.id} isOwner={profile?.role === 'owner'} />}
      </TabPanel>

      {statusTarget && (
        <StatusModal
          employee={employee}
          target={statusTarget}
          completeness={completeness}
          onClose={() => setStatusTarget(null)}
          onDone={(msg) => {
            setStatusTarget(null)
            setNotice(msg)
            load()
          }}
        />
      )}
      {editing && (
        <EditDrawer
          employee={employee}
          role={profile?.role}
          onClose={() => setEditing(false)}
          onDone={() => {
            setEditing(false)
            setNotice('Employee details updated.')
            load()
          }}
        />
      )}
    </div>
  )
}

function Dl({ items }: { items: [string, string][] }) {
  return (
    <dl className="grid grid-cols-1 gap-x-4 gap-y-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
      {items.map(([label, value]) => (
        <div key={label}>
          <dt className="text-xs text-muted">{label}</dt>
          <dd className="text-ink">{value || '—'}</dd>
        </div>
      ))}
    </dl>
  )
}

function OverviewTab({
  employee,
  onChanged,
  onNotice,
  onError,
}: {
  employee: FullEmployee
  onChanged: () => void
  onNotice: (m: string) => void
  onError: (m: string) => void
}) {
  const [requests, setRequests] = useState<EmployeeChangeRequest[] | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const load = useCallback(() => {
    supabase
      .from('employee_change_requests')
      .select('*')
      .eq('employee_id', employee.id)
      .order('requested_at', { ascending: false })
      .limit(20)
      .then(({ data }) => setRequests((data ?? []) as EmployeeChangeRequest[]))
  }, [employee.id])
  useEffect(load, [load])

  async function decide(r: EmployeeChangeRequest, action: 'approve' | 'reject') {
    setBusyId(r.id)
    // decide_employee_change_request() re-checks authority and that the
    // request is still pending, so a double click can't replay a decision.
    const res = await decideEmployeeChangeRequest(r.id, action, null)
    setBusyId(null)
    if (res.error) return onError(res.error)
    onNotice(action === 'approve' ? 'Change applied.' : 'Change request rejected.')
    load()
    onChanged()
  }

  const pending = (requests ?? []).filter((r) => r.status === 'pending')
  const decided = (requests ?? []).filter((r) => r.status !== 'pending')

  return (
    <div className="space-y-4">
      <section className="card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Contact</h2>
        <Dl
          items={[
            ['Phone', employee.phone ?? ''],
            ['Email', employee.email ?? ''],
            ['Emergency contact', employee.emergency_contact_name ?? ''],
            ['Emergency phone', employee.emergency_contact_phone ?? ''],
            ['Nationality', employee.nationality ?? ''],
            ['Date of birth', employee.dob ? fmtDate(employee.dob) : ''],
            ['Joined', employee.join_date ? fmtDate(employee.join_date) : ''],
            ['Self-service login', employee.auth_user_id ? 'Linked' : 'Not linked'],
          ]}
        />
      </section>
      {pending.length > 0 && (
        <section className="card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Pending change requests</h2>
          <ul className="space-y-2">
            {pending.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span>
                  {CHANGE_FIELD_LABEL[r.field_name] ?? humanize(r.field_name)}: {r.old_value ?? '—'} → <strong>{r.new_value}</strong>
                  {r.reason && <span className="block text-xs text-muted">“{r.reason}”</span>}
                </span>
                <span className="flex gap-2">
                  <button className="btn-primary" disabled={busyId === r.id} onClick={() => decide(r, 'approve')}>
                    Approve
                  </button>
                  <button className="btn-secondary" disabled={busyId === r.id} onClick={() => decide(r, 'reject')}>
                    Reject
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
      {decided.length > 0 && (
        <section className="card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Change request history</h2>
          <ul className="space-y-1.5">
            {decided.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span>
                  {CHANGE_FIELD_LABEL[r.field_name] ?? humanize(r.field_name)}: “{r.new_value}” · {fmtDate(r.requested_at)}
                </span>
                <StatusBadge status={r.status} />
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  )
}

function EmploymentTab({ employee, canReveal }: { employee: FullEmployee; canReveal: boolean }) {
  return (
    <div className="space-y-4">
      <section className="card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Employment</h2>
        <Dl
          items={[
            ['Status', humanize(employee.employment_status)],
            ['Employment type', humanize(employee.employment_type)],
            ['Position', employee.positions?.title ?? ''],
            ['Department', employee.positions?.department ?? ''],
            ['Home branch', employee.locations?.name ?? ''],
            ['Join date', employee.join_date ? fmtDate(employee.join_date) : ''],
            ['Probation ends', employee.probation_end_date ? fmtDate(employee.probation_end_date) : ''],
            ['Gender', humanize(employee.gender)],
          ]}
        />
        {employee.notes && <p className="mt-3 rounded-lg bg-surface-alt p-3 text-sm">{employee.notes}</p>}
      </section>
      {canReveal && <SensitiveInfoPanel employeeId={employee.id} />}
    </div>
  )
}

function DocumentsTab({ employee }: { employee: FullEmployee }) {
  const [docs, setDocs] = useState<EmployeeDocument[] | null>(null)
  useEffect(() => {
    supabase
      .from('employee_documents')
      .select('*')
      .eq('employee_id', employee.id)
      .eq('is_current', true)
      .order('doc_type')
      .then(({ data }) => setDocs((data ?? []) as unknown as EmployeeDocument[]))
  }, [employee.id])
  return (
    <div className="space-y-4">
      <section className="card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Document expiry</h2>
        <ul className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {EXPIRY_DOCS.map((d) => {
            const st = expiryStatus(employee[d.key])
            return (
              <li key={d.key} className="rounded-lg bg-surface-alt p-3">
                <p className="text-xs text-muted">{d.label}</p>
                <p className="mt-1 text-sm text-ink">{employee[d.key] ? fmtDate(employee[d.key]) : 'Not on file'}</p>
                <div className="mt-1.5">
                  <StatusBadge status={st} tone={EXPIRY_TONE[st]} />
                </div>
              </li>
            )
          })}
        </ul>
      </section>
      <section className="card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Current documents</h2>
        {docs === null ? (
          <Skeleton rows={2} className="h-10" />
        ) : docs.length === 0 ? (
          <p className="text-sm text-muted">No documents on file yet.</p>
        ) : (
          <ul className="space-y-1.5">
            {docs.map((d) => (
              <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span>
                  {docTypeLabel(d.doc_type)} · v{d.version_number}
                  {d.expiry_date && <span className="text-muted"> · expires {fmtDate(d.expiry_date)}</span>}
                </span>
                <StatusBadge status={d.review_status} />
              </li>
            ))}
          </ul>
        )}
        <p className="mt-3 text-sm text-muted">
          Uploads, renewals and reviews happen in{' '}
          <Link to="/documents" className="font-medium text-brand-blue hover:underline">
            Documents
          </Link>
          .
        </p>
      </section>
    </div>
  )
}

function ScheduleTab({ employeeId }: { employeeId: string }) {
  const [rows, setRows] = useState<{ id: string; shift_date: string; start_time: string; end_time: string; status: string; is_published: boolean; locations: { name: string } | null }[] | null>(null)
  useEffect(() => {
    const today = todayDubai()
    supabase
      .from('shifts')
      .select('id, shift_date, start_time, end_time, status, is_published, locations(name)')
      .eq('employee_id', employeeId)
      .gte('shift_date', addDays(today, -7))
      .lte('shift_date', addDays(today, 21))
      .order('shift_date')
      .order('start_time')
      .then(({ data }) => setRows((data ?? []) as unknown as NonNullable<typeof rows>))
  }, [employeeId])
  return (
    <section className="card">
      <h2 className="mb-3 text-sm font-semibold text-ink">Shifts — last 7 days and next 3 weeks</h2>
      {rows === null ? (
        <Skeleton rows={3} className="h-10" />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No shifts in this period.</p>
      ) : (
        <ul className="space-y-1.5">
          {rows.map((s) => (
            <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
              <span>
                {fmtDayShort(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)}
                {s.locations?.name && <span className="text-muted"> · {s.locations.name}</span>}
              </span>
              <span className="flex gap-1">
                {!s.is_published && <StatusBadge status="draft" />}
                <StatusBadge status={s.status} />
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function AttendanceTab({ employeeId }: { employeeId: string }) {
  const [rows, setRows] = useState<{ id: string; clock_in_at: string; clock_out_at: string | null; corrected: boolean; correction_reason: string | null }[] | null>(null)
  useEffect(() => {
    supabase
      .from('attendance_records')
      .select('id, clock_in_at, clock_out_at, corrected, correction_reason')
      .eq('employee_id', employeeId)
      .gte('clock_in_at', addDays(todayDubai(), -30))
      .order('clock_in_at', { ascending: false })
      .then(({ data }) => setRows((data ?? []) as NonNullable<typeof rows>))
  }, [employeeId])
  return (
    <section className="card">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-sm font-semibold text-ink">Attendance — last 30 days</h2>
        <Link to="/attendance" className="text-sm font-medium text-brand-blue hover:underline">
          Open workspace
        </Link>
      </div>
      {rows === null ? (
        <Skeleton rows={3} className="h-10" />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No clock-ins recorded.</p>
      ) : (
        <ul className="space-y-1.5">
          {rows.map((r) => {
            const mins = r.clock_out_at ? (new Date(r.clock_out_at).getTime() - new Date(r.clock_in_at).getTime()) / 60000 : null
            return (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span>
                  {fmtDayShort(r.clock_in_at)} · {fmtClockRange(r.clock_in_at, r.clock_out_at)}
                  {r.corrected && <span className="block text-xs text-brand-info-text">Corrected: {r.correction_reason}</span>}
                </span>
                <span className="flex items-center gap-2">
                  <span className="font-medium">{fmtMinutes(mins)}</span>
                  {!r.clock_out_at && <StatusBadge status="Open" tone="warning" />}
                </span>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}

function LeaveTab({ employeeId }: { employeeId: string }) {
  const [requests, setRequests] = useState<LeaveRequest[] | null>(null)
  const [balances, setBalances] = useState<LeaveBalance[]>([])
  useEffect(() => {
    supabase
      .from('leave_requests')
      .select('*, leave_types(id, name)')
      .eq('employee_id', employeeId)
      .order('requested_at', { ascending: false })
      .limit(20)
      .then(({ data }) => setRequests((data ?? []) as unknown as LeaveRequest[]))
    supabase
      .from('leave_balances')
      .select('*, leave_types(id, name)')
      .eq('employee_id', employeeId)
      .then(({ data }) => setBalances((data ?? []) as unknown as LeaveBalance[]))
  }, [employeeId])
  return (
    <div className="space-y-4">
      {balances.length > 0 && (
        <section className="card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Balances</h2>
          <ul className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {balances.map((b) => (
              <li key={b.id} className="rounded-lg bg-surface-alt p-3">
                <p className="text-xs text-muted">{b.leave_types?.name ?? 'Leave'}</p>
                <p className="text-lg font-semibold text-ink">{b.balance_days} days</p>
              </li>
            ))}
          </ul>
        </section>
      )}
      <section className="card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Requests</h2>
        {requests === null ? (
          <Skeleton rows={2} className="h-10" />
        ) : requests.length === 0 ? (
          <p className="text-sm text-muted">No leave requests yet.</p>
        ) : (
          <ul className="space-y-1.5">
            {requests.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span>
                  {r.leave_types?.name ?? 'Leave'} · {fmtDate(r.start_date)} – {fmtDate(r.end_date)} · {r.days_requested} day(s)
                </span>
                <StatusBadge status={r.status} />
              </li>
            ))}
          </ul>
        )}
        <p className="mt-3 text-sm text-muted">
          Decisions happen in{' '}
          <Link to="/leave" className="font-medium text-brand-blue hover:underline">
            Leave
          </Link>
          .
        </p>
      </section>
    </div>
  )
}

function PayslipsTab({ employeeId }: { employeeId: string }) {
  const [rows, setRows] = useState<
    { id: string; net_pay: number; base_pay: number; total_deductions: number; generated_at: string; payroll_runs: { period_start: string; period_end: string; status: string } | null }[] | null
  >(null)
  useEffect(() => {
    supabase
      .from('payslips')
      .select('id, net_pay, base_pay, total_deductions, generated_at, payroll_runs(period_start, period_end, status)')
      .eq('employee_id', employeeId)
      .order('generated_at', { ascending: false })
      .limit(24)
      .then(({ data }) => setRows((data ?? []) as unknown as NonNullable<typeof rows>))
  }, [employeeId])
  const aed = (n: number) => `AED ${Number(n).toLocaleString('en-AE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
  return (
    <section className="card">
      <h2 className="mb-3 text-sm font-semibold text-ink">Payslips</h2>
      {rows === null ? (
        <Skeleton rows={2} className="h-10" />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No payslips yet.</p>
      ) : (
        <ul className="space-y-1.5">
          {rows.map((p) => (
            <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
              <span>
                {p.payroll_runs ? `${fmtDate(p.payroll_runs.period_start)} – ${fmtDate(p.payroll_runs.period_end)}` : fmtDate(p.generated_at)}
                <span className="block text-xs text-muted">
                  Base {aed(p.base_pay)} · Deductions {aed(p.total_deductions)}
                </span>
              </span>
              <span className="flex items-center gap-2">
                <span className="font-semibold">{aed(p.net_pay)}</span>
                {p.payroll_runs && <StatusBadge status={p.payroll_runs.status} />}
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function AuditTab({ employeeId, isOwner }: { employeeId: string; isOwner: boolean }) {
  const [rows, setRows] = useState<AuditRow[] | null>(null)
  useEffect(() => {
    if (!isOwner) return
    listEmployeeAudit(employeeId).then((r) => setRows(r.data ?? []))
  }, [employeeId, isOwner])
  if (!isOwner) {
    return (
      <section className="card">
        <p className="text-sm text-muted">The full audit trail for this employee is visible to the Owner.</p>
      </section>
    )
  }
  return (
    <section className="card">
      <h2 className="mb-3 text-sm font-semibold text-ink">Audit trail</h2>
      {rows === null ? (
        <Skeleton rows={3} className="h-10" />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No audit entries.</p>
      ) : (
        <ol className="space-y-1.5">
          {rows.map((a) => (
            <li key={a.id} className="rounded-lg bg-surface-alt px-3 py-2 text-sm">
              <span className="font-medium">{humanize(a.action)}</span> · {humanize(a.table_name)}
              <span className="block text-xs text-muted">{fmtDateTime(a.changed_at)}</span>
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}

function StatusModal({
  employee,
  target,
  completeness,
  onClose,
  onDone,
}: {
  employee: FullEmployee
  target: EmployeeStatus
  completeness: Completeness | null
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const needsReason = target === 'inactive' || employee.employment_status === 'inactive'
  // Activation is refused server-side until every key document is approved and unexpired.
  const missingKeyDocs =
    target === 'active' ? (completeness?.missing ?? []).filter((m) => m.endsWith('_document')) : []
  const blocked = missingKeyDocs.length > 0

  async function submit() {
    if (blocked) return
    if (needsReason && !reason.trim()) return setErr('A reason is required for this change.')
    setSaving(true)
    const res = await setEmployeeStatus(employee.id, target, reason.trim() || null)
    setSaving(false)
    if (res.error) return setErr(res.error)
    onDone(`${employee.full_name} is now ${humanize(target).toLowerCase()}.`)
  }

  return (
    <Modal
      open
      title={`${STATUS_ACTION_LABEL[target]} ${employee.full_name}?`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className={target === 'inactive' ? 'btn-danger' : 'btn-primary'} onClick={submit} disabled={saving || blocked}>
            {saving ? 'Saving…' : STATUS_ACTION_LABEL[target]}
          </button>
        </>
      }
    >
      <p>
        Status: <StatusBadge status={employee.employment_status ?? 'candidate'} /> → <StatusBadge status={target} />
      </p>
      {target === 'inactive' && (
        <p className="text-muted">They will no longer be able to clock in or be scheduled. Records and history are kept.</p>
      )}
      {blocked && (
        <Alert tone="warning">
          Key documents must be approved and in date before activation. Missing:{' '}
          {missingKeyDocs.map(completenessItemLabel).join(', ')}. Add them on the Documents tab.
        </Alert>
      )}
      <Field label={needsReason ? 'Reason' : 'Note (optional)'} error={err} required={needsReason}>
        {(p) => <textarea {...p} rows={3} className="input" value={reason} onChange={(e) => setReason(e.target.value)} data-autofocus />}
      </Field>
    </Modal>
  )
}

function EditDrawer({
  employee,
  role,
  onClose,
  onDone,
}: {
  employee: FullEmployee
  role: string | undefined
  onClose: () => void
  onDone: () => void
}) {
  const EDITABLE_FIELDS = editableFieldsFor(role)
  const record = employee as unknown as Record<string, unknown>
  const [lookups, setLookups] = useState<Record<string, { value: string; label: string }[]>>({})
  useEffect(() => {
    Promise.all([
      supabase.from('positions').select('id, title').eq('entity_id', employee.entity_id).order('title'),
      supabase.from('locations').select('id, name').eq('entity_id', employee.entity_id).order('name'),
    ]).then(([pos, loc]) =>
      setLookups({
        position_id: ((pos.data ?? []) as { id: string; title: string }[]).map((p) => ({ value: p.id, label: p.title })),
        home_location_id: ((loc.data ?? []) as { id: string; name: string }[]).map((l) => ({ value: l.id, label: l.name })),
      })
    )
  }, [employee.entity_id])
  const [draft, setDraft] = useState<Record<string, string>>(() =>
    Object.fromEntries(EDITABLE_FIELDS.map((f) => [f.key, record[f.key] == null ? '' : String(record[f.key])]))
  )
  const [reviewing, setReviewing] = useState(false)
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [fieldError, setFieldError] = useState<Record<string, string>>({})
  const changes = diffEmployeeChanges(record, draft)
  const changedKeys = Object.keys(changes)

  function review() {
    const e: Record<string, string> = {}
    if ('full_name' in draft && !draft.full_name.trim()) e.full_name = 'Full name is required.'
    if (draft.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(draft.email.trim())) e.email = 'Enter a valid email.'
    setFieldError(e)
    if (Object.keys(e).length) return
    if (changedKeys.length === 0) return setServerError('No changes to save.')
    setServerError(null)
    setReviewing(true)
  }

  async function save() {
    setSaving(true)
    const res = await updateEmployeeDetails(employee.id, changes)
    setSaving(false)
    setReviewing(false)
    if (res.error) return setServerError(res.error)
    onDone()
  }

  const label = (k: string) => EDITABLE_FIELDS.find((f) => f.key === k)?.label ?? k
  const show = (k: string, v: unknown) => {
    if (v == null || v === '') return '—'
    const def = EDITABLE_FIELDS.find((f) => f.key === k)
    if (def?.type === 'date') return fmtDate(String(v))
    if (def?.type === 'select') return humanize(String(v))
    if (def?.type === 'lookup') return lookups[k]?.find((o) => o.value === v)?.label ?? String(v)
    return String(v)
  }

  return (
    <Drawer
      open
      wide
      title="Edit employee details"
      description={employee.full_name}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={review} disabled={saving}>
            Review {changedKeys.length ? `${changedKeys.length} change(s)` : 'changes'}
          </button>
        </>
      }
    >
      <div className="grid gap-4 sm:grid-cols-2">
        {EDITABLE_FIELDS.map((f, i) => (
          <Field key={f.key} label={f.label} error={fieldError[f.key]} required={f.key === 'full_name'}>
            {(p) =>
              f.type === 'lookup' ? (
                <select {...p} className="input" value={draft[f.key]} onChange={(e) => setDraft({ ...draft, [f.key]: e.target.value })}>
                  <option value="">Not set</option>
                  {(lookups[f.key] ?? []).map((o) => (
                    <option key={o.value} value={o.value}>
                      {o.label}
                    </option>
                  ))}
                </select>
              ) : f.type === 'textarea' ? (
                <textarea {...p} rows={3} className="input" value={draft[f.key]} onChange={(e) => setDraft({ ...draft, [f.key]: e.target.value })} />
              ) : f.type === 'select' ? (
                <select {...p} className="input" value={draft[f.key]} onChange={(e) => setDraft({ ...draft, [f.key]: e.target.value })}>
                  <option value="">Not set</option>
                  {f.options!.map((o) => (
                    <option key={o} value={o}>
                      {humanize(o)}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  {...p}
                  type={f.type}
                  className="input"
                  value={draft[f.key]}
                  onChange={(e) => setDraft({ ...draft, [f.key]: e.target.value })}
                  data-autofocus={i === 0 ? true : undefined}
                />
              )
            }
          </Field>
        ))}
      </div>
      {serverError && (
        <div className="mt-4">
          <Alert tone="error">{serverError}</Alert>
        </div>
      )}
      <Modal
        open={reviewing}
        title="Confirm changes"
        onClose={() => setReviewing(false)}
        footer={
          <>
            <button className="btn-secondary" onClick={() => setReviewing(false)}>
              Back
            </button>
            <button className="btn-primary" onClick={save} disabled={saving}>
              {saving ? 'Saving…' : 'Save changes'}
            </button>
          </>
        }
      >
        <table className="w-full text-left text-sm">
          <caption className="sr-only">Before and after</caption>
          <thead className="text-xs text-muted">
            <tr>
              <th scope="col" className="py-1">
                Field
              </th>
              <th scope="col" className="py-1">
                Before
              </th>
              <th scope="col" className="py-1">
                After
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {changedKeys.map((k) => (
              <tr key={k}>
                <td className="py-1.5 pr-2 text-muted">{label(k)}</td>
                <td className="py-1.5 pr-2 line-through decoration-brand-risk/60">{show(k, record[k])}</td>
                <td className="py-1.5 font-medium">{show(k, changes[k])}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Modal>
    </Drawer>
  )
}

// Compensation and identity documents load only after an explicit click,
// never with the page — a deliberate speed bump against casually loading
// salary/bank/passport numbers while browsing.
function SensitiveInfoPanel({ employeeId }: { employeeId: string }) {
  const [revealed, setRevealed] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [compensation, setCompensation] = useState<Compensation | null>(null)
  const [identity, setIdentity] = useState<IdentityDocs | null>(null)

  async function handleReveal() {
    setLoading(true)
    setError(null)
    const [compRes, idRes] = await Promise.all([
      supabase.from('employee_compensation').select('*').eq('employee_id', employeeId).maybeSingle(),
      supabase.from('employee_identity_documents').select('*').eq('employee_id', employeeId).maybeSingle(),
    ])
    setLoading(false)
    if (compRes.error || idRes.error) {
      setError(compRes.error?.message ?? idRes.error?.message ?? 'Failed to load sensitive information.')
      return
    }
    setCompensation((compRes.data as Compensation | null) ?? null)
    setIdentity((idRes.data as IdentityDocs | null) ?? null)
    setRevealed(true)
  }

  return (
    <section className="card">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-ink">Compensation & identity documents</h2>
        {revealed ? (
          <button className="btn-secondary" onClick={() => setRevealed(false)}>
            Hide
          </button>
        ) : (
          <button onClick={handleReveal} disabled={loading} className="btn-secondary">
            {loading ? 'Loading…' : 'Reveal'}
          </button>
        )}
      </div>
      {error && (
        <div className="mt-2">
          <Alert tone="error">{error}</Alert>
        </div>
      )}
      {!revealed && !error && <p className="mt-1 text-sm text-muted">Salary, bank details and identity numbers are hidden by default.</p>}
      {revealed && (
        <div className="mt-3">
          <Dl
            items={[
              ['Pay type', humanize(compensation?.pay_type)],
              ['Pay rate', compensation?.pay_rate != null ? String(compensation.pay_rate) : ''],
              ['Overtime multiplier', compensation?.overtime_multiplier != null ? String(compensation.overtime_multiplier) : ''],
              ['Holiday multiplier', compensation?.holiday_multiplier != null ? String(compensation.holiday_multiplier) : ''],
              ['Passport no.', identity?.passport_no ?? ''],
              ['Emirates ID no.', identity?.national_id_no ?? ''],
              ['Visa no.', identity?.visa_no ?? ''],
              ['Labour card no.', identity?.labor_card_no ?? ''],
              ['Health card no.', identity?.health_card_no ?? ''],
              ['Bank name', identity?.bank_name ?? ''],
              ['Bank IBAN', identity?.bank_iban ?? ''],
            ]}
          />
        </div>
      )}
    </section>
  )
}
