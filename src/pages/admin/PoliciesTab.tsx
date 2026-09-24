import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { StatusBadge } from '../../components/StatusBadge'
import { AccrualPolicyPanel } from '../../components/AccrualPolicyPanel'
import { Alert, Drawer, Field, Skeleton } from '../../components/ui'
import {
  approveDataRetentionPolicy,
  getEntityAdminSelfApproval,
  listRetentionPolicies,
  proposeDataRetentionPolicy,
  setEntityAdminSelfApproval,
  type RetentionPolicy,
} from '../../lib/api/admin'
import { fmtDate, humanize } from '../../lib/format'
import type { LeaveType } from '../../types/db'

const RETENTION_TABLES: { value: string; label: string }[] = [
  { value: 'employees', label: 'Employee records' },
  { value: 'employee_documents', label: 'Employee documents' },
  { value: 'attendance_records', label: 'Attendance records' },
  { value: 'leave_requests', label: 'Leave requests' },
  { value: 'payroll_runs', label: 'Payroll runs' },
  { value: 'payslips', label: 'Payslips' },
  { value: 'candidates', label: 'Recruiting candidates' },
  { value: 'audit_log', label: 'Audit log' },
]

const DISPOSAL: { value: string; label: string }[] = [
  { value: 'manual_review', label: 'Manual review before disposal' },
  { value: 'soft_delete', label: 'Archive (soft delete)' },
  { value: 'hard_delete', label: 'Permanently delete' },
]

export function PoliciesTab({ isOwner, activeEntityId }: { isOwner: boolean; activeEntityId: string | null }) {
  const [leaveTypes, setLeaveTypes] = useState<LeaveType[]>([])
  useEffect(() => {
    let q = supabase.from('leave_types').select('*').order('name')
    if (activeEntityId) q = q.eq('entity_id', activeEntityId)
    q.then(({ data }) => setLeaveTypes((data ?? []) as LeaveType[]))
  }, [activeEntityId])

  return (
    <div className="space-y-5">
      <section aria-labelledby="leave-policy-h" className="space-y-2">
        <h3 id="leave-policy-h" className="text-base font-semibold text-ink">
          Leave
        </h3>
        {leaveTypes.length > 0 && (
          <div className="card">
            <p className="mb-2 text-sm font-semibold text-ink">Leave types</p>
            <ul className="grid gap-2 sm:grid-cols-2">
              {leaveTypes.map((t) => (
                <li key={t.id} className="flex items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
                  <span>
                    {t.name} · {t.accrual_days_per_year} days/year
                  </span>
                  <StatusBadge status="Configurable — pending HR/legal approval" tone="warning" />
                </li>
              ))}
            </ul>
          </div>
        )}
        <AccrualPolicyPanel leaveTypes={leaveTypes} isOwner={isOwner} entityId={activeEntityId} />
      </section>
      <RetentionSection isOwner={isOwner} entityId={activeEntityId} />
      <SelfApprovalSection isOwner={isOwner} />
    </div>
  )
}

function RetentionSection({ isOwner, entityId }: { isOwner: boolean; entityId: string | null }) {
  const [rows, setRows] = useState<RetentionPolicy[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [proposing, setProposing] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)

  const load = useCallback(async () => {
    setRows(null)
    const res = await listRetentionPolicies(entityId)
    if (res.error) setError(res.error)
    setRows(res.data ?? [])
  }, [entityId])
  useEffect(() => {
    load()
  }, [load])

  async function approve(id: string) {
    setBusyId(id)
    const res = await approveDataRetentionPolicy(id)
    setBusyId(null)
    if (res.error || res.notAvailable) return setError(res.error ?? 'Not available yet.')
    setNotice('Retention policy approved.')
    load()
  }

  return (
    <section aria-labelledby="retention-h" className="card space-y-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h3 id="retention-h" className="text-base font-semibold text-ink">
            Data retention
          </h3>
          <p className="text-sm text-muted">How long each kind of record is kept. Proposals need Owner approval; nothing is deleted automatically.</p>
        </div>
        <button className="btn-secondary" onClick={() => setProposing(true)}>
          Propose policy
        </button>
      </div>
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
      {rows === null ? (
        <Skeleton rows={2} />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No retention policies yet.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((r) => (
            <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2 text-sm">
              <span>
                <span className="font-medium">{RETENTION_TABLES.find((t) => t.value === r.table_name)?.label ?? humanize(r.table_name)}</span> ·{' '}
                {r.retention_years} years · {DISPOSAL.find((d) => d.value === r.disposal_method)?.label ?? r.disposal_method}
                {r.legal_basis && <span className="block text-xs text-muted">Basis: {r.legal_basis}</span>}
                <span className="block text-xs text-muted">Proposed {fmtDate(r.created_at)}</span>
              </span>
              <span className="flex items-center gap-2">
                <StatusBadge status={r.is_approved ? 'approved' : 'pending'} />
                {!r.is_approved && isOwner && (
                  <button className="btn-primary" onClick={() => approve(r.id)} disabled={busyId === r.id}>
                    {busyId === r.id ? 'Approving…' : 'Approve'}
                  </button>
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
      {proposing && (
        <ProposeRetentionDrawer
          entityId={entityId}
          onClose={() => setProposing(false)}
          onDone={() => {
            setProposing(false)
            setNotice('Retention policy proposed — awaiting Owner approval.')
            load()
          }}
        />
      )}
    </section>
  )
}

function ProposeRetentionDrawer({ entityId, onClose, onDone }: { entityId: string | null; onClose: () => void; onDone: () => void }) {
  const [table, setTable] = useState(RETENTION_TABLES[0].value)
  const [years, setYears] = useState('5')
  const [method, setMethod] = useState('manual_review')
  const [basis, setBasis] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [serverError, setServerError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  async function submit() {
    const y = Number(years)
    if (!Number.isInteger(y) || y < 1 || y > 50) return setErr('Enter whole years between 1 and 50.')
    setErr(null)
    setSaving(true)
    const res = await proposeDataRetentionPolicy(table, y, method, basis.trim() || null, entityId)
    setSaving(false)
    if (res.error || res.notAvailable) return setServerError(res.error ?? 'Not available yet.')
    onDone()
  }

  return (
    <Drawer
      open
      title="Propose retention policy"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={saving}>
            {saving ? 'Saving…' : 'Propose'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Records">
          {(p) => (
            <select {...p} className="input" value={table} onChange={(e) => setTable(e.target.value)} data-autofocus>
              {RETENTION_TABLES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
          )}
        </Field>
        <Field label="Keep for (years)" error={err} required>
          {(p) => <input {...p} type="number" min={1} max={50} className="input" value={years} onChange={(e) => setYears(e.target.value)} />}
        </Field>
        <Field label="After that">
          {(p) => (
            <select {...p} className="input" value={method} onChange={(e) => setMethod(e.target.value)}>
              {DISPOSAL.map((d) => (
                <option key={d.value} value={d.value}>
                  {d.label}
                </option>
              ))}
            </select>
          )}
        </Field>
        <Field label="Legal basis" hint="e.g. UAE Labour Law record-keeping requirement — confirm with HR/legal.">
          {(p) => <textarea {...p} rows={2} className="input" value={basis} onChange={(e) => setBasis(e.target.value)} />}
        </Field>
        {serverError && <Alert tone="error">{serverError}</Alert>}
      </div>
    </Drawer>
  )
}

function SelfApprovalSection({ isOwner }: { isOwner: boolean }) {
  const [enabled, setEnabled] = useState<boolean | null>(null)
  const [unavailable, setUnavailable] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    getEntityAdminSelfApproval().then((res) => {
      if (res.notAvailable) setUnavailable(true)
      else setEnabled(Boolean(res.data))
    })
  }, [])

  async function toggle() {
    if (enabled === null) return
    setSaving(true)
    setError(null)
    const res = await setEntityAdminSelfApproval(!enabled)
    setSaving(false)
    if (res.error || res.notAvailable) return setError(res.error ?? 'Not available yet.')
    setEnabled(!enabled)
  }

  if (unavailable) return null
  return (
    <section aria-labelledby="self-approval-h" className="card flex flex-wrap items-center justify-between gap-3">
      <div className="max-w-xl">
        <h3 id="self-approval-h" className="text-base font-semibold text-ink">
          Entity Admin self-approval
        </h3>
        <p className="text-sm text-muted">
          When on, an Entity Admin may approve their own uploads of ordinary operational documents. Sensitive documents always need Owner approval.
        </p>
        {!isOwner && <p className="mt-1 text-xs text-muted">Only the Owner can change this.</p>}
        {error && <p className="mt-1 text-sm text-brand-risk-text">{error}</p>}
      </div>
      <button
        role="switch"
        aria-checked={Boolean(enabled)}
        aria-labelledby="self-approval-h"
        onClick={toggle}
        disabled={!isOwner || saving || enabled === null}
        className={`btn ${enabled ? 'bg-brand-action-soft text-brand-action-text' : 'bg-surface-alt text-muted'}`}
      >
        {enabled === null ? '…' : enabled ? 'On' : 'Off'}
      </button>
    </section>
  )
}
