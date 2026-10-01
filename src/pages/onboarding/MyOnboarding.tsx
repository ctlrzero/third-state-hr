import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { Alert, Field, Skeleton } from '../../components/ui'
import { EmptyState } from '../../components/EmptyState'
import { StatusBadge } from '../../components/StatusBadge'
import {
  acceptContract,
  acknowledgePolicy,
  completeTask,
  documentLink,
  getMyContract,
  getMyOnboarding,
  saveMyPaymentDetails,
  saveMyProfile,
  submitSection,
  uploadMyDocument,
  type MyOnboarding as MyOnb,
  type OnboardingTask,
} from '../../lib/api/onboarding'
import {
  employeeOutstanding,
  formatIban,
  isPostStart,
  isPreActivation,
  isTaskDone,
  isValidUaeIban,
  missingProfileFields,
  normaliseIban,
  PROFILE_FIELDS,
  startsInLabel,
} from '../../lib/onboarding'
import { docTypeLabel } from '../../lib/documents'
import { fmtDate, todayDubai } from '../../lib/format'
import { ProgressBar, TaskStatusBadge } from './shared'
import AvailabilityStep from './AvailabilityStep'
import { getMyImmigration, type ImmigrationStepStatus } from '../../lib/api/onboarding'
import { HelpLink } from '../../components/HelpLink'

// The new starter's own portal. Everything resolves from the login on the
// server (get_my_onboarding); nothing here sends an employee id. Details
// save as you go and can be finished later.

export default function MyOnboarding() {
  const [data, setData] = useState<MyOnb | null | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const load = useCallback(async () => {
    const r = await getMyOnboarding()
    if (r.error) setError(r.error)
    setData(r.data)
  }, [])
  useEffect(() => {
    load()
  }, [load])

  const say = useCallback(
    async (msg: string) => {
      setError(null)
      setNotice(msg)
      await load()
    },
    [load]
  )

  if (data === undefined) return <Skeleton rows={5} className="h-24" />
  if (data === null)
    return (
      <div className="mx-auto max-w-2xl space-y-3">
        {error && <Alert tone="error">{error}</Alert>}
        <EmptyState title="No onboarding right now" description="When you are hired, your joining steps appear here." />
      </div>
    )

  const pre = isPreActivation(data.status)
  const post = isPostStart(data.status)
  const tasks = data.tasks
  const byKind = (k: OnboardingTask['kind']) => tasks.filter((t) => t.kind === k && t.owner_role === 'employee' && t.phase === 'pre_activation')
  const outstanding = employeeOutstanding(tasks)
  const changes = tasks.filter((t) => t.status === 'changes_required' && t.owner_role === 'employee')
  // Activated before onboarding was complete: keep the joining steps on screen until they are done.
  const catchUp = post && (outstanding.length > 0 || changes.some((t) => t.phase === 'pre_activation'))
  const showSteps = pre || catchUp
  const firstName = (data.profile.preferred_name || data.profile.full_name).split(' ')[0]
  const start = data.actual_start_date ?? data.proposed_start_date

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      <div>
        <p className="text-xs font-semibold uppercase tracking-wider text-muted">{data.company}</p>
        <h1 className="text-2xl font-semibold text-ink">Welcome, {firstName}</h1>
        <HelpLink slug="how-to-complete-your-joining-steps" />
        <p className="mt-1 text-sm text-muted">
          {[data.position?.title, data.branch?.name].filter(Boolean).join(' · ')}
          {start && ` · ${startsInLabel(start, todayDubai())} (${fmtDate(start)})`}
        </p>
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

      {pre && (
        <section className="card space-y-3">
          <ProgressBar percent={data.readiness.percent} label="Your joining steps" />
          {changes.length > 0 ? (
            <Alert tone="warning">
              Please fix: {changes.map((t) => t.item_label).join(', ')}.
              {changes.map((t) => t.review_reason && <span key={t.id} className="block text-xs">“{t.review_reason}”</span>)}
            </Alert>
          ) : outstanding.length > 0 ? (
            <p className="text-sm text-ink">
              {outstanding.length} step{outstanding.length === 1 ? '' : 's'} left for you. Your details save as you go.
            </p>
          ) : (
            <p className="text-sm text-ink">You have done everything we need. HR is reviewing — we will let you know if anything else is needed.</p>
          )}
        </section>
      )}

      {catchUp && (
        <Alert tone="warning">
          You&rsquo;re already working, but {outstanding.length || changes.length} joining step
          {(outstanding.length || changes.length) === 1 ? ' is' : 's are'} still open. Please finish them below.
        </Alert>
      )}

      {post && <DayOneCard data={data} onDone={say} onError={setError} />}

      {showSteps && (
        <>
          <ProfileStep data={data} onDone={say} onError={setError} />
          {byKind('document').length > 0 && <DocumentsStep data={data} tasks={byKind('document')} onDone={say} onError={setError} />}
          {byKind('payment_details').length > 0 && <PaymentStep data={data} onDone={say} onError={setError} />}
          {data.policies.length > 0 && <PoliciesStep data={data} onDone={say} onError={setError} />}
          {byKind('contract_acceptance').length > 0 && <ContractStep data={data} onDone={say} onError={setError} />}
          {tasks.some((t) => t.kind === 'availability') && <AvailabilityStep n={6} onDone={say} onError={setError} />}
          <ManualSteps tasks={tasks.filter((t) => t.kind === 'manual' && t.owner_role === 'employee' && t.phase === 'pre_activation')} onDone={say} onError={setError} />
        </>
      )}

      {!['completed', 'cancelled', 'withdrawn'].includes(data.status) && <VisaProgress />}
      <AboutCard data={data} />
    </div>
  )
}

interface StepProps {
  data: MyOnb
  onDone: (msg: string) => Promise<void>
  onError: (e: string) => void
}

function Step({ n, title, status, children }: { n: number | string; title: string; status?: ReactNode; children: ReactNode }) {
  return (
    <section className="card space-y-3" aria-label={title}>
      <div className="flex items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-base font-semibold text-ink">
          <span className="flex h-7 w-7 items-center justify-center rounded-full bg-brand-blue-soft text-sm text-brand-blue-text" aria-hidden="true">
            {n}
          </span>
          {title}
        </h2>
        {status}
      </div>
      {children}
    </section>
  )
}

function stepStatus(tasks: OnboardingTask[]) {
  if (tasks.length === 0) return null
  if (tasks.every((t) => isTaskDone(t.status))) return <StatusBadge status="Done" tone="success" />
  if (tasks.some((t) => t.status === 'changes_required')) return <StatusBadge status="Changes needed" tone="risk" />
  if (tasks.every((t) => isTaskDone(t.status) || t.status === 'submitted')) return <StatusBadge status="With HR" tone="warning" />
  return <StatusBadge status="To do" tone="neutral" />
}

// ----------------------------------------------------------- 1 profile
function ProfileStep({ data, onDone, onError }: StepProps) {
  const profileTasks = data.tasks.filter((t) => t.section === 'profile')
  const locked = profileTasks.some((t) => t.status === 'submitted' || t.status === 'approved')
  const [f, setF] = useState<Record<string, string>>(() =>
    Object.fromEntries(PROFILE_FIELDS.map((p) => [p.key, String((data.profile as unknown as Record<string, string | null>)[p.key] ?? '')]))
  )
  const [busy, setBusy] = useState(false)
  const missing = missingProfileFields(f)

  async function save(andSubmit: boolean) {
    setBusy(true)
    const patch = Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v.trim() || null]))
    const r = await saveMyProfile(patch)
    if (r.error) {
      setBusy(false)
      return onError(r.error)
    }
    if (andSubmit) {
      const s = await submitSection(data.id, 'profile')
      setBusy(false)
      if (s.error) return onError(s.error)
      return onDone('Your details were sent to HR for review.')
    }
    setBusy(false)
    onDone('Saved. You can come back and finish later.')
  }

  return (
    <Step n={1} title="Your details" status={stepStatus(profileTasks)}>
      {locked ? (
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          {PROFILE_FIELDS.map((p) => (
            <div key={p.key} className="contents">
              <dt className="text-muted">{p.label}</dt>
              <dd className="text-ink">{f[p.key] ? (p.type === 'date' ? fmtDate(f[p.key]) : f[p.key]) : '—'}</dd>
            </div>
          ))}
        </dl>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2">
            {PROFILE_FIELDS.map((p) => (
              <Field key={p.key} label={p.label} required={p.required}>
                {(a) =>
                  p.type === 'select' ? (
                    <select className="input" {...a} value={f[p.key]} onChange={(e) => setF({ ...f, [p.key]: e.target.value })}>
                      <option value="">—</option>
                      {p.options!.map((o) => (
                        <option key={o} value={o}>
                          {o.charAt(0).toUpperCase() + o.slice(1)}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input className="input" type={p.type} {...a} value={f[p.key]} onChange={(e) => setF({ ...f, [p.key]: e.target.value })} autoComplete="off" />
                  )
                }
              </Field>
            ))}
          </div>
          <div className="flex flex-wrap gap-2">
            <button className="btn-secondary" onClick={() => save(false)} disabled={busy}>
              Save for later
            </button>
            <button className="btn-primary" onClick={() => save(true)} disabled={busy || missing.length > 0} title={missing.length ? `Still needed: ${missing.join(', ')}` : undefined}>
              Send to HR
            </button>
          </div>
          {missing.length > 0 && <p className="text-xs text-muted">Still needed: {missing.join(', ')}.</p>}
        </>
      )}
    </Step>
  )
}

// --------------------------------------------------------- 2 documents
function DocumentsStep({ data, tasks, onDone, onError }: StepProps & { tasks: OnboardingTask[] }) {
  const needsExpiry = ['passport', 'visa', 'emirates_id', 'labor_card', 'health_card']
  return (
    <Step n={2} title="Documents" status={stepStatus(tasks.filter((t) => t.is_required))}>
      <p className="text-sm text-muted">Take a clear photo or scan of each page. PDF, JPG or PNG, up to 10 MB.</p>
      <ul className="divide-y divide-border">
        {tasks.map((t) => (
          <DocRow key={t.id} task={t} data={data} needsExpiry={needsExpiry.includes(t.doc_type ?? '')} onDone={onDone} onError={onError} />
        ))}
      </ul>
    </Step>
  )
}

function DocRow({ task, data, needsExpiry, onDone, onError }: { task: OnboardingTask; data: MyOnb; needsExpiry: boolean; onDone: StepProps['onDone']; onError: StepProps['onError'] }) {
  const [file, setFile] = useState<File | null>(null)
  const [expiry, setExpiry] = useState('')
  const [busy, setBusy] = useState(false)
  const latest = data.documents.find((d) => d.doc_type === task.doc_type)
  const canUpload = !['approved', 'waived', 'cancelled', 'submitted'].includes(task.status)
  async function upload() {
    if (!file) return onError('Choose a file first.')
    if (needsExpiry && !expiry) return onError('Enter the expiry date shown on the document.')
    setBusy(true)
    const r = await uploadMyDocument(task.doc_type!, file, expiry || null)
    setBusy(false)
    if (r.error) return onError(r.error)
    setFile(null)
    onDone(`${docTypeLabel(task.doc_type!)} uploaded. HR will check it.`)
  }
  return (
    <li className="space-y-2 py-3">
      <div className="flex items-center justify-between gap-2">
        <span className="text-sm font-medium text-ink">
          {task.item_label}
          {!task.is_required && <span className="ml-1 text-xs font-normal text-muted">(if you have one)</span>}
        </span>
        <TaskStatusBadge status={task.status} />
      </div>
      {latest?.review_status === 'rejected' && latest.rejection_reason && <p className="text-xs text-brand-risk-text">HR: {latest.rejection_reason}</p>}
      {task.item_key === 'visa' && task.status === 'approved' && !latest && <p className="text-xs text-muted">Not needed for UAE nationals.</p>}
      {canUpload && (
        <div className="flex flex-wrap items-end gap-2">
          <label className="min-w-48 flex-1">
            <span className="sr-only">File for {task.item_label}</span>
            <input type="file" accept=".pdf,.jpg,.jpeg,.png" capture="environment" className="input" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
          </label>
          {needsExpiry && (
            <label>
              <span className="label">Expiry date</span>
              <input type="date" className="input" value={expiry} onChange={(e) => setExpiry(e.target.value)} />
            </label>
          )}
          <button className="btn-primary" onClick={upload} disabled={busy || !file}>
            {busy ? 'Uploading…' : 'Upload'}
          </button>
        </div>
      )}
    </li>
  )
}

// ---------------------------------------------------------- 3 payment
function PaymentStep({ data, onDone, onError }: StepProps) {
  const pd = data.payment_details
  const tasks = data.tasks.filter((t) => t.kind === 'payment_details')
  const editable = !pd || pd.status === 'rejected' || pd.status === 'submitted'
  const [editing, setEditing] = useState(!pd || pd.status === 'rejected')
  const [f, setF] = useState({ method: pd?.method ?? 'bank_transfer', bank: pd?.bank_name ?? '', account: pd?.account_name ?? data.profile.full_name, iban: '' })
  const [busy, setBusy] = useState(false)
  const ibanOk = f.method !== 'bank_transfer' || isValidUaeIban(f.iban)
  async function save() {
    if (!ibanOk) return onError('Enter a UAE IBAN: AE followed by 21 digits.')
    setBusy(true)
    const r = await saveMyPaymentDetails(f.method, f.bank.trim(), f.account.trim(), f.iban ? normaliseIban(f.iban) : null)
    setBusy(false)
    if (r.error) return onError(r.error)
    setEditing(false)
    onDone('Payment details saved. Payroll will verify them.')
  }
  return (
    <Step n={3} title="Salary payment" status={stepStatus(tasks)}>
      {pd && !editing ? (
        <div className="space-y-2 text-sm">
          <p className="text-ink">
            {pd.method === 'bank_transfer' ? 'Bank transfer' : pd.method.replace(/_/g, ' ')} {pd.bank_name && `· ${pd.bank_name}`} {pd.iban_last4 && `· IBAN ending ${pd.iban_last4}`}
          </p>
          <p className="flex items-center gap-2">
            <StatusBadge status={pd.status} />
            {pd.rejection_reason && <span className="text-xs text-brand-risk-text">{pd.rejection_reason}</span>}
          </p>
          {editable && (
            <button className="btn-secondary" onClick={() => setEditing(true)}>
              Change
            </button>
          )}
        </div>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="How you are paid">
              {(a) => (
                <select className="input" {...a} value={f.method} onChange={(e) => setF({ ...f, method: e.target.value as typeof f.method })}>
                  <option value="bank_transfer">Bank account (WPS)</option>
                  <option value="exchange_house">Exchange house</option>
                  <option value="wps_card">WPS salary card</option>
                </select>
              )}
            </Field>
            <Field label={f.method === 'bank_transfer' ? 'Bank name' : 'Provider'}>
              {(a) => <input className="input" {...a} value={f.bank} onChange={(e) => setF({ ...f, bank: e.target.value })} />}
            </Field>
            <Field label="Account holder name">
              {(a) => <input className="input" {...a} value={f.account} onChange={(e) => setF({ ...f, account: e.target.value })} />}
            </Field>
            {f.method === 'bank_transfer' && (
              <Field label="IBAN" required error={f.iban && !ibanOk ? 'AE followed by 21 digits' : null} hint="Starts with AE — 23 characters.">
                {(a) => <input className="input font-mono" {...a} value={f.iban} onChange={(e) => setF({ ...f, iban: formatIban(e.target.value) })} inputMode="text" autoComplete="off" />}
              </Field>
            )}
          </div>
          <div className="flex gap-2">
            {pd && (
              <button className="btn-secondary" onClick={() => setEditing(false)}>
                Cancel
              </button>
            )}
            <button className="btn-primary" onClick={save} disabled={busy || !ibanOk}>
              Save
            </button>
          </div>
          <p className="text-xs text-muted">Only payroll can see your full account number.</p>
        </>
      )}
    </Step>
  )
}

// --------------------------------------------------------- 4 policies
function PoliciesStep({ data, onDone, onError }: StepProps) {
  const [open, setOpen] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const allDone = data.policies.every((p) => p.acknowledged_at)
  async function accept(id: string, title: string) {
    setBusy(true)
    const r = await acknowledgePolicy(id)
    setBusy(false)
    if (r.error) return onError(r.error)
    onDone(`${title}: accepted.`)
  }
  return (
    <Step n={4} title="Company policies" status={allDone ? <StatusBadge status="Done" tone="success" /> : <StatusBadge status="To do" tone="neutral" />}>
      <ul className="divide-y divide-border">
        {data.policies.map((p) => (
          <li key={p.id} className="py-2">
            <div className="flex items-center justify-between gap-2">
              <button className="text-left text-sm font-medium text-brand-blue hover:underline" onClick={() => setOpen(open === p.id ? null : p.id)} aria-expanded={open === p.id}>
                {p.title}
              </button>
              {p.acknowledged_at ? (
                <span className="text-xs text-muted">Accepted {fmtDate(p.acknowledged_at)}</span>
              ) : (
                <button className="btn-secondary min-h-9" onClick={() => setOpen(p.id)}>
                  Read
                </button>
              )}
            </div>
            {open === p.id && (
              <div className="mt-2 space-y-2">
                <div className="max-h-72 overflow-y-auto whitespace-pre-wrap rounded-lg bg-surface-alt p-3 text-sm text-ink">{p.body}</div>
                {!p.acknowledged_at && (
                  <button className="btn-primary" disabled={busy} onClick={() => accept(p.id, p.title)}>
                    I have read and accept this
                  </button>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
    </Step>
  )
}

// --------------------------------------------------------- 5 contract
function ContractStep({ data, onDone, onError }: StepProps) {
  const [agree, setAgree] = useState(false)
  const [busy, setBusy] = useState(false)
  const c = data.contract
  async function view() {
    // Open the tab inside the tap: phone browsers (iOS Safari) block
    // window.open() once we've awaited the network, so the contract would
    // silently never appear.
    const tab = window.open('', '_blank')
    if (tab) tab.opener = null
    const r = await getMyContract()
    const url = r.data && !r.error ? await documentLink(r.data.storage_path) : null
    if (url && tab) tab.location.href = url
    else if (url) window.location.assign(url)
    else {
      tab?.close()
      onError(r.error ?? (r.data ? 'Could not open the contract.' : 'The contract is not available yet.'))
    }
  }
  async function accept() {
    setBusy(true)
    const r = await acceptContract(data.id)
    setBusy(false)
    if (r.error) return onError(r.error)
    onDone('Thank you — your acceptance of the contract is recorded.')
  }
  return (
    <Step n={5} title="Employment contract" status={c?.accepted_at ? <StatusBadge status="Accepted" tone="success" /> : c ? <StatusBadge status="To do" tone="neutral" /> : <StatusBadge status="Being prepared" tone="info" />}>
      {!c ? (
        <p className="text-sm text-muted">HR is preparing your contract. You will be able to read and accept it here.</p>
      ) : c.accepted_at ? (
        <p className="text-sm text-ink">
          You accepted version {c.version} on {fmtDate(c.accepted_at)}.{' '}
          <button className="font-medium text-brand-blue hover:underline" onClick={view}>
            View contract
          </button>
        </p>
      ) : (
        <div className="space-y-3">
          <button className="btn-secondary" onClick={view}>
            Read your contract
          </button>
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-1" checked={agree} onChange={(e) => setAgree(e.target.checked)} />
            <span>I have read my employment contract and accept its terms.</span>
          </label>
          <button className="btn-primary" disabled={!agree || busy} onClick={accept}>
            Accept contract
          </button>
          <p className="text-xs text-muted">Your MOHRE contract is signed separately as part of your work permit.</p>
        </div>
      )}
    </Step>
  )
}

// --------------------------------------------------- other manual steps
function ManualSteps({ tasks, onDone, onError }: { tasks: OnboardingTask[]; onDone: StepProps['onDone']; onError: StepProps['onError'] }) {
  const [busy, setBusy] = useState(false)
  if (tasks.length === 0) return null
  return (
    <Step n="✓" title="Other steps">
      <ul className="divide-y divide-border">
        {tasks.map((t) => (
          <li key={t.id} className="flex items-center justify-between gap-2 py-2 text-sm">
            <span>
              {t.item_label}
              {t.description && <span className="block text-xs text-muted">{t.description}</span>}
            </span>
            {isTaskDone(t.status) || t.status === 'submitted' ? (
              <TaskStatusBadge status={t.status} />
            ) : (
              <button
                className="btn-secondary min-h-9"
                disabled={busy}
                onClick={async () => {
                  setBusy(true)
                  const r = await completeTask(t.id, null)
                  setBusy(false)
                  if (r.error) onError(r.error)
                  else onDone(`${t.item_label}: done.`)
                }}
              >
                Mark done
              </button>
            )}
          </li>
        ))}
      </ul>
    </Step>
  )
}

// --------------------------------------------------------- after start
function DayOneCard({ data, onDone, onError }: StepProps) {
  const mine = data.tasks.filter((t) => t.phase !== 'pre_activation')
  const [busy, setBusy] = useState(false)
  const policyByKey = useMemo(() => new Map(data.policies.map((p) => [p.policy_key, p])), [data.policies])
  return (
    <section className="card space-y-3">
      <h2 className="text-base font-semibold text-ink">Your first weeks</h2>
      <ul className="divide-y divide-border">
        {mine.map((t) => {
          const pol = t.kind === 'acknowledgement' && t.policy_key ? policyByKey.get(t.policy_key) : undefined
          return (
            <li key={t.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
              <span>
                {t.item_label}
                {t.due_date && !isTaskDone(t.status) && <span className="block text-xs text-muted">by {fmtDate(t.due_date)}</span>}
              </span>
              {isTaskDone(t.status) ? (
                <TaskStatusBadge status={t.status} />
              ) : pol ? (
                <button
                  className="btn-secondary min-h-9"
                  disabled={busy}
                  onClick={async () => {
                    setBusy(true)
                    const r = await acknowledgePolicy(pol.id)
                    setBusy(false)
                    if (r.error) onError(r.error)
                    else onDone(`${pol.title}: accepted.`)
                  }}
                >
                  Read and accept
                </button>
              ) : t.kind === 'manual' && t.owner_role === 'employee' ? (
                <button
                  className="btn-secondary min-h-9"
                  disabled={busy}
                  onClick={async () => {
                    setBusy(true)
                    const r = await completeTask(t.id, null)
                    setBusy(false)
                    if (r.error) onError(r.error)
                    else onDone('Done.')
                  }}
                >
                  Mark done
                </button>
              ) : (
                <span className="text-xs text-muted">Your manager completes this</span>
              )}
            </li>
          )
        })}
      </ul>
    </section>
  )
}

function AboutCard({ data }: { data: MyOnb }) {
  return (
    <section className="card space-y-2 text-sm">
      <h2 className="text-base font-semibold text-ink">About your job</h2>
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
        <dt className="text-muted">Job</dt>
        <dd className="text-ink">{data.position?.title ?? '—'}</dd>
        <dt className="text-muted">Branch</dt>
        <dd className="text-ink">
          {data.branch?.name ?? '—'}
          {data.branch?.address && <span className="block text-xs text-muted">{data.branch.address}</span>}
        </dd>
        <dt className="text-muted">Manager</dt>
        <dd className="text-ink">
          {data.manager?.name ?? '—'}
          {data.manager?.phone && (
            <a className="block text-xs text-brand-blue" href={`tel:${data.manager.phone}`}>
              {data.manager.phone}
            </a>
          )}
        </dd>
        <dt className="text-muted">Employee number</dt>
        <dd className="text-ink">{data.profile.employee_number ?? '—'}</dd>
      </dl>
      {data.position?.description && <p className="whitespace-pre-wrap text-ink">{data.position.description}</p>}
    </section>
  )
}

/** Work permit / visa progress, read-only (HR updates it). */
function VisaProgress() {
  const [steps, setSteps] = useState<{ label: string; status: ImmigrationStepStatus; completed_at: string | null }[] | null>(null)
  useEffect(() => {
    getMyImmigration().then((r) => setSteps(r.data))
  }, [])
  if (!steps || steps.length === 0) return null
  const done = steps.filter((s) => s.status === 'done').length
  return (
    <section className="card space-y-3">
      <h2 className="text-base font-semibold text-ink">Work permit and visa</h2>
      <ProgressBar percent={(100 * done) / steps.length} label={`${done} of ${steps.length} steps done`} />
      <ul className="space-y-1 text-sm">
        {steps.map((s) => (
          <li key={s.label} className="flex items-center justify-between gap-2">
            <span className={s.status === 'done' ? 'text-muted line-through' : 'text-ink'}>{s.label}</span>
            <StatusBadge
              status={s.status === 'done' ? 'Done' : s.status === 'in_progress' ? 'In progress' : s.status === 'failed' ? 'Problem' : 'Waiting'}
              tone={s.status === 'done' ? 'success' : s.status === 'failed' ? 'risk' : s.status === 'in_progress' ? 'info' : 'neutral'}
            />
          </li>
        ))}
      </ul>
      <p className="text-xs text-muted">HR arranges these with MOHRE and immigration. They will tell you when you need to attend the medical test or Emirates ID biometrics.</p>
    </section>
  )
}
