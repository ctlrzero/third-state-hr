import { useCallback, useEffect, useState } from 'react'
import { Alert, Modal, Skeleton } from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import {
  changeImmigrationTrack,
  closeImmigrationCase,
  getImmigrationCase,
  openImmigrationCase,
  setImmigrationStepBlocking,
  updateImmigrationCase,
  updateImmigrationStep,
  type ImmigrationCase,
  type ImmigrationStep,
  type ImmigrationStepStatus,
  type ImmigrationTrack,
} from '../../lib/api/onboarding'
import { TRACK_LABEL } from '../../lib/onboarding'
import { fmtDate, todayDubai } from '../../lib/format'
import { fmtMoney } from '../../lib/payroll'
import { ReasonModal, Section } from './shared'

const STEP_STATUS: Record<ImmigrationStepStatus, { label: string; tone: 'neutral' | 'info' | 'success' | 'risk' }> = {
  not_started: { label: 'Not started', tone: 'neutral' },
  in_progress: { label: 'In progress', tone: 'info' },
  done: { label: 'Done', tone: 'success' },
  not_needed: { label: 'Not needed', tone: 'neutral' },
  failed: { label: 'Problem', tone: 'risk' },
}

/** Work permit and visa processing for one employee. Owner / entity admin only. */
export default function ImmigrationCard({ employeeId, onChanged }: { employeeId: string; onChanged?: () => void }) {
  const [data, setData] = useState<{ suggested_track: ImmigrationTrack; case: ImmigrationCase | null; steps: ImmigrationStep[] } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [track, setTrack] = useState<ImmigrationTrack>('outside_uae')
  const [editing, setEditing] = useState<ImmigrationStep | null>(null)
  const [blocking, setBlocking] = useState<ImmigrationStep | null>(null)
  const [trackChange, setTrackChange] = useState<ImmigrationTrack | null>(null)
  const [closing, setClosing] = useState<'completed' | 'cancelled' | null>(null)
  const [refs, setRefs] = useState(false)
  const [busy, setBusy] = useState(false)
  const today = todayDubai()

  const load = useCallback(async () => {
    const r = await getImmigrationCase(employeeId)
    if (r.error) return setError(r.error)
    setData(r.data)
    if (r.data) setTrack(r.data.case?.track ?? r.data.suggested_track)
  }, [employeeId])
  useEffect(() => {
    load()
  }, [load])

  async function after(res: { error: string | null }) {
    if (res.error) {
      setError(res.error)
      return res.error
    }
    await load()
    onChanged?.()
    return null
  }

  if (error && !data) return <Section title="Work permit and visa" id="imm">{<Alert tone="error">{error}</Alert>}</Section>
  if (!data) return <Skeleton rows={2} className="h-12" />
  const c = data.case
  const open = c?.status === 'open'

  return (
    <Section
      title="Work permit and visa"
      id="imm"
      actions={
        c &&
        open && (
          <>
            <button className="btn-ghost min-h-9" onClick={() => setRefs(true)}>
              References
            </button>
            <button className="btn-ghost min-h-9" onClick={() => setClosing('completed')}>
              Mark complete
            </button>
          </>
        )
      }
    >
      {error && (
        <Alert tone="error" onDismiss={() => setError(null)}>
          {error}
        </Alert>
      )}
      {!c || c.status === 'cancelled' ? (
        <div className="flex flex-wrap items-end gap-2">
          <label className="min-w-60 flex-1">
            <span className="label">Situation</span>
            <select className="input" value={track} onChange={(e) => setTrack(e.target.value as ImmigrationTrack)}>
              {Object.entries(TRACK_LABEL).map(([k, l]) => (
                <option key={k} value={k}>
                  {l}
                </option>
              ))}
            </select>
          </label>
          <button
            className="btn-primary"
            disabled={busy}
            onClick={async () => {
              setBusy(true)
              await after(await openImmigrationCase(employeeId, track, null))
              setBusy(false)
            }}
          >
            Start tracking
          </button>
          <p className="w-full text-xs text-muted">Suggested from nationality: {TRACK_LABEL[data.suggested_track]}. Steps follow from the situation; you can mark any as not needed.</p>
        </div>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <StatusBadge status={c.status} />
            {open ? (
              <label className="flex items-center gap-2">
                <span className="text-muted">Situation</span>
                <select className="input min-h-9 py-1" value={c.track} onChange={(e) => setTrackChange(e.target.value as ImmigrationTrack)}>
                  {Object.entries(TRACK_LABEL).map(([k, l]) => (
                    <option key={k} value={k}>
                      {l}
                    </option>
                  ))}
                </select>
              </label>
            ) : (
              <span>{TRACK_LABEL[c.track]}</span>
            )}
            {c.work_permit_number && <span className="text-muted">· Work permit {c.work_permit_number}</span>}
            {c.uid_number && <span className="text-muted">· UID {c.uid_number}</span>}
          </div>
          <ul className="divide-y divide-border">
            {data.steps.map((s) => {
              const overdue = !['done', 'not_needed'].includes(s.status) && s.due_date && s.due_date < today
              return (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                  <span className="min-w-0">
                    <span className={s.status === 'not_needed' ? 'text-muted line-through' : 'text-ink'}>{s.label}</span>
                    {s.is_blocking && s.status !== 'done' && s.status !== 'not_needed' && <span className="ml-1 text-xs text-brand-risk-text">blocks activation</span>}
                    <span className="block text-xs text-muted">
                      {s.reference_number && `Ref ${s.reference_number} · `}
                      {s.expiry_date && `Expires ${fmtDate(s.expiry_date)} · `}
                      {s.status === 'done' && s.completed_at ? `Done ${fmtDate(s.completed_at)}` : s.due_date ? `Target ${fmtDate(s.due_date)}` : ''}
                      {overdue && <span className="text-brand-risk-text"> · overdue</span>}
                      {s.fee_amount != null && ` · Fee ${fmtMoney(s.fee_amount)} (${s.fee_paid_by === 'employee' ? 'employee paid' : 'company paid'})`}
                    </span>
                    {s.notes && <span className="block text-xs text-muted">{s.notes}</span>}
                  </span>
                  <span className="flex items-center gap-2">
                    <StatusBadge status={STEP_STATUS[s.status].label} tone={STEP_STATUS[s.status].tone} />
                    {open && (
                      <>
                        <button className="btn-secondary min-h-9" onClick={() => setEditing(s)}>
                          Update
                        </button>
                        <button className="btn-ghost min-h-9 text-xs" onClick={() => setBlocking(s)} title="Change whether this step blocks activation">
                          {s.is_blocking ? 'Unblock' : 'Make blocking'}
                        </button>
                      </>
                    )}
                  </span>
                </li>
              )
            })}
          </ul>
          <p className="text-xs text-muted">Defaults follow MOHRE / ICP practice; check current rules for your emirate. Upload the visa and Emirates ID in Documents when issued.</p>
        </>
      )}

      {editing && <StepEditor step={editing} onClose={() => setEditing(null)} onSave={async (a) => {
        const e = await after(
          await updateImmigrationStep(
            editing.id,
            a.status,
            a.reference || null,
            a.expiry || null,
            a.due || null,
            a.notes || null,
            a.feeAmount ? Number(a.feeAmount) : null,
            a.feeAmount ? a.feePaidBy : null
          )
        )
        if (!e) setEditing(null)
        return e
      }} />}
      <ReasonModal
        open={Boolean(blocking)}
        title={blocking?.is_blocking ? 'Stop this step blocking activation' : 'Make this step block activation'}
        prompt="Why?"
        confirmLabel="Save"
        onCancel={() => setBlocking(null)}
        onConfirm={async (r) => {
          const e = blocking ? await after(await setImmigrationStepBlocking(blocking.id, !blocking.is_blocking, r)) : null
          if (!e) setBlocking(null)
          return e
        }}
      />
      <ReasonModal
        open={Boolean(trackChange)}
        title={`Change situation to “${trackChange ? TRACK_LABEL[trackChange] : ''}”`}
        prompt="Why?"
        confirmLabel="Change"
        onCancel={() => setTrackChange(null)}
        onConfirm={async (r) => {
          const e = c && trackChange ? await after(await changeImmigrationTrack(c.id, trackChange, r)) : null
          if (!e) setTrackChange(null)
          return e
        }}
      >
        <p>Steps for the new situation are added; steps that no longer apply and have not started are marked not needed.</p>
      </ReasonModal>
      <ReasonModal
        open={Boolean(closing)}
        title="Close visa tracking"
        prompt="Notes"
        optional={closing === 'completed'}
        confirmLabel="Close"
        onCancel={() => setClosing(null)}
        onConfirm={async (r) => {
          const e = c && closing ? await after(await closeImmigrationCase(c.id, closing, r || null)) : null
          if (!e) setClosing(null)
          return e
        }}
      >
        <p>All steps must be done or marked not needed.</p>
      </ReasonModal>
      {refs && c && (
        <RefsEditor
          c={c}
          onClose={() => setRefs(false)}
          onSave={async (p) => {
            const e = await after(await updateImmigrationCase(c.id, p))
            if (!e) setRefs(false)
            return e
          }}
        />
      )}
    </Section>
  )
}

function StepEditor({
  step,
  onClose,
  onSave,
}: {
  step: ImmigrationStep
  onClose: () => void
  onSave: (a: { status: ImmigrationStepStatus; reference: string; expiry: string; due: string; notes: string; feeAmount: string; feePaidBy: 'company' | 'employee' }) => Promise<string | null>
}) {
  const [f, setF] = useState({
    status: step.status,
    reference: step.reference_number ?? '',
    expiry: step.expiry_date ?? '',
    due: step.due_date ?? '',
    notes: '',
    feeAmount: step.fee_amount != null ? String(step.fee_amount) : '',
    feePaidBy: (step.fee_paid_by ?? 'company') as 'company' | 'employee',
  })
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  async function save() {
    if ((f.status === 'not_needed' || f.status === 'failed') && !f.notes.trim()) return setErr('Add a note saying why.')
    setBusy(true)
    const e = await onSave(f)
    setBusy(false)
    if (e) setErr(e)
  }
  const hasExpiry = ['residence_visa', 'emirates_id_issued', 'work_permit', 'entry_permit', 'health_insurance'].includes(step.step_key)
  return (
    <Modal
      open
      title={step.label}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save} disabled={busy}>
            Save
          </button>
        </>
      }
    >
      <label className="block">
        <span className="label">Status</span>
        <select className="input" value={f.status} onChange={(e) => setF({ ...f, status: e.target.value as ImmigrationStepStatus })}>
          {Object.entries(STEP_STATUS).map(([k, v]) => (
            <option key={k} value={k}>
              {v.label}
            </option>
          ))}
        </select>
      </label>
      <label className="block">
        <span className="label">Reference / application number</span>
        <input className="input" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} />
      </label>
      <div className="grid grid-cols-2 gap-3">
        {hasExpiry && (
          <label className="block">
            <span className="label">Valid until</span>
            <input type="date" className="input" value={f.expiry} onChange={(e) => setF({ ...f, expiry: e.target.value })} />
          </label>
        )}
        <label className="block">
          <span className="label">Target date</span>
          <input type="date" className="input" value={f.due} onChange={(e) => setF({ ...f, due: e.target.value })} />
        </label>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="label">Fee (if any)</span>
          <input
            type="number"
            min="0"
            step="0.01"
            className="input"
            value={f.feeAmount}
            onChange={(e) => setF({ ...f, feeAmount: e.target.value })}
          />
        </label>
        <label className="block">
          <span className="label">Paid by</span>
          <select className="input" value={f.feePaidBy} onChange={(e) => setF({ ...f, feePaidBy: e.target.value as 'company' | 'employee' })} disabled={!f.feeAmount}>
            <option value="company">Company</option>
            <option value="employee">Employee</option>
          </select>
        </label>
      </div>
      <label className="block">
        <span className="label">Note{f.status === 'not_needed' || f.status === 'failed' ? ' *' : ''}</span>
        <textarea className="input min-h-16" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

function RefsEditor({ c, onClose, onSave }: { c: ImmigrationCase; onClose: () => void; onSave: (p: Record<string, string | null>) => Promise<string | null> }) {
  const [f, setF] = useState({
    mohre_person_code: c.mohre_person_code ?? '',
    work_permit_number: c.work_permit_number ?? '',
    uid_number: c.uid_number ?? '',
    visa_file_number: c.visa_file_number ?? '',
    notes: c.notes ?? '',
  })
  const [err, setErr] = useState<string | null>(null)
  const fields: [keyof typeof f, string][] = [
    ['mohre_person_code', 'MOHRE person code'],
    ['work_permit_number', 'Work permit number'],
    ['uid_number', 'UID number'],
    ['visa_file_number', 'Residence visa file number'],
  ]
  return (
    <Modal
      open
      title="Visa and permit references"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            onClick={async () => {
              const e = await onSave(Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v.trim() || null])))
              if (e) setErr(e)
            }}
          >
            Save
          </button>
        </>
      }
    >
      {fields.map(([k, l]) => (
        <label key={k} className="block">
          <span className="label">{l}</span>
          <input className="input" value={f[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })} />
        </label>
      ))}
      <label className="block">
        <span className="label">Notes</span>
        <textarea className="input min-h-16" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}
