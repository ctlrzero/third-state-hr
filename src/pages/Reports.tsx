import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { EmptyState } from '../components/EmptyState'
import { StatusBadge } from '../components/StatusBadge'
import type { Employee, Location } from '../types/db'

interface Metrics {
  activeEmployees: number
  openRequisitions: number
  pendingDocuments: number
  pendingLeave: number
  openShifts: number
  pendingSwaps: number
  payrollRunsInProgress: number | null // null when not applicable to this role (location_manager)
}

interface AuditRow {
  id: string
  table_name: string
  record_id: string
  changed_by: string | null
  changed_at: string
  action: string | null
  old_value: unknown
  new_value: unknown
  entity_id: string | null
  location_id: string | null
  employee_id: string | null
}

// Reports & audit: cross-module summary metrics plus an audit log viewer.
// Every metric query reuses each table's existing RLS scope (entity_id /
// home_location filter, same as the admin queues in Schedules/Leave/
// Documents/Recruiting) — this page adds no new data access, just totals.
// The audit log viewer goes through get_audit_log() rather than a direct
// `.from('audit_log')` query (direct table SELECT is owner-only). As of the
// Phase 1.2 audit-architecture rework, audit_log carries entity_id/
// location_id/employee_id columns populated directly by each writing
// function at write time — get_audit_log() filters on these columns
// directly rather than resolving ownership via a join chain. Owner sees
// everything; entity_admin sees their own entity; location_manager now also
// gets a curated set of operational events (shift/swap/document/timesheet)
// scoped to their own location (a new capability — previously always
// empty for this role); employee/staff access is a separate curated
// "approved own-history" view, not surfaced on this admin/manager-only
// screen (staff never reaches this component at all — see the early return
// above).
export default function Reports() {
  const { profile, activeEntityId } = useAuth()

  if (profile?.role === 'staff') {
    return (
      <div className="space-y-5">
        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-muted">Third State Café</p>
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Reports</h1>
        </div>
        <EmptyState title="Not available" description="Reports & audit is an owner/admin/manager view." />
      </div>
    )
  }

  return <ReportsView role={profile?.role} activeEntityId={activeEntityId} />
}

function ReportsView({ role, activeEntityId }: { role: string | undefined; activeEntityId: string | null }) {
  const { entities } = useAuth()
  const [metrics, setMetrics] = useState<Metrics | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  async function loadMetrics() {
    if (!activeEntityId) return
    setLoading(true)
    setError(null)

    // Each query below is scoped to the active entity exactly the way the
    // corresponding admin screen already scopes it — this page doesn't
    // grant any new read access, it just counts what the signed-in role
    // could already see one table at a time.
    const [empRes, reqRes, docRes, leaveRes, shiftRes, swapRes, payrollRes] = await Promise.all([
      supabase.from('employees').select('id', { count: 'exact', head: true }).eq('entity_id', activeEntityId).eq('employment_status', 'active'),
      supabase.from('job_requisitions').select('id', { count: 'exact', head: true }).eq('entity_id', activeEntityId).eq('status', 'open'),
      supabase.from('employee_documents').select('id, employees!inner(entity_id)', { count: 'exact', head: true }).eq('employees.entity_id', activeEntityId).eq('review_status', 'pending_review'),
      supabase.from('leave_requests').select('id, employees!inner(entity_id)', { count: 'exact', head: true }).eq('employees.entity_id', activeEntityId).eq('status', 'pending'),
      supabase.from('shifts').select('id', { count: 'exact', head: true }).eq('entity_id', activeEntityId).eq('status', 'open'),
      supabase.from('shift_swap_requests').select('id, shifts!inner(entity_id)', { count: 'exact', head: true }).eq('shifts.entity_id', activeEntityId).eq('status', 'claimed'),
      role === 'location_manager'
        ? Promise.resolve({ count: null, error: null })
        : supabase.from('payroll_runs').select('id', { count: 'exact', head: true }).eq('entity_id', activeEntityId).in('status', ['draft', 'in_review']),
    ])

    const firstError = [empRes, reqRes, docRes, leaveRes, shiftRes, swapRes, payrollRes].find((r) => r.error)?.error
    if (firstError) setError(firstError.message)

    setMetrics({
      activeEmployees: empRes.count ?? 0,
      openRequisitions: reqRes.count ?? 0,
      pendingDocuments: docRes.count ?? 0,
      pendingLeave: leaveRes.count ?? 0,
      openShifts: shiftRes.count ?? 0,
      pendingSwaps: swapRes.count ?? 0,
      payrollRunsInProgress: payrollRes.count,
    })
    setLoading(false)
  }

  useEffect(() => {
    loadMetrics()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeEntityId, role])

  return (
    <div className="space-y-5">
      <div>
        <p className="text-xs font-semibold uppercase tracking-wider text-muted">Third State Café</p>
        <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Reports & audit</h1>
      </div>

      {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

      {loading || !metrics ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="h-20 animate-pulse rounded-[14px] bg-surface" />
          ))}
        </div>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <MetricCard label="Active employees" value={metrics.activeEmployees} />
          <MetricCard label="Open requisitions" value={metrics.openRequisitions} />
          <MetricCard label="Documents pending review" value={metrics.pendingDocuments} />
          <MetricCard label="Leave requests pending" value={metrics.pendingLeave} />
          <MetricCard label="Open shifts" value={metrics.openShifts} />
          <MetricCard label="Swaps awaiting approval" value={metrics.pendingSwaps} />
          {metrics.payrollRunsInProgress !== null && (
            <MetricCard label="Payroll runs in progress" value={metrics.payrollRunsInProgress} />
          )}
        </div>
      )}

      <AuditLogViewer role={role} activeEntityId={activeEntityId} entities={entities} />
    </div>
  )
}

function MetricCard({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-1 text-2xl font-medium text-ink">{value}</p>
    </div>
  )
}

const TABLE_FILTERS = [
  { value: '', label: 'All tables' },
  { value: 'employees', label: 'Employees' },
  { value: 'employee_documents', label: 'Documents' },
  { value: 'candidate_files', label: 'Candidate files' },
  { value: 'interviews', label: 'Interviews' },
  { value: 'interview_feedback', label: 'Interview feedback' },
  { value: 'interview_round_closures', label: 'Interview round closures' },
  { value: 'offers', label: 'Offers' },
  { value: 'shifts', label: 'Shifts' },
  { value: 'shift_swap_requests', label: 'Shift swaps' },
  { value: 'schedule_templates', label: 'Schedule templates' },
  { value: 'attendance_records', label: 'Attendance' },
  { value: 'timesheet_entries', label: 'Timesheets' },
  { value: 'leave_requests', label: 'Leave requests' },
  { value: 'leave_balances', label: 'Leave balances' },
  { value: 'leave_accrual_policies', label: 'Leave accrual policies' },
  { value: 'payroll_runs', label: 'Payroll runs' },
  { value: 'payslips', label: 'Payslips' },
  { value: 'payslip_deductions', label: 'Payslip deductions' },
  { value: 'tips_pools', label: 'Tips pools' },
  { value: 'app_settings', label: 'Settings (owner only)' },
]

// Coarser groupings over the same table_name values, resolved server-side by
// get_audit_log()/export_audit_log() (an unrecognized module name is
// rejected there, not silently ignored). Selecting a module resets the
// fine-grained table filter if it no longer belongs to that module, so the
// two controls can't be combined into a silently-empty, confusing result.
const MODULE_FILTERS: { value: string; label: string; tables: string[] }[] = [
  { value: '', label: 'All modules', tables: [] },
  { value: 'employees', label: 'Employees', tables: ['employees'] },
  { value: 'documents', label: 'Documents', tables: ['employee_documents', 'candidate_files'] },
  { value: 'recruiting', label: 'Recruiting', tables: ['interviews', 'interview_feedback', 'interview_round_closures', 'offers'] },
  {
    value: 'scheduling',
    label: 'Scheduling & attendance',
    tables: ['shifts', 'shift_swap_requests', 'schedule_templates', 'attendance_records', 'timesheet_entries'],
  },
  { value: 'leave', label: 'Leave', tables: ['leave_requests', 'leave_balances', 'leave_accrual_policies'] },
  { value: 'payroll', label: 'Payroll', tables: ['payroll_runs', 'payslips', 'payslip_deductions', 'tips_pools'] },
  { value: 'settings', label: 'Settings (owner only)', tables: ['app_settings'] },
]

const PAGE_SIZE = 50
const EXPORT_CAP = 5000

function toIsoStartOfDay(dateStr: string): string {
  return new Date(`${dateStr}T00:00:00`).toISOString()
}
function toIsoStartOfNextDay(dateStr: string): string {
  const d = new Date(`${dateStr}T00:00:00`)
  d.setDate(d.getDate() + 1)
  return d.toISOString()
}

function csvCell(value: unknown): string {
  if (value === null || value === undefined) return ''
  const s = typeof value === 'string' ? value : JSON.stringify(value)
  return `"${s.replace(/"/g, '""')}"`
}

function downloadCsv(filename: string, rows: AuditRow[]) {
  const headers = ['id', 'changed_at', 'table_name', 'action', 'changed_by', 'entity_id', 'location_id', 'employee_id', 'record_id', 'old_value', 'new_value']
  const lines = [
    headers.join(','),
    ...rows.map((r) =>
      [r.id, r.changed_at, r.table_name, r.action, r.changed_by, r.entity_id, r.location_id, r.employee_id, r.record_id, r.old_value, r.new_value]
        .map(csvCell)
        .join(',')
    ),
  ]
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

// Owner/entity_admin get the full filter set (including entity/branch
// narrowing and CSV export — export is a heavier, owner/entity_admin-only
// capability enforced server-side by export_audit_log()). location_manager
// now also renders this viewer (previously hard-blocked client-side even
// though get_audit_log() already had a working curated branch for them since
// Phase 1.2/1.4) but without the entity/branch pickers or export button,
// since they're already scoped to their own location and shouldn't get a
// bulk-extraction capability. Staff never reaches this screen at all (see
// the early return in Reports() above).
function AuditLogViewer({
  role,
  activeEntityId,
  entities,
}: {
  role: string | undefined
  activeEntityId: string | null
  entities: { id: string; name: string }[]
}) {
  const isOwner = role === 'owner'
  const canExport = role === 'owner' || role === 'entity_admin'
  const canNarrowEntityOrLocation = role === 'owner' || role === 'entity_admin'

  const [rows, setRows] = useState<AuditRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [hasMore, setHasMore] = useState(true)

  const [tableFilter, setTableFilter] = useState('')
  const [moduleFilter, setModuleFilter] = useState('')
  const [actionFilter, setActionFilter] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')
  const [actorId, setActorId] = useState('')
  const [employeeId, setEmployeeId] = useState('')
  const [entityFilter, setEntityFilter] = useState('')
  const [locationFilter, setLocationFilter] = useState('')

  const [employees, setEmployees] = useState<Pick<Employee, 'id' | 'full_name' | 'auth_user_id'>[]>([])
  const [locations, setLocations] = useState<Pick<Location, 'id' | 'name'>[]>([])
  const [exporting, setExporting] = useState(false)

  useEffect(() => {
    // location_manager doesn't get actor/employee/branch pickers — their view
    // is already curated and scoped to their own location server-side.
    if (role === 'staff' || role === 'location_manager') return
    const scopeEntityId = (isOwner && entityFilter) || activeEntityId
    if (!scopeEntityId) return
    supabase
      .from('employees')
      .select('id, full_name, auth_user_id')
      .eq('entity_id', scopeEntityId)
      .order('full_name')
      .then(({ data }) => setEmployees(data ?? []))
    supabase
      .from('locations')
      .select('id, name')
      .eq('entity_id', scopeEntityId)
      .order('name')
      .then(({ data }) => setLocations(data ?? []))
  }, [role, isOwner, activeEntityId, entityFilter])

  function currentFilters() {
    return {
      p_table_name: tableFilter || null,
      p_module: moduleFilter || null,
      p_action: actionFilter.trim() || null,
      p_after: dateFrom ? toIsoStartOfDay(dateFrom) : null,
      p_before_range: dateTo ? toIsoStartOfNextDay(dateTo) : null,
      p_actor_id: actorId || null,
      p_entity_id: canNarrowEntityOrLocation && entityFilter ? entityFilter : null,
      p_location_id: canNarrowEntityOrLocation && locationFilter ? locationFilter : null,
      p_employee_id: employeeId || null,
    }
  }

  async function load(cursor?: string, replace = true) {
    setLoading(true)
    setError(null)
    const f = currentFilters()
    // A date-range "to" and a pagination cursor both express "changed_at <
    // X" — when paging within a bounded range, the cursor (older than the
    // last row loaded) is always the tighter bound once any page has loaded.
    const before = cursor ?? f.p_before_range
    const { data, error: rpcError } = await supabase.rpc('get_audit_log', {
      p_limit: PAGE_SIZE,
      p_before: before,
      p_table_name: f.p_table_name,
      p_action: f.p_action,
      p_after: f.p_after,
      p_module: f.p_module,
      p_actor_id: f.p_actor_id,
      p_entity_id: f.p_entity_id,
      p_location_id: f.p_location_id,
      p_employee_id: f.p_employee_id,
    })
    setLoading(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const newRows = (data ?? []) as AuditRow[]
    setHasMore(newRows.length === PAGE_SIZE)
    setRows((prev) => (replace ? newRows : [...prev, ...newRows]))
  }

  useEffect(() => {
    load(undefined, true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tableFilter, moduleFilter, actionFilter, dateFrom, dateTo, actorId, employeeId, entityFilter, locationFilter])

  function handleLoadMore() {
    const last = rows[rows.length - 1]
    if (last) load(last.changed_at, false)
  }

  function handleModuleChange(value: string) {
    setModuleFilter(value)
    const mod = MODULE_FILTERS.find((m) => m.value === value)
    if (mod && mod.tables.length > 0 && tableFilter && !mod.tables.includes(tableFilter)) {
      setTableFilter('')
    }
  }

  // export_audit_log() re-enforces owner/entity_admin itself and applies the
  // exact same filters as the on-screen query — this button being hidden for
  // other roles is only a convenience, not the access control. The export
  // also writes its own audited 'audit_log_exported' event server-side.
  async function handleExport() {
    setExporting(true)
    setError(null)
    setNotice(null)
    const f = currentFilters()
    const { data, error: rpcError } = await supabase.rpc('export_audit_log', {
      p_after: f.p_after,
      p_before: f.p_before_range,
      p_table_name: f.p_table_name,
      p_module: f.p_module,
      p_action: f.p_action,
      p_actor_id: f.p_actor_id,
      p_entity_id: f.p_entity_id,
      p_location_id: f.p_location_id,
      p_employee_id: f.p_employee_id,
    })
    setExporting(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    const exportRows = (data ?? []) as AuditRow[]
    downloadCsv(`audit-log-${new Date().toISOString().slice(0, 10)}.csv`, exportRows)
    setNotice(
      exportRows.length === EXPORT_CAP
        ? `Exported the most recent ${EXPORT_CAP} matching rows — narrow the date range to get older ones.`
        : `Exported ${exportRows.length} row${exportRows.length === 1 ? '' : 's'}.`
    )
  }

  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-ink">Audit log</h2>
        {canExport && (
          <button
            onClick={handleExport}
            disabled={exporting}
            className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30 disabled:opacity-60"
          >
            {exporting ? 'Exporting…' : 'Export CSV'}
          </button>
        )}
      </div>

      <div className="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
        <select
          value={moduleFilter}
          onChange={(e) => handleModuleChange(e.target.value)}
          className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          {MODULE_FILTERS.map((f) => (
            <option key={f.value} value={f.value}>
              {f.label}
            </option>
          ))}
        </select>
        <select
          value={tableFilter}
          onChange={(e) => setTableFilter(e.target.value)}
          className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          {TABLE_FILTERS.filter((f) => {
            const mod = MODULE_FILTERS.find((m) => m.value === moduleFilter)
            return !mod || mod.tables.length === 0 || f.value === '' || mod.tables.includes(f.value)
          }).map((f) => (
            <option key={f.value} value={f.value}>
              {f.label}
            </option>
          ))}
        </select>
        <input
          value={actionFilter}
          onChange={(e) => setActionFilter(e.target.value)}
          placeholder="Action (exact, e.g. document_approved)"
          className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        />
        {role !== 'staff' && role !== 'location_manager' && (
          <select
            value={actorId}
            onChange={(e) => setActorId(e.target.value)}
            className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            <option value="">All actors</option>
            {employees
              .filter((e) => e.auth_user_id)
              .map((e) => (
                <option key={e.id} value={e.auth_user_id ?? ''}>
                  {e.full_name}
                </option>
              ))}
          </select>
        )}
        <input
          type="date"
          value={dateFrom}
          onChange={(e) => setDateFrom(e.target.value)}
          aria-label="From date"
          className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        />
        <input
          type="date"
          value={dateTo}
          onChange={(e) => setDateTo(e.target.value)}
          aria-label="To date"
          className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        />
        {role !== 'staff' && role !== 'location_manager' && (
          <select
            value={employeeId}
            onChange={(e) => setEmployeeId(e.target.value)}
            className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            <option value="">All employees</option>
            {employees.map((e) => (
              <option key={e.id} value={e.id}>
                {e.full_name}
              </option>
            ))}
          </select>
        )}
        {canNarrowEntityOrLocation && locations.length > 0 && (
          <select
            value={locationFilter}
            onChange={(e) => setLocationFilter(e.target.value)}
            className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            <option value="">All branches</option>
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name}
              </option>
            ))}
          </select>
        )}
        {isOwner && entities.length > 1 && (
          <select
            value={entityFilter}
            onChange={(e) => {
              setEntityFilter(e.target.value)
              setLocationFilter('')
            }}
            className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            <option value="">All entities</option>
            {entities.map((e) => (
              <option key={e.id} value={e.id}>
                {e.name}
              </option>
            ))}
          </select>
        )}
      </div>

      {error && <p className="mb-3 rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
      {notice && (
        <p className="mb-3 rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      {loading && rows.length === 0 ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-10 animate-pulse rounded-lg bg-surface-alt" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No audit events match these filters.</p>
      ) : (
        <>
          <ul className="space-y-1.5">
            {rows.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  <span className="font-medium">{r.table_name}</span> · {r.action ?? '—'}
                </span>
                <span className="flex items-center gap-2 text-muted">
                  <StatusBadge status={r.action ?? 'unknown'} tone="neutral" />
                  {new Date(r.changed_at).toLocaleString()}
                </span>
              </li>
            ))}
          </ul>
          {hasMore && (
            <button
              onClick={handleLoadMore}
              disabled={loading}
              className="mt-3 w-full rounded-lg border border-border py-2 text-xs font-medium text-brand-blue hover:border-brand-blue/30 disabled:opacity-60"
            >
              {loading ? 'Loading…' : 'Load more'}
            </button>
          )}
        </>
      )}
    </div>
  )
}
