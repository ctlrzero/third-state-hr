import { useEffect, useState } from 'react'
import { Alert, Drawer, Field } from '../../components/ui'
import { supabase } from '../../lib/supabase'
import { startOffboarding } from '../../lib/api/offboarding'
import {
  defaultInitiatedBy,
  minNoticeDays,
  noticeDays,
  SEPARATION_LABEL,
  settlementDue,
  type InitiatedBy,
  type SeparationType,
} from '../../lib/offboarding'
import { fmtDate, todayDubai } from '../../lib/format'

/**
 * Start offboarding for an active employee. `employee` fixes the person
 * (profile / onboarding problem); otherwise a picker lists active staff.
 */
export default function StartOffboarding({
  entityId,
  employee,
  presetType,
  sourceExceptionId,
  onClose,
  onStarted,
}: {
  entityId: string
  employee?: { id: string; name: string } | null
  presetType?: SeparationType
  sourceExceptionId?: string | null
  onClose: () => void
  onStarted: (caseId: string) => void
}) {
  const today = todayDubai()
  const [people, setPeople] = useState<{ id: string; name: string }[]>([])
  const [employeeId, setEmployeeId] = useState(employee?.id ?? '')
  const [type, setType] = useState<SeparationType>(presetType ?? 'resignation')
  const [by, setBy] = useState<InitiatedBy>(defaultInitiatedBy(presetType ?? 'resignation'))
  const [noticeDate, setNoticeDate] = useState(today)
  const [lastDay, setLastDay] = useState('')
  const [leavingUae, setLeavingUae] = useState(false)
  const [reason, setReason] = useState('')
  const [shortfall, setShortfall] = useState('')
  const [inProbation, setInProbation] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (employee) return
    supabase
      .from('employees')
      .select('id, full_name')
      .eq('entity_id', entityId)
      .eq('employment_status', 'active')
      .order('full_name')
      .then(({ data }) => setPeople((data ?? []).map((e) => ({ id: e.id as string, name: e.full_name as string }))))
  }, [entityId, employee])

  useEffect(() => {
    if (!employeeId) return setInProbation(null)
    supabase
      .from('employee_probation_periods')
      .select('end_date')
      .eq('employee_id', employeeId)
      .eq('status', 'active')
      .maybeSingle()
      .then(({ data }) => setInProbation(Boolean(data && (data.end_date as string) >= noticeDate)))
  }, [employeeId, noticeDate])

  const min = minNoticeDays(type, by, Boolean(inProbation), leavingUae)
  const given = lastDay ? noticeDays(noticeDate, lastDay) : null
  const short = given !== null && given < min
  const suggestedLast = (() => {
    const d = new Date(noticeDate + 'T12:00:00Z')
    d.setUTCDate(d.getUTCDate() + min)
    return d.toISOString().slice(0, 10)
  })()

  async function submit() {
    setError(null)
    if (!employeeId) return setError('Choose the employee.')
    if (!lastDay) return setError('Choose the last working day.')
    if (!reason.trim()) return setError('A reason is required.')
    if (short && !shortfall.trim()) return setError(`The minimum notice is ${min} days. Record why the notice is shorter, or move the last working day.`)
    setBusy(true)
    const r = await startOffboarding({
      employeeId,
      type,
      initiatedBy: by,
      noticeDate,
      lastWorkingDate: lastDay,
      reason: reason.trim(),
      leavingUae,
      shortfallReason: short ? shortfall.trim() : null,
      sourceExceptionId: sourceExceptionId ?? null,
    })
    setBusy(false)
    if (r.error || !r.data) return setError(r.error ?? 'Could not start offboarding.')
    onStarted(r.data.case_id)
  }

  return (
    <Drawer
      open
      title={employee ? `Offboard ${employee.name}` : 'Start offboarding'}
      description="Sets the last working day for payroll and creates the leaving checklist."
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Starting…' : 'Start offboarding'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        {error && <Alert tone="error">{error}</Alert>}
        {!employee && (
          <Field label="Employee" required>
            {(p) => (
              <select className="input" {...p} value={employeeId} onChange={(e) => setEmployeeId(e.target.value)}>
                <option value="">Choose…</option>
                {people.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.name}
                  </option>
                ))}
              </select>
            )}
          </Field>
        )}
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Type" required>
            {(p) => (
              <select
                className="input"
                {...p}
                value={type}
                onChange={(e) => {
                  const t = e.target.value as SeparationType
                  setType(t)
                  setBy(defaultInitiatedBy(t))
                }}
              >
                {Object.entries(SEPARATION_LABEL).map(([k, l]) => (
                  <option key={k} value={k}>
                    {l}
                  </option>
                ))}
              </select>
            )}
          </Field>
          <Field label="Ended by">
            {(p) => (
              <select className="input" {...p} value={by} onChange={(e) => setBy(e.target.value as InitiatedBy)}>
                <option value="employee">The employee</option>
                <option value="employer">The company</option>
                <option value="mutual">Both (agreement)</option>
                <option value="none">Neither</option>
              </select>
            )}
          </Field>
          <Field label="Notice given on" required>
            {(p) => <input type="date" className="input" {...p} value={noticeDate} onChange={(e) => setNoticeDate(e.target.value)} />}
          </Field>
          <Field label="Last working day" required>
            {(p) => <input type="date" className="input" {...p} min={noticeDate} value={lastDay} onChange={(e) => setLastDay(e.target.value)} />}
          </Field>
        </div>
        {type === 'resignation' && inProbation && (
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={leavingUae} onChange={(e) => setLeavingUae(e.target.checked)} /> Leaving the UAE (not joining another UAE employer)
          </label>
        )}
        <div className="rounded-lg bg-surface-alt p-3 text-sm">
          <p className="text-ink">
            Minimum notice: <strong>{min === 0 ? 'none' : `${min} days`}</strong>
            {inProbation ? ' (in probation)' : inProbation === false ? ' (after probation)' : ''}.{' '}
            {min > 0 && (
              <button type="button" className="font-medium text-brand-blue hover:underline" onClick={() => setLastDay(suggestedLast)}>
                Use {fmtDate(suggestedLast)}
              </button>
            )}
          </p>
          {given !== null && (
            <p className={short ? 'text-brand-risk-text' : 'text-muted'}>
              Notice given: {given} days. Final settlement due by {fmtDate(settlementDue(lastDay))}.
            </p>
          )}
          <p className="mt-1 text-xs text-muted">UAE Labour Law: 14 days / one month in probation (Art. 9), at least 30 days after (Art. 43). Check the contract — it may require more.</p>
        </div>
        {short && (
          <Field label="Why is the notice shorter?" required hint="For example: paid in lieu of notice, or the employee waived notice in writing.">
            {(p) => <textarea className="input min-h-16" {...p} value={shortfall} onChange={(e) => setShortfall(e.target.value)} />}
          </Field>
        )}
        <Field label="Reason" required hint="Visible to HR only, not to the branch manager.">
          {(p) => <textarea className="input min-h-20" {...p} value={reason} onChange={(e) => setReason(e.target.value)} />}
        </Field>
      </div>
    </Drawer>
  )
}
