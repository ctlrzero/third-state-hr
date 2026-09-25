import { useEffect, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { fmtDayShort, fmtTime } from '../lib/format'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import { expiryStatus } from '../lib/documents'
import type { EmployeeChangeRequest, Location, Position, Shift } from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'

// UAE-readable dates / 24h times (Asia/Dubai) shared across the app.
const fmtDate = (d: string) => fmtDayShort(d)

type SelfEmployee = {
  id: string
  full_name: string
  preferred_name: string | null
  photo_url: string | null
  email: string | null
  phone: string | null
  emergency_contact_name: string | null
  emergency_contact_phone: string | null
  employment_type: string | null
  employment_status: string | null
  join_date: string | null
  probation_end_date: string | null
  passport_exp: string | null
  visa_exp: string | null
  labor_card_exp: string | null
  health_card_exp: string | null
  locations?: Pick<Location, 'id' | 'name'> | null
  positions?: Pick<Position, 'id' | 'title' | 'department'> | null
}

// Requestable fields mirror exactly what decide_employee_change_request() is
// able to apply on approval — phone, email, and the two emergency-contact
// fields. Everything else on the employee record (DOB, nationality,
// employment type/status, dates) is admin-managed only; there is
// deliberately no self-service edit path for those here.
const REQUESTABLE_FIELDS: { key: 'phone' | 'email' | 'emergency_contact_name' | 'emergency_contact_phone'; label: string }[] = [
  { key: 'phone', label: 'Phone number' },
  { key: 'email', label: 'Email address' },
  { key: 'emergency_contact_name', label: 'Emergency contact name' },
  { key: 'emergency_contact_phone', label: 'Emergency contact phone' },
]

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

// UX employee self-service profile. This screen only ever selects columns
// the employee is already allowed to see about themselves (employees_select
// grants auth_user_id = auth.uid()) and never fetches employee_compensation
// or employee_identity_documents — pay rate, bank details, and identity
// document numbers stay owner/entity_admin-only regardless of this screen.
export default function MyProfile() {
  const { session } = useAuth()
  const [employee, setEmployee] = useState<SelfEmployee | null>(null)
  const [requests, setRequests] = useState<EmployeeChangeRequest[]>([])
  const [scheduleHistory, setScheduleHistory] = useState<Shift[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [requestingField, setRequestingField] = useState<string | null>(null)

  async function load() {
    if (!session?.user?.id) return
    setLoading(true)
    setError(null)
    const { data: empRow, error: empError } = await supabase
      .from('employees')
      .select(
        'id, full_name, preferred_name, photo_url, email, phone, emergency_contact_name, emergency_contact_phone, employment_type, employment_status, join_date, probation_end_date, passport_exp, visa_exp, labor_card_exp, health_card_exp, locations(id, name), positions(id, title, department)'
      )
      .eq('auth_user_id', session.user.id)
      .maybeSingle()

    if (empError) {
      setError(empError.message)
      setLoading(false)
      return
    }
    setEmployee((empRow ?? null) as unknown as SelfEmployee | null)

    if (empRow) {
      const { data: reqRows } = await supabase
        .from('employee_change_requests')
        .select('*')
        .eq('employee_id', (empRow as { id: string }).id)
        .order('requested_at', { ascending: false })
      setRequests((reqRows ?? []) as EmployeeChangeRequest[])

      // Phase 3.14: compact schedule history, right here rather than only a
      // link out to My Schedule (which only ever shows upcoming shifts).
      // IMPORTANT: this page is reachable by every role, not just staff — and
      // owner/entity_admin/location_manager also match the broader
      // shifts_access policy (their whole entity/location's shifts), which
      // Postgres OR's together with shifts_select_self (own shifts only).
      // Unlike My Schedule (staff-only, so shifts_select_self is the only
      // policy ever in play there), the explicit .eq('employee_id', ...)
      // filter below is doing real work here, not just presentation — without
      // it, an admin/manager who is also an assigned employee somewhere would
      // see their entire team's shift history on their own profile page
      // instead of just their own.
      const today = new Date().toISOString().slice(0, 10)
      const { data: historyRows } = await supabase
        .from('shifts')
        .select('*, locations(id, name), positions(id, title)')
        .eq('employee_id', (empRow as { id: string }).id)
        .lt('shift_date', today)
        .order('shift_date', { ascending: false })
        .limit(10)
      setScheduleHistory((historyRows ?? []) as unknown as Shift[])
    }
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.user?.id])

  const pendingByField = new Set(requests.filter((r) => r.status === 'pending').map((r) => r.field_name))

  if (loading) {
    return (
      <div className="space-y-3">
        <div className="h-20 animate-pulse rounded-[14px] bg-surface" />
        <div className="h-40 animate-pulse rounded-[14px] bg-surface" />
      </div>
    )
  }

  if (!employee) {
    return (
      <div className="space-y-5">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">My profile</h1>
        </div>
        <EmptyState
          title="No employee record linked to your account yet"
          description="Ask an owner or admin to link your login to your employee record."
        />
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div>
        <EntityEyebrow />
        <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">My profile</h1>
      </div>

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
        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-3">
          <div>
            <dt className="text-xs text-muted">Employment type</dt>
            <dd className="capitalize text-ink">{employee.employment_type?.replace('_', ' ') ?? '—'}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted">Joined</dt>
            <dd className="text-ink">{employee.join_date ?? '—'}</dd>
          </div>
          {employee.probation_end_date && (
            <div>
              <dt className="text-xs text-muted">Probation ends</dt>
              <dd className="text-ink">{employee.probation_end_date}</dd>
            </div>
          )}
        </dl>
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Contact details</h2>
        <ul className="space-y-3">
          {REQUESTABLE_FIELDS.map((f) => (
            <li key={f.key} className="flex flex-wrap items-center justify-between gap-2 border-b border-border pb-3 last:border-0 last:pb-0">
              <div>
                <p className="text-xs text-muted">{f.label}</p>
                <p className="text-sm text-ink">{employee[f.key] || '—'}</p>
              </div>
              {pendingByField.has(f.key) ? (
                <StatusBadge status="pending" />
              ) : (
                <button
                  onClick={() => setRequestingField(f.key)}
                  className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                >
                  Request change
                </button>
              )}
            </li>
          ))}
        </ul>
        <p className="mt-3 text-xs text-muted">
          These fields need owner/admin/manager approval before they update — see your request history below. Everything
          else on your record (role, employment type, dates) is managed by HR.
        </p>
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Document expiry</h2>
        <p className="mb-3 text-xs text-muted">
          Uploading or renewing these documents happens in <a href="/documents" className="text-brand-blue hover:underline">Documents</a>.
        </p>
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
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-sm font-semibold text-ink">Schedule history</h2>
          <a href="/schedules" className="text-xs font-medium text-brand-blue hover:underline">
            Open Schedules →
          </a>
        </div>
        {scheduleHistory.length === 0 ? (
          <p className="text-sm text-muted">No past shifts on file yet.</p>
        ) : (
          <ul className="space-y-2">
            {scheduleHistory.map((s) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">
                  {fmtDate(s.shift_date)} · {fmtTime(s.start_time)}–{fmtTime(s.end_time)} · {s.locations?.name ?? '—'}
                  {s.positions?.title ? ` · ${s.positions.title}` : ''}
                </span>
                <StatusBadge status={s.status} tone={s.status === 'cancelled' ? 'neutral' : 'success'} />
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <h2 className="mb-3 text-sm font-semibold text-ink">Change request history</h2>
        {requests.length === 0 ? (
          <p className="text-sm text-muted">No change requests yet.</p>
        ) : (
          <ul className="space-y-2">
            {requests.map((r) => (
              <li key={r.id} className="rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-medium text-ink">
                    {REQUESTABLE_FIELDS.find((f) => f.key === r.field_name)?.label ?? r.field_name}: “{r.new_value}”
                  </span>
                  <StatusBadge status={r.status} />
                </div>
                <p className="mt-1 text-muted">Requested {fmtDate(r.requested_at)}</p>
                {r.status !== 'pending' && r.decision_reason && (
                  <p className="mt-1 text-muted">Note: {r.decision_reason}</p>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      {requestingField && employee && (
        <RequestChangeModal
          employeeId={employee.id}
          fieldKey={requestingField as (typeof REQUESTABLE_FIELDS)[number]['key']}
          currentValue={employee[requestingField as keyof SelfEmployee] as string | null}
          onClose={() => setRequestingField(null)}
          onSubmitted={() => {
            setRequestingField(null)
            setNotice('Change request submitted — an owner, admin, or manager needs to approve it.')
            load()
          }}
        />
      )}
    </div>
  )
}

function RequestChangeModal({
  employeeId,
  fieldKey,
  currentValue,
  onClose,
  onSubmitted,
}: {
  employeeId: string
  fieldKey: (typeof REQUESTABLE_FIELDS)[number]['key']
  currentValue: string | null
  onClose: () => void
  onSubmitted: () => void
}) {
  const [newValue, setNewValue] = useState('')
  const [reason, setReason] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const label = REQUESTABLE_FIELDS.find((f) => f.key === fieldKey)?.label ?? fieldKey

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!newValue.trim()) {
      setError('Enter the new value.')
      return
    }
    setSubmitting(true)
    setError(null)
    // employee_change_requests RLS (change_requests_insert) only allows a
    // self-submitted row when employee_id = my_employee_id() and it's
    // created as status = 'pending' with no decision already attached —
    // an employee can propose a value but can never approve their own
    // change or backdate a decision.
    const { error: insertError } = await supabase.from('employee_change_requests').insert({
      employee_id: employeeId,
      field_name: fieldKey,
      old_value: currentValue,
      new_value: newValue.trim(),
      reason: reason.trim() || null,
      status: 'pending',
    })
    setSubmitting(false)
    if (insertError) {
      setError(insertError.message)
      return
    }
    onSubmitted()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-1 text-base font-semibold text-ink">Request a change</h2>
        <p className="mb-4 text-xs text-muted">{label}</p>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="myprofile-current-value-1" className="mb-1 block text-sm font-medium text-ink">Current value</label>
            <input id="myprofile-current-value-1"
              value={currentValue ?? ''}
              disabled
              className="w-full rounded-lg border border-border bg-surface-alt px-3 py-2 text-sm text-muted"
            />
          </div>
          <div>
            <label htmlFor="myprofile-new-value-2" className="mb-1 block text-sm font-medium text-ink">New value</label>
            <input id="myprofile-new-value-2"
              value={newValue}
              onChange={(e) => setNewValue(e.target.value)}
              autoFocus
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <div>
            <label htmlFor="myprofile-reason-optional-3" className="mb-1 block text-sm font-medium text-ink">Reason (optional)</label>
            <textarea id="myprofile-reason-optional-3"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={2}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>

          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Submitting…' : 'Submit request'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
