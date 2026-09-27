import { useEffect, useState } from 'react'
import { Alert, Drawer, Field } from '../../components/ui'
import { supabase } from '../../lib/supabase'
import { EMPLOYMENT_TYPES, loadPickers, type Option, type Pickers } from './pickers'
import { startDirectHire, startForEmployee } from '../../lib/api/onboarding'

/**
 * Start onboarding outside Recruiting: a direct hire (new person, reason
 * required) or an existing pre-boarding employee created before onboarding
 * existed. Accepted offers start from Recruiting → Offer.
 */
export default function StartModal({
  open,
  entityId,
  onClose,
  onStarted,
}: {
  open: boolean
  entityId: string
  onClose: () => void
  onStarted: (instanceId: string) => void
}) {
  const [mode, setMode] = useState<'direct' | 'existing'>('direct')
  const [pickers, setPickers] = useState<Pickers | null>(null)
  const [preboarding, setPreboarding] = useState<Option[]>([])
  const [f, setF] = useState({
    fullName: '',
    email: '',
    phone: '',
    gender: '',
    locationId: '',
    positionId: '',
    employmentType: 'full_time',
    startDate: '',
    managerId: '',
    reason: '',
    employeeId: '',
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    setError(null)
    loadPickers(entityId).then(setPickers)
    // Pre-boarding employees without an open onboarding.
    ;(async () => {
      const { data: emps } = await supabase
        .from('employees')
        .select('id, full_name')
        .eq('entity_id', entityId)
        .in('employment_status', ['candidate', 'pre_boarding'])
        .order('full_name')
      const { data: open } = await supabase
        .from('onboarding_instances')
        .select('employee_id')
        .eq('entity_id', entityId)
        .not('status', 'in', '(completed,cancelled,withdrawn)')
      const busyIds = new Set((open ?? []).map((o) => o.employee_id as string))
      setPreboarding((emps ?? []).filter((e) => !busyIds.has(e.id as string)).map((e) => ({ id: e.id as string, name: e.full_name as string })))
    })()
  }, [open, entityId])

  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }))

  async function submit() {
    setError(null)
    if (!f.reason.trim()) return setError('A reason is required.')
    setBusy(true)
    const res =
      mode === 'direct'
        ? await startDirectHire({
            entityId,
            fullName: f.fullName.trim(),
            email: f.email.trim() || null,
            phone: f.phone.trim() || null,
            gender: f.gender || null,
            locationId: f.locationId || null,
            positionId: f.positionId || null,
            employmentType: f.employmentType || null,
            startDate: f.startDate || null,
            managerEmployeeId: f.managerId || null,
            reason: f.reason.trim(),
          })
        : await startForEmployee(f.employeeId, f.managerId || null, f.reason.trim())
    setBusy(false)
    if (res.error || !res.data) return setError(res.error ?? 'Could not start onboarding.')
    onStarted(res.data.onboarding_instance_id)
  }

  const canSubmit = mode === 'direct' ? f.fullName.trim() && f.reason.trim() : f.employeeId && f.reason.trim()

  return (
    <Drawer
      open={open}
      title="Start onboarding"
      description="Accepted offers start from Recruiting. Use this for a direct hire or an existing pre-boarding employee."
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy || !canSubmit}>
            {busy ? 'Starting…' : 'Start onboarding'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        {error && <Alert tone="error">{error}</Alert>}
        <fieldset className="flex gap-2" aria-label="Who is starting">
          {(
            [
              ['direct', 'Direct hire'],
              ['existing', 'Existing pre-boarding employee'],
            ] as const
          ).map(([k, l]) => (
            <label key={k} className={`flex-1 cursor-pointer rounded-lg border px-3 py-2 text-sm ${mode === k ? 'border-brand-blue bg-brand-blue-soft' : 'border-border'}`}>
              <input type="radio" name="start-mode" className="sr-only" checked={mode === k} onChange={() => setMode(k)} />
              {l}
            </label>
          ))}
        </fieldset>

        {mode === 'existing' ? (
          <Field label="Employee" required hint={preboarding.length === 0 ? 'Everyone in pre-boarding already has an onboarding.' : undefined}>
            {(p) => (
              <select className="input" {...p} value={f.employeeId} onChange={set('employeeId')}>
                <option value="">Choose…</option>
                {preboarding.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.name}
                  </option>
                ))}
              </select>
            )}
          </Field>
        ) : (
          <>
            <Field label="Full name (as on passport)" required>
              {(p) => <input className="input" {...p} value={f.fullName} onChange={set('fullName')} autoComplete="off" />}
            </Field>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Email" hint="Used for the portal invitation.">
                {(p) => <input className="input" type="email" {...p} value={f.email} onChange={set('email')} />}
              </Field>
              <Field label="Mobile">
                {(p) => <input className="input" type="tel" {...p} value={f.phone} onChange={set('phone')} />}
              </Field>
              <Field label="Gender">
                {(p) => (
                  <select className="input" {...p} value={f.gender} onChange={set('gender')}>
                    <option value="">—</option>
                    <option value="female">Female</option>
                    <option value="male">Male</option>
                  </select>
                )}
              </Field>
              <Field label="Employment type">
                {(p) => (
                  <select className="input" {...p} value={f.employmentType} onChange={set('employmentType')}>
                    {EMPLOYMENT_TYPES.map((t) => (
                      <option key={t.value} value={t.value}>
                        {t.label}
                      </option>
                    ))}
                  </select>
                )}
              </Field>
              <Field label="Branch">
                {(p) => (
                  <select className="input" {...p} value={f.locationId} onChange={set('locationId')}>
                    <option value="">—</option>
                    {pickers?.locations.map((o) => (
                      <option key={o.id} value={o.id}>
                        {o.name}
                      </option>
                    ))}
                  </select>
                )}
              </Field>
              <Field label="Job">
                {(p) => (
                  <select className="input" {...p} value={f.positionId} onChange={set('positionId')}>
                    <option value="">—</option>
                    {pickers?.positions.map((o) => (
                      <option key={o.id} value={o.id}>
                        {o.name}
                      </option>
                    ))}
                  </select>
                )}
              </Field>
              <Field label="Start date">
                {(p) => <input className="input" type="date" {...p} value={f.startDate} onChange={set('startDate')} />}
              </Field>
            </div>
          </>
        )}
        <Field label="Reporting manager">
          {(p) => (
            <select className="input" {...p} value={f.managerId} onChange={set('managerId')}>
              <option value="">—</option>
              {pickers?.managers.map((o) => (
                <option key={o.id} value={o.id}>
                  {o.name}
                </option>
              ))}
            </select>
          )}
        </Field>
        <Field label="Reason" required hint={mode === 'direct' ? 'Why this hire did not go through Recruiting.' : undefined}>
          {(p) => <textarea className="input min-h-20" {...p} value={f.reason} onChange={set('reason')} />}
        </Field>
        <p className="text-xs text-muted">Missing details can be added later; the onboarding shows what is still needed before activation.</p>
      </div>
    </Drawer>
  )
}
