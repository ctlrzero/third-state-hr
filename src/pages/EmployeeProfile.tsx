import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { expiryStatus } from '../lib/documents'
import type { Employee, EmployeeChangeRequest, EmployeeDocument, LeaveRequest } from '../types/db'

const EXPIRY_DOCS: { key: 'passport_exp' | 'visa_exp' | 'labor_card_exp' | 'health_card_exp'; label: string }[] = [
  { key: 'passport_exp', label: 'Passport' },
  { key: 'visa_exp', label: 'Visa' },
  { key: 'labor_card_exp', label: 'Labor card' },
  { key: 'health_card_exp', label: 'Health card' },
]

const EXPIRY_TONE: Record<string, 'neutral' | 'warning' | 'risk' | 'success'> = {
  expired: 'risk',
  expiring: 'warning',
  current: 'success',
  non_expiring: 'neutral',
}

const CHANGE_FIELD_LABEL: Record<string, string> = {
  phone: 'Phone number',
  email: 'Email address',
  emergency_contact_name: 'Emergency contact name',
  emergency_contact_phone: 'Emergency contact phone',
}

type FullEmployee = Employee & {
  dob: string | null
  gender: string | null
  nationality: string | null
  emergency_contact_name: string | null
  emergency_contact_phone: string | null
  probation_end_date: string | null
  notes: string | null
}

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

// Employee profile drill-in (/employees/:id) — the last remaining
// ComingSoon route. This screen only ever selects the same curated column
// set that the rest of the app already treats as "safe to show an
// owner/entity_admin/location_manager" — RLS (employees_select) is what
// actually restricts which employee_id values resolve at all for a given
// caller; a location_manager navigating to an out-of-location employee id
// gets an empty result here, not another location's data.
//
// Compensation (employee_compensation) and identity documents
// (employee_identity_documents) are NEVER fetched as part of the initial
// page load, even for owner/entity_admin. They're both owner/entity_admin
// -only per their own RLS (comp_access / identity_documents_access,
// unchanged by this pass), and additionally sit behind an explicit
// "Reveal" click here, per this app's existing rule that compensation/
// identity data should stay behind an explicit reveal action rather than
// loading passively into a profile view. location_manager never even sees
// the Reveal button, since the underlying RLS would just return nothing
// for that role anyway — the UI mirrors the boundary rather than inviting
// a click that's guaranteed to fail.
export default function EmployeeProfile() {
  const { id } = useParams<{ id: string }>()
  const { profile } = useAuth()
  const [employee, setEmployee] = useState<FullEmployee | null>(null)
  const [changeRequests, setChangeRequests] = useState<EmployeeChangeRequest[]>([])
  const [documents, setDocuments] = useState<EmployeeDocument[]>([])
  const [leaveRequests, setLeaveRequests] = useState<LeaveRequest[]>([])
  const [loading, setLoading] = useState(true)
  const [notFound, setNotFound] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busyRequestId, setBusyRequestId] = useState<string | null>(null)

  async function load() {
    if (!id) return
    setLoading(true)
    setError(null)
    setNotFound(false)

    const empRes = await supabase
      .from('employees')
      .select(
        'id, entity_id, home_location_id, position_id, full_name, preferred_name, photo_url, dob, gender, nationality, phone, email, emergency_contact_name, emergency_contact_phone, passport_exp, visa_exp, labor_card_exp, health_card_exp, employment_type, employment_status, join_date, probation_end_date, notes, created_at, updated_at, locations(id, name), positions(id, title, department)'
      )
      .eq('id', id)
      .maybeSingle()

    if (empRes.error) {
      setError(empRes.error.message)
      setLoading(false)
      return
    }
    if (!empRes.data) {
      // RLS scoped this to nothing — either the id doesn't exist, or it
      // exists in an entity/location this caller can't see. Same message
      // either way, so the screen never confirms or denies which case it is.
      setNotFound(true)
      setLoading(false)
      return
    }
    setEmployee(empRes.data as unknown as FullEmployee)

    const [crRes, docRes, leaveRes] = await Promise.all([
      supabase.from('employee_change_requests').select('*').eq('employee_id', id).order('requested_at', { ascending: false }),
      supabase.from('employee_documents').select('*').eq('employee_id', id).eq('is_current', true).order('doc_type'),
      supabase.from('leave_requests').select('*, leave_types(id, name)').eq('employee_id', id).order('requested_at', { ascending: false }).limit(10),
    ])
    setChangeRequests((crRes.data ?? []) as EmployeeChangeRequest[])
    setDocuments((docRes.data ?? []) as unknown as EmployeeDocument[])
    setLeaveRequests((leaveRes.data ?? []) as unknown as LeaveRequest[])
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id])

  async function handleDecide(requestId: string, action: 'approve' | 'reject') {
    setBusyRequestId(requestId)
    setError(null)
    // decide_employee_change_request() re-checks the caller's own
    // authority (entity/location match) and that the request is still
    // pending before applying anything — this button can't be used to
    // replay a decision on a request that's already been decided.
    const { error: rpcError } = await supabase.rpc('decide_employee_change_request', {
      p_request_id: requestId,
      p_action: action,
      p_decision_reason: null,
    })
    setBusyRequestId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setNotice(action === 'approve' ? 'Change applied.' : 'Change request rejected.')
    load()
  }

  if (loading) {
    return (
      <div className="space-y-3">
        <div className="h-20 animate-pulse rounded-[14px] bg-surface" />
        <div className="h-40 animate-pulse rounded-[14px] bg-surface" />
      </div>
    )
  }

  if (notFound || !employee) {
    return (
      <div className="space-y-5">
        <Link to="/employees" className="text-sm text-brand-blue hover:underline">
          ← Back to directory
        </Link>
        <EmptyState title="Employee not found" description="This record doesn't exist, or you don't have access to it." />
      </div>
    )
  }

  const canReveal = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const pendingChangeRequests = changeRequests.filter((r) => r.status === 'pending')
  const decidedChangeRequests = changeRequests.filter((r) => r.status !== 'pending').slice(0, 10)

  return (
    <div className="space-y-5">
      <Link to="/employees" className="text-sm text-brand-blue hover:underline">
        ← Back to directory
      </Link>

      {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
      {notice && (
        <p className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-lg font-medium text-ink">{employee.preferred_name || employee.full_name}</p>
            <p className="text-sm text-muted">
              {employee.positions?.title ?? 'No role set'} · {employee.locations?.name ?? 'No branch set'}
            </p>
          </div>
          <StatusBadge status={employee.employment_status ?? 'candidate'} />
        </div>
        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-4">
          <Field label="Employment type" value={employee.employment_type?.replace('_', ' ') ?? '—'} className="capitalize" />
          <Field label="Joined" value={employee.join_date ?? '—'} />
          <Field label="Probation ends" value={employee.probation_end_date ?? '—'} />
          <Field label="Nationality" value={employee.nationality ?? '—'} />
          <Field label="Phone" value={employee.phone ?? '—'} />
          <Field label="Email" value={employee.email ?? '—'} />
          <Field label="Emergency contact" value={employee.emergency_contact_name ?? '—'} />
          <Field label="Emergency phone" value={employee.emergency_contact_phone ?? '—'} />
        </dl>
      </div>

      {pendingChangeRequests.length > 0 && (
        <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Pending change requests</h2>
          <ul className="space-y-2">
            {pendingChangeRequests.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                <span className="text-ink">
                  {CHANGE_FIELD_LABEL[r.field_name] ?? r.field_name}: <span className="font-medium">“{r.new_value}”</span>
                  {r.old_value && <span className="text-xs text-muted"> (was “{r.old_value}”)</span>}
                </span>
                <span className="flex gap-1">
                  <button
                    onClick={() => handleDecide(r.id, 'approve')}
                    disabled={busyRequestId === r.id}
                    className="rounded-full bg-brand-action-soft px-2.5 py-1 text-xs font-medium text-brand-action-text disabled:opacity-60"
                  >
                    {busyRequestId === r.id ? 'Working…' : 'Approve'}
                  </button>
                  <button
                    onClick={() => handleDecide(r.id, 'reject')}
                    disabled={busyRequestId === r.id}
                    className="rounded-full bg-brand-risk-soft px-2.5 py-1 text-xs font-medium text-brand-risk-text disabled:opacity-60"
                  >
                    Reject
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Document expiry</h2>
        <ul className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {EXPIRY_DOCS.map((d) => {
            const status = expiryStatus(employee[d.key])
            return (
              <li key={d.key} className="rounded-lg bg-surface-alt p-3">
                <p className="text-xs text-muted">{d.label}</p>
                <p className="mt-1 text-sm text-ink">{employee[d.key] ?? 'Not on file'}</p>
                <div className="mt-1.5">
                  <StatusBadge status={status} tone={EXPIRY_TONE[status]} />
                </div>
              </li>
            )
          })}
        </ul>
        <p className="mt-3 text-xs text-muted">
          Uploads, renewals, and reviews happen in <Link to="/documents" className="text-brand-blue hover:underline">Documents</Link>.
        </p>
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Current documents on file</h2>
        {documents.length === 0 ? (
          <p className="text-sm text-muted">No approved documents on file yet.</p>
        ) : (
          <ul className="space-y-1.5">
            {documents.map((d) => (
              <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink capitalize">{d.doc_type.replace(/_/g, ' ')}</span>
                <StatusBadge status={d.review_status} />
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Recent leave requests</h2>
        {leaveRequests.length === 0 ? (
          <p className="text-sm text-muted">No leave requests yet.</p>
        ) : (
          <ul className="space-y-1.5">
            {leaveRequests.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  {r.leave_types?.name ?? 'Leave'} · {r.start_date} – {r.end_date}
                </span>
                <StatusBadge status={r.status} />
              </li>
            ))}
          </ul>
        )}
        <p className="mt-3 text-xs text-muted">
          Decisions happen in <Link to="/leave" className="text-brand-blue hover:underline">Leave</Link>.
        </p>
      </div>

      {decidedChangeRequests.length > 0 && (
        <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
          <h2 className="mb-3 text-sm font-semibold text-ink">Change request history</h2>
          <ul className="space-y-1.5">
            {decidedChangeRequests.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  {CHANGE_FIELD_LABEL[r.field_name] ?? r.field_name}: “{r.new_value}”
                </span>
                <StatusBadge status={r.status} />
              </li>
            ))}
          </ul>
        </div>
      )}

      {canReveal && <SensitiveInfoPanel employeeId={employee.id} />}
    </div>
  )
}

function Field({ label, value, className }: { label: string; value: string; className?: string }) {
  return (
    <div>
      <dt className="text-xs text-muted">{label}</dt>
      <dd className={`text-ink ${className ?? ''}`}>{value}</dd>
    </div>
  )
}

// Compensation and identity documents are fetched only after an explicit
// click, never as part of the page load — even though canReveal already
// guarantees this only renders for owner/entity_admin, whose RLS would let
// them fetch it either way. The extra click is a deliberate speed bump
// against casually loading salary/bank/passport numbers while browsing
// the directory, consistent with how this app treats that data everywhere
// else (Documents, My Profile).
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
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-ink">Compensation & identity documents</h2>
        {!revealed && (
          <button
            onClick={handleReveal}
            disabled={loading}
            className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30 disabled:opacity-60"
          >
            {loading ? 'Loading…' : 'Reveal'}
          </button>
        )}
      </div>
      {error && <p className="mt-2 rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}
      {!revealed && !error && (
        <p className="mt-1 text-xs text-muted">Salary, bank details, and identity document numbers are hidden by default.</p>
      )}
      {revealed && (
        <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-4">
          <Field label="Pay type" value={compensation?.pay_type?.replace('_', ' ') ?? '—'} className="capitalize" />
          <Field label="Pay rate" value={compensation?.pay_rate != null ? String(compensation.pay_rate) : '—'} />
          <Field label="Overtime multiplier" value={compensation?.overtime_multiplier != null ? String(compensation.overtime_multiplier) : '—'} />
          <Field label="Holiday multiplier" value={compensation?.holiday_multiplier != null ? String(compensation.holiday_multiplier) : '—'} />
          <Field label="Passport no." value={identity?.passport_no ?? '—'} />
          <Field label="National ID no." value={identity?.national_id_no ?? '—'} />
          <Field label="Visa no." value={identity?.visa_no ?? '—'} />
          <Field label="Labor card no." value={identity?.labor_card_no ?? '—'} />
          <Field label="Health card no." value={identity?.health_card_no ?? '—'} />
          <Field label="Bank name" value={identity?.bank_name ?? '—'} />
          <Field label="Bank IBAN" value={identity?.bank_iban ?? '—'} />
        </dl>
      )}
    </div>
  )
}
