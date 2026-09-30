import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Alert, Field, Modal } from './ui'
import { StatusBadge } from './StatusBadge'
import { DOC_TYPES, canRoleSeeDocType } from '../lib/documents'
import { fmtDate, todayDubai } from '../lib/format'
import {
  PROFILE_REQUEST_FIELDS,
  cancelEmployeeRequest,
  createEmployeeRequest,
  getEmployeeRequests,
  type EmployeeRequestKind,
  type EmployeeRequestRow,
  type ProfileRequestField,
} from '../lib/api/employeeRequests'
import type { UserRole } from '../types/db'

// Admin side of "Ask an employee for something": the open requests card on an
// employee's profile plus the "Ask for something" form. The server decides who
// may send (owner, Company Admin, Branch Manager for their own branch) — this
// component only hides the button for everyone else.

export const CAN_SEND_REQUESTS: readonly UserRole[] = ['owner', 'entity_admin', 'location_manager']

interface KnownProfile {
  phone?: string | null
  emergency_contact_name?: string | null
  emergency_contact_phone?: string | null
  dob?: string | null
  nationality?: string | null
}

function isFilled(p: KnownProfile | undefined, f: ProfileRequestField): boolean {
  if (!p) return false
  const has = (v: string | null | undefined) => Boolean(v && v.trim())
  if (f === 'phone') return has(p.phone)
  if (f === 'emergency_contact') return has(p.emergency_contact_name) && has(p.emergency_contact_phone)
  if (f === 'dob') return has(p.dob)
  if (f === 'nationality') return has(p.nationality)
  return false // home address isn't loaded on the profile; the server checks it
}

export function EmployeeRequestsCard({
  employeeId,
  employeeName,
  role,
  known,
  refreshKey = 0,
}: {
  employeeId: string
  employeeName: string
  role: UserRole | undefined
  known?: KnownProfile
  refreshKey?: number
}) {
  const [rows, setRows] = useState<EmployeeRequestRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [asking, setAsking] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [showClosed, setShowClosed] = useState(false)
  const canSend = role ? CAN_SEND_REQUESTS.includes(role) : false

  const load = useCallback(async () => {
    if (!canSend) return
    const res = await getEmployeeRequests(employeeId, showClosed)
    if (res.error) setError(res.error)
    else setRows(res.data ?? [])
  }, [employeeId, showClosed, canSend])

  useEffect(() => {
    load()
  }, [load, refreshKey])

  if (!canSend) return null

  async function cancel(r: EmployeeRequestRow) {
    setBusyId(r.id)
    setError(null)
    const res = await cancelEmployeeRequest(r.id)
    setBusyId(null)
    if (res.error) setError(res.error)
    else {
      setNotice('Request cancelled.')
      load()
    }
  }

  const open = (rows ?? []).filter((r) => r.status === 'open')
  const closed = (rows ?? []).filter((r) => r.status !== 'open')

  return (
    <section className="card space-y-3" aria-labelledby="emp-req-h">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 id="emp-req-h" className="text-sm font-semibold text-ink">
          Requests to {employeeName}
        </h2>
        <button type="button" className="btn-primary min-h-11" onClick={() => setAsking(true)}>
          Ask for something
        </button>
      </div>
      {error && <Alert tone="error" onDismiss={() => setError(null)}>{error}</Alert>}
      {notice && <Alert tone="success" onDismiss={() => setNotice(null)}>{notice}</Alert>}

      {rows === null ? (
        <div className="h-10 animate-pulse rounded bg-surface-alt" />
      ) : open.length === 0 ? (
        <p className="text-sm text-muted">Nothing asked right now. Use “Ask for something” to request a document, bank details or missing information.</p>
      ) : (
        <ul className="divide-y divide-border">
          {open.map((r) => (
            <li key={r.id} className="flex flex-wrap items-start justify-between gap-2 py-2.5">
              <div className="min-w-0">
                <p className="font-medium text-ink">{r.label}</p>
                <p className="text-xs text-muted">
                  Asked {fmtDate(r.created_at)}
                  {r.requested_by_name ? ` by ${r.requested_by_name}` : ''}
                  {r.due_date ? ` · due ${fmtDate(r.due_date)}` : ''}
                </p>
                {r.note && <p className="mt-1 text-xs text-ink">“{r.note}”</p>}
              </div>
              <div className="flex items-center gap-2">
                <StatusBadge status={r.is_overdue ? 'Overdue' : 'Waiting'} tone={r.is_overdue ? 'risk' : 'warning'} />
                {r.can_cancel && (
                  <button type="button" className="btn-secondary min-h-11" disabled={busyId === r.id} onClick={() => cancel(r)}>
                    {busyId === r.id ? 'Cancelling…' : 'Cancel'}
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}

      <button type="button" className="min-h-11 text-sm font-medium text-brand-blue hover:underline" onClick={() => setShowClosed((v) => !v)}>
        {showClosed ? 'Hide finished requests' : 'Show finished requests'}
      </button>
      {showClosed && closed.length > 0 && (
        <ul className="divide-y divide-border">
          {closed.map((r) => (
            <li key={r.id} className="flex items-center justify-between gap-2 py-2 text-sm">
              <span className="min-w-0 text-ink">{r.label}</span>
              <span className="flex items-center gap-2 text-xs text-muted">
                {r.closed_at ? fmtDate(r.closed_at) : ''}
                <StatusBadge status={r.status === 'done' ? 'Done' : 'Cancelled'} tone={r.status === 'done' ? 'success' : 'neutral'} />
              </span>
            </li>
          ))}
        </ul>
      )}
      {showClosed && closed.length === 0 && rows !== null && <p className="text-sm text-muted">No finished requests yet.</p>}

      {asking && (
        <AskForSomethingModal
          employeeId={employeeId}
          employeeName={employeeName}
          role={role}
          known={known}
          onClose={() => setAsking(false)}
          onSent={() => {
            setAsking(false)
            setNotice(`Sent. ${employeeName} will see it on their Home screen.`)
            load()
          }}
        />
      )}
    </section>
  )
}

const KIND_OPTIONS: { value: EmployeeRequestKind; label: string; hint: string }[] = [
  { value: 'document', label: 'Upload a document', hint: 'For example a new visa or health card' },
  { value: 'payment_details', label: 'Bank / payment details', hint: 'Add or update how they get paid' },
  { value: 'profile_info', label: 'Missing information', hint: 'Phone, emergency contact, date of birth…' },
]

export function AskForSomethingModal({
  employeeId,
  employeeName,
  role,
  known,
  onClose,
  onSent,
}: {
  employeeId: string
  employeeName: string
  role: UserRole | undefined
  known?: KnownProfile
  onClose: () => void
  onSent: () => void
}) {
  const docTypes = DOC_TYPES.filter((t) => canRoleSeeDocType(role, t.value))
  const [kind, setKind] = useState<EmployeeRequestKind>('document')
  const [docType, setDocType] = useState<string>(docTypes[0]?.value ?? 'other')
  const [fields, setFields] = useState<ProfileRequestField[]>(() =>
    PROFILE_REQUEST_FIELDS.map((f) => f.key).filter((k) => !isFilled(known, k))
  )
  const [note, setNote] = useState('')
  const [dueDate, setDueDate] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  function toggleField(k: ProfileRequestField) {
    setFields((cur) => (cur.includes(k) ? cur.filter((x) => x !== k) : [...cur, k]))
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    if (kind === 'profile_info' && fields.length === 0) {
      setError('Choose at least one detail to ask for.')
      return
    }
    setBusy(true)
    const res = await createEmployeeRequest({ employeeId, kind, docType, fields, note, dueDate: dueDate || null })
    setBusy(false)
    if (res.error) setError(res.error)
    else onSent()
  }

  return (
    <Modal open title={`Ask ${employeeName} for something`} onClose={onClose}>
      <form onSubmit={submit} className="space-y-4">
        <fieldset>
          <legend className="label">What do you need?</legend>
          <div className="space-y-2">
            {KIND_OPTIONS.map((o) => (
              <label
                key={o.value}
                className={`flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border p-3 ${kind === o.value ? 'border-brand-blue bg-brand-blue-soft' : 'border-border'}`}
              >
                <input type="radio" name="req-kind" className="mt-1" checked={kind === o.value} onChange={() => setKind(o.value)} />
                <span>
                  <span className="block font-medium text-ink">{o.label}</span>
                  <span className="block text-xs text-muted">{o.hint}</span>
                </span>
              </label>
            ))}
          </div>
        </fieldset>

        {kind === 'document' && (
          <Field label="Which document?" required hint={role === 'location_manager' ? 'Passport, visa, Emirates ID and contracts can only be asked for by a Company Admin.' : undefined}>
            {(p) => (
              <select {...p} className="input min-h-11" value={docType} onChange={(e) => setDocType(e.target.value)}>
                {docTypes.map((t) => (
                  <option key={t.value} value={t.value}>
                    {t.label}
                  </option>
                ))}
              </select>
            )}
          </Field>
        )}

        {kind === 'profile_info' && (
          <fieldset>
            <legend className="label">Which details are missing?</legend>
            <div className="space-y-1">
              {PROFILE_REQUEST_FIELDS.map((f) => {
                const filled = isFilled(known, f.key)
                return (
                  <label key={f.key} className={`flex min-h-11 items-center gap-3 ${filled ? 'text-muted' : 'text-ink'}`}>
                    <input type="checkbox" disabled={filled} checked={!filled && fields.includes(f.key)} onChange={() => toggleField(f.key)} />
                    <span>
                      {f.label}
                      {filled && <span className="ml-1 text-xs">(already filled in)</span>}
                    </span>
                  </label>
                )
              })}
            </div>
          </fieldset>
        )}

        {kind === 'payment_details' && (
          <p className="rounded-lg bg-surface-alt p-3 text-xs text-muted">
            They will enter their bank details in the app. Payroll must check the new details before the next pay day.
          </p>
        )}

        <Field label="Note (optional)" hint="A short message they will see with the request.">
          {(p) => (
            <textarea {...p} className="input" rows={2} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
          )}
        </Field>
        <Field label="Please do it by (optional)" hint="We remind them every day after this date.">
          {(p) => (
            <input {...p} type="date" className="input min-h-11" min={todayDubai()} value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
          )}
        </Field>

        {error && <Alert tone="error">{error}</Alert>}

        <div className="flex flex-wrap justify-end gap-2">
          <button type="button" className="btn-secondary min-h-11" onClick={onClose}>
            Close
          </button>
          <button type="submit" className="btn-primary min-h-11" disabled={busy}>
            {busy ? 'Sending…' : 'Send request'}
          </button>
        </div>
      </form>
    </Modal>
  )
}
