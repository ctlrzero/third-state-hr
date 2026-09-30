import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Alert, Drawer, Modal, Skeleton } from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import { supabase } from '../../lib/supabase'
import { sendInvite } from '../../lib/api/admin'
import { inviteOutcomeMessage } from '../../lib/authFlows'
import {
  activateWithOpenItems,
  approveAndActivate,
  cancelOnboarding,
  closeOnboarding,
  completeTask,
  documentLink,
  getWorkspace,
  issueInvitation,
  raiseException,
  recordDayOne,
  reissueInvitation,
  resolveException,
  reviewPay,
  reviewSection,
  reviewTask,
  setPendingPay,
  updateSetup,
  verifyPaymentDetails,
  waiveTask,
  withdrawOnboarding,
  type OnboardingTask,
  type OwnerRole,
  type Workspace,
} from '../../lib/api/onboarding'
import {
  EXCEPTION_TYPES,
  exceptionLabel,
  formatIban,
  groupBySection,
  isPostStart,
  isPreActivation,
  isTaskDone,
  OWNER_LABEL,
  PHASE_LABEL,
  startsInLabel,
} from '../../lib/onboarding'
import { docTypeLabel } from '../../lib/documents'
import { fmtDate, fmtDateTime, todayDubai } from '../../lib/format'
import { fmtMoney } from '../../lib/payroll'
import { OnboardingStatusBadge, ReadinessPanel, ReasonModal, Section, TaskStatusBadge } from './shared'
import { EMPLOYMENT_TYPES, loadPickers, type Pickers } from './pickers'
import ImmigrationCard from './ImmigrationCard'
import StartOffboarding from '../offboarding/StartOffboarding'
import { useAuth } from '../../auth/AuthContext'

type Perms = Workspace['permissions']

/** UI hint only: can this viewer act as the task's owner role? The server re-checks. */
function canOwn(p: Perms, role: OwnerRole): boolean {
  if (role === 'employee' || role === 'hr') return p.manage
  if (role === 'location_manager') return p.operate
  if (role === 'payroll') return p.payroll
  return p.approve
}
function canReview(p: Perms, role: string | null): boolean {
  if (role === 'hr') return p.manage
  if (role === 'location_manager') return p.operate
  if (role === 'payroll') return p.payroll
  return false
}

interface Doc {
  id: string
  doc_type: string
  review_status: string
  is_current: boolean
  expiry_date: string | null
  storage_path: string | null
  submitted_at: string | null
  rejection_reason: string | null
  upload_confirmed: boolean
}

type Prompt =
  | { kind: 'cancel' | 'withdraw' | 'reissue' | 'close' }
  | { kind: 'task_changes'; task: OnboardingTask }
  | { kind: 'waive'; task: OnboardingTask }
  | { kind: 'section_changes'; section: string }
  | { kind: 'pay_changes' }
  | { kind: 'bank_reject'; id: string }
  | { kind: 'doc_reject'; id: string }
  | { kind: 'resolve'; id: string }
  | null

export default function WorkspaceDrawer({
  instanceId,
  onClose,
  onChanged,
}: {
  instanceId: string | null
  onClose: () => void
  onChanged: () => void
}) {
  const [ws, setWs] = useState<Workspace | null>(null)
  const [docs, setDocs] = useState<Doc[]>([])
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [prompt, setPrompt] = useState<Prompt>(null)
  const { profile } = useAuth()
  const [panel, setPanel] = useState<'setup' | 'pay' | 'exception' | 'dayone' | 'activate' | 'activate_anyway' | 'contract' | null>(null)
  const [offboard, setOffboard] = useState<{ type: 'no_show' | 'probation_not_confirmed'; exceptionId: string } | null>(null)
  const navigate = useNavigate()

  const load = useCallback(async () => {
    if (!instanceId) return
    const res = await getWorkspace(instanceId)
    if (res.error) return setError(res.error)
    setWs(res.data)
    if (res.data) {
      const { data } = await supabase
        .from('employee_documents')
        .select('id, doc_type, review_status, is_current, expiry_date, storage_path, submitted_at, rejection_reason, upload_confirmed')
        .eq('employee_id', res.data.employee.id)
        .neq('review_status', 'archived')
        .order('submitted_at', { ascending: false })
      setDocs(((data ?? []) as Doc[]).filter((d) => d.upload_confirmed))
    }
  }, [instanceId])

  useEffect(() => {
    setWs(null)
    setError(null)
    setNotice(null)
    load()
  }, [load])

  /** Run an action, show its error or refresh + notify the list. */
  async function act(fn: () => Promise<{ error: string | null }>, ok?: string): Promise<string | null> {
    setBusy(true)
    setError(null)
    const res = await fn()
    setBusy(false)
    if (res.error) {
      setError(res.error)
      return res.error
    }
    if (ok) setNotice(ok)
    await load()
    onChanged()
    return null
  }

  const today = todayDubai()
  const status = ws?.instance.status
  const p = ws?.permissions
  const pre = status ? isPreActivation(status) : false
  const post = status ? isPostStart(status) : false
  // Owner / company admin may activate before onboarding is complete; the open items stay tracked here.
  const canOverride = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const openAfterActivation =
    !!ws?.instance.activated_with_open_items && !ws.instance.open_items_cleared_at && !pre && (ws?.readiness.blocking_count ?? 0) > 0
  const phases = useMemo(() => {
    if (!ws) return []
    return (['pre_activation', 'day_one', 'initial_period'] as const)
      .map((ph) => ({ phase: ph, groups: groupBySection(ws.tasks.filter((t) => t.phase === ph)) }))
      .filter((x) => x.groups.length > 0)
  }, [ws])
  const pendingSections = useMemo(() => {
    if (!ws) return []
    const latest = new Map<string, Workspace['sections'][number]>()
    for (const s of ws.sections) if (!latest.has(s.section) || latest.get(s.section)!.version < s.version) latest.set(s.section, s)
    return [...latest.values()].filter((s) => s.status === 'submitted')
  }, [ws])

  async function invite(reissue: boolean, reason?: string) {
    if (!ws) return 'Not loaded'
    setBusy(true)
    setError(null)
    const res = reissue ? await reissueInvitation(ws.instance.id, reason ?? '', null) : await issueInvitation(ws.instance.id)
    if (res.error || !res.data) {
      setBusy(false)
      setError(res.error)
      return res.error
    }
    let msg = res.data.already_issued ? `Invitation already sent to ${res.data.email}.` : `Invitation recorded for ${res.data.email}.`
    if (res.data.send_email) {
      const sent = await sendInvite(res.data.email)
      const out = inviteOutcomeMessage(res.data.email, { status: sent.status, errorCode: sent.errorCode, errorMessage: sent.message, httpStatus: sent.httpStatus })
      if (out.tone === 'error') {
        setBusy(false)
        setError(`Invitation recorded, but: ${out.message}`)
        await load()
        return null
      }
      msg = out.message
    } else if (!res.data.already_issued) {
      msg = `${ws.employee.name} already has a login; they will see onboarding when they sign in.`
    }
    setBusy(false)
    setNotice(msg)
    await load()
    onChanged()
    return null
  }

  async function viewDoc(d: Doc) {
    if (!d.storage_path) return
    // Open the tab inside the tap: iOS Safari blocks window.open() after an await.
    const tab = window.open('', '_blank')
    if (tab) tab.opener = null
    const url = await documentLink(d.storage_path)
    if (url && tab) tab.location.href = url
    else if (url) window.location.assign(url)
    else {
      tab?.close()
      setError('Could not open the document.')
    }
  }

  const title = ws ? ws.employee.name : 'Onboarding'
  return (
    <Drawer
      open={Boolean(instanceId)}
      title={title}
      description={ws ? `${ws.employee.employee_number ?? 'No employee number'} · ${ws.template.name ?? 'No template'} v${ws.template.version ?? '–'}` : undefined}
      onClose={onClose}
      wide
    >
      {!ws ? (
        error ? <Alert tone="error">{error}</Alert> : <Skeleton rows={6} className="h-16" />
      ) : (
        <div className="space-y-4">
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

          {/* ------------------------------------------------ header + actions */}
          <div className="flex flex-wrap items-center gap-2">
            <OnboardingStatusBadge status={ws.instance.status} />
            <span className="text-sm text-muted">
              {startsInLabel(ws.instance.actual_start_date ?? ws.instance.proposed_start_date, today)} ·{' '}
              {fmtDate(ws.instance.actual_start_date ?? ws.instance.proposed_start_date)}
            </span>
            <span className="text-sm text-muted">· {ws.instance.source === 'offer' ? 'From accepted offer' : ws.instance.source === 'direct_hire' ? 'Direct hire' : 'Existing employee'}</span>
            <Link to={`/employees/${ws.employee.id}`} className="ml-auto text-sm font-medium text-brand-blue hover:underline">
              Employee profile
            </Link>
          </div>

          <div className="flex flex-wrap gap-2">
            {pre && p?.approve && (
              <button className="btn-primary" disabled={busy || !ws.readiness.ready} onClick={() => setPanel('activate')} title={ws.readiness.ready ? undefined : 'Resolve the blocking items first'}>
                Approve and activate
              </button>
            )}
            {pre && canOverride && !ws.readiness.ready && (
              <button className="btn-secondary" disabled={busy} onClick={() => setPanel('activate_anyway')}>
                Activate anyway
              </button>
            )}
            {pre && p?.manage && !ws.employee.has_login && (
              <button className="btn-secondary" disabled={busy} onClick={() => (ws.invitation && ws.invitation.status !== 'revoked' ? setPrompt({ kind: 'reissue' }) : invite(false))}>
                {ws.invitation ? (ws.invitation.status === 'expired' ? 'Reissue invitation' : 'Resend invitation') : 'Invite to portal'}
              </button>
            )}
            {post && p?.operate && !ws.instance.day_one_outcome && (
              <button className="btn-primary" disabled={busy} onClick={() => setPanel('dayone')}>
                Record day one
              </button>
            )}
            {post && ws.instance.status !== 'activated' && p?.manage && (
              <button className="btn-secondary" disabled={busy} onClick={() => setPrompt({ kind: 'close' })}>
                Close onboarding
              </button>
            )}
            {!['completed', 'cancelled', 'withdrawn'].includes(ws.instance.status) && p?.operate && (
              <button className="btn-secondary" disabled={busy} onClick={() => setPanel('exception')}>
                Raise a problem
              </button>
            )}
            {pre && p?.manage && (
              <>
                <button className="btn-ghost" disabled={busy} onClick={() => setPrompt({ kind: 'withdraw' })}>
                  Candidate withdrew
                </button>
                <button className="btn-ghost text-brand-risk-text" disabled={busy} onClick={() => setPrompt({ kind: 'cancel' })}>
                  Cancel onboarding
                </button>
              </>
            )}
          </div>

          {openAfterActivation && (
            <Alert tone="warning">
              Activated before onboarding was complete — {ws.readiness.blocking_count} item{ws.readiness.blocking_count === 1 ? '' : 's'} still
              open. The employee is reminded daily and HR every Monday until they are done.
            </Alert>
          )}
          {(pre || openAfterActivation) && <ReadinessPanel readiness={ws.readiness} onTask={(id) => document.getElementById(`task-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' })} />}
          {ws.instance.end_reason && <Alert tone="info">Ended: {ws.instance.end_reason}</Alert>}

          {/* ------------------------------------------------------- setup */}
          <SetupCard ws={ws} onEdit={p?.manage && pre ? () => setPanel('setup') : undefined} />

          {/* -------------------------------------------------- invitation */}
          {p?.manage && (
            <Section title="Portal access" id="ws-invite">
              {ws.employee.has_login ? (
                <p className="text-sm text-ink">Signed in to the portal{ws.invitation?.accepted_at ? ` on ${fmtDate(ws.invitation.accepted_at)}` : ''}.</p>
              ) : ws.invitation ? (
                <p className="text-sm text-ink">
                  <StatusBadge status={ws.invitation.status} tone={ws.invitation.status === 'expired' ? 'risk' : 'info'} /> sent to {ws.invitation.sent_to} on{' '}
                  {fmtDate(ws.invitation.issued_at)} · expires {fmtDate(ws.invitation.expires_at)}
                </p>
              ) : (
                <p className="text-sm text-muted">Not invited yet. {ws.employee.email ? `Invitation goes to ${ws.employee.email}.` : 'Add an email in Setup first.'}</p>
              )}
            </Section>
          )}

          {/* --------------------------------------------- sections to review */}
          {pendingSections.length > 0 && (
            <Section title="Waiting for your review" id="ws-sections">
              <ul className="divide-y divide-border">
                {pendingSections.map((s) => (
                  <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                    <span>
                      {sectionName(s.section)} · submitted {fmtDateTime(s.submitted_at)} (version {s.version})
                    </span>
                    {p?.manage && (
                      <span className="flex gap-2">
                        <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPrompt({ kind: 'section_changes', section: s.section })}>
                          Request changes
                        </button>
                        <button className="btn-primary min-h-11" disabled={busy} onClick={() => act(() => reviewSection(ws.instance.id, s.section, 'approved', null), 'Section approved.')}>
                          Approve
                        </button>
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            </Section>
          )}

          {/* ------------------------------------------------------- tasks */}
          {phases.map(({ phase, groups }) => (
            <Section key={phase} title={PHASE_LABEL[phase]} id={`ws-phase-${phase}`}>
              {groups.map((g) => (
                <div key={g.section}>
                  <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">{g.label}</p>
                  <ul className="divide-y divide-border">
                    {g.tasks.map((t) => (
                      <li key={t.id} id={`task-${t.id}`} className="flex flex-wrap items-center justify-between gap-2 py-2">
                        <div className="min-w-0">
                          <p className="text-sm text-ink">
                            {t.item_label}
                            {!t.is_required && <span className="ml-1 text-xs text-muted">(optional)</span>}
                          </p>
                          <p className="text-xs text-muted">
                            {OWNER_LABEL[t.owner_role]}
                            {t.reviewer_role ? ` · reviewed by ${OWNER_LABEL[t.reviewer_role]}` : ''}
                            {t.due_date && !isTaskDone(t.status) ? ` · due ${fmtDate(t.due_date)}` : ''}
                            {t.due_date && !isTaskDone(t.status) && t.due_date < today ? ' · overdue' : ''}
                          </p>
                          {t.review_reason && t.status === 'changes_required' && <p className="text-xs text-brand-risk-text">{t.review_reason}</p>}
                          {t.waived_reason && t.status === 'waived' && <p className="text-xs text-muted">Waived: {t.waived_reason}</p>}
                          {t.kind === 'contract_acceptance' && ws.contract && (
                            <p className="text-xs text-muted">
                              Accepted version {ws.contract.document_version} on {fmtDateTime(ws.contract.accepted_at)}
                            </p>
                          )}
                        </div>
                        <div className="flex flex-wrap items-center gap-2">
                          <TaskStatusBadge status={t.status} />
                          {p && t.kind === 'manual' && !isTaskDone(t.status) && t.status !== 'submitted' && canOwn(p, t.owner_role) && (
                            <button className="btn-secondary min-h-11" disabled={busy} onClick={() => act(() => completeTask(t.id, null), `${t.item_label}: done.`)}>
                              Mark done
                            </button>
                          )}
                          {p && t.status === 'submitted' && t.kind === 'manual' && canReview(p, t.reviewer_role) && (
                            <>
                              <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPrompt({ kind: 'task_changes', task: t })}>
                                Changes
                              </button>
                              <button className="btn-primary min-h-11" disabled={busy} onClick={() => act(() => reviewTask(t.id, 'approved', null), 'Approved.')}>
                                Approve
                              </button>
                            </>
                          )}
                          {p?.manage && t.is_waivable && !isTaskDone(t.status) && !['compensation', 'contract_acceptance'].includes(t.kind) && (
                            <button className="btn-ghost min-h-11" disabled={busy} onClick={() => setPrompt({ kind: 'waive', task: t })}>
                              Waive
                            </button>
                          )}
                          {p?.manage && t.kind === 'document' && t.doc_type === 'contract' && !isTaskDone(t.status) && (
                            <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPanel('contract')}>
                              Upload contract
                            </button>
                          )}
                        </div>
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </Section>
          ))}

          {/* ------------------------------------------- work permit / visa */}
          {p?.manage && <ImmigrationCard employeeId={ws.employee.id} onChanged={() => { load(); onChanged() }} />}

          {/* --------------------------------------------------- documents */}
          <Section
            title="Documents"
            id="ws-docs"
            actions={
              <Link to="/documents" className="text-sm font-medium text-brand-blue hover:underline">
                Open Documents
              </Link>
            }
          >
            {docs.length === 0 ? (
              <p className="text-sm text-muted">Nothing uploaded yet.</p>
            ) : (
              <ul className="divide-y divide-border">
                {docs.map((d) => (
                  <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                    <span>
                      {docTypeLabel(d.doc_type)}
                      {d.expiry_date && <span className="text-muted"> · expires {fmtDate(d.expiry_date)}</span>}
                      {d.rejection_reason && d.review_status === 'rejected' && <span className="block text-xs text-brand-risk-text">{d.rejection_reason}</span>}
                    </span>
                    <span className="flex flex-wrap items-center gap-2">
                      <StatusBadge status={d.review_status} />
                      {d.storage_path && (
                        <button className="btn-ghost min-h-11" onClick={() => viewDoc(d)}>
                          View
                        </button>
                      )}
                      {d.review_status === 'pending_review' && (p?.manage || p?.operate) && (
                        <>
                          <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPrompt({ kind: 'doc_reject', id: d.id })}>
                            Reject
                          </button>
                          <button
                            className="btn-primary min-h-11"
                            disabled={busy}
                            onClick={() =>
                              act(async () => {
                                const { error } = await supabase.rpc('approve_document', { p_document_id: d.id })
                                return { error: error?.message ?? null }
                              }, 'Document approved.')
                            }
                          >
                            Approve
                          </button>
                        </>
                      )}
                    </span>
                  </li>
                ))}
              </ul>
            )}
            <p className="text-xs text-muted">Passport, visa, Emirates ID and contract need an Owner or Entity Admin to approve; the contract uploaded by an Entity Admin needs the Owner.</p>
          </Section>

          {/* --------------------------------------------------------- pay */}
          {(p?.manage || p?.payroll) && (
            <Section
              title="Starting pay"
              id="ws-pay"
              actions={
                pre && (
                  <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPanel('pay')}>
                    {ws.compensation ? 'Change pay' : 'Enter pay'}
                  </button>
                )
              }
            >
              {!ws.compensation ? (
                <p className="text-sm text-muted">Not entered. Pay is applied as the first pay version when the employee is activated.</p>
              ) : (
                <div className="space-y-2 text-sm">
                  <p className="text-ink">
                    {ws.compensation.pay_type === 'monthly' ? `${fmtMoney(ws.compensation.basic_monthly)} basic / month` : `${fmtMoney(ws.compensation.hourly_rate)} / hour`}
                    {ws.compensation.overtime_eligible ? ' · overtime eligible' : ' · no overtime'} · from {fmtDate(ws.compensation.effective_from)}
                  </p>
                  {ws.compensation.offer_amount != null && (
                    <p className="text-muted">
                      Accepted offer: {fmtMoney(ws.compensation.offer_amount)}
                      {ws.compensation.variance_reason ? ` · difference: ${ws.compensation.variance_reason}` : ''}
                    </p>
                  )}
                  <p className="flex flex-wrap items-center gap-2">
                    <StatusBadge status={ws.compensation.status} />
                    {ws.compensation.review_reason && <span className="text-xs text-brand-risk-text">{ws.compensation.review_reason}</span>}
                  </p>
                  {p?.payroll && ws.compensation.status === 'pending_review' && pre && (
                    <div className="flex gap-2">
                      <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPrompt({ kind: 'pay_changes' })}>
                        Request changes
                      </button>
                      <button className="btn-primary min-h-11" disabled={busy} onClick={() => act(() => reviewPay(ws.instance.id, 'approved', null), 'Pay approved.')}>
                        Approve pay
                      </button>
                    </div>
                  )}
                  <p className="text-xs text-muted">The person who enters the pay cannot approve it.</p>
                </div>
              )}
            </Section>
          )}

          {/* ---------------------------------------------------- bank details */}
          {(p?.manage || p?.payroll) && (
            <Section title="Salary payment details" id="ws-bank">
              {!ws.payment_details ? (
                <p className="text-sm text-muted">The employee has not entered them yet.</p>
              ) : (
                <div className="space-y-2 text-sm">
                  <p className="text-ink">
                    {ws.payment_details.method.replace(/_/g, ' ')}
                    {ws.payment_details.bank_name ? ` · ${ws.payment_details.bank_name}` : ''}
                    {ws.payment_details.account_name ? ` · ${ws.payment_details.account_name}` : ''}
                  </p>
                  <p className="font-mono text-ink">
                    {ws.payment_details.iban ? formatIban(ws.payment_details.iban) : ws.payment_details.iban_last4 ? `•••• ${ws.payment_details.iban_last4}` : '—'}
                  </p>
                  <p className="flex items-center gap-2">
                    <StatusBadge status={ws.payment_details.status} />
                    {ws.payment_details.rejection_reason && <span className="text-xs text-brand-risk-text">{ws.payment_details.rejection_reason}</span>}
                  </p>
                  {p?.payroll && ws.payment_details.status === 'submitted' && ws.payment_details.id && (
                    <div className="flex gap-2">
                      <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPrompt({ kind: 'bank_reject', id: ws.payment_details!.id! })}>
                        Reject
                      </button>
                      <button className="btn-primary min-h-11" disabled={busy} onClick={() => act(() => verifyPaymentDetails(ws.payment_details!.id!, 'verified', null), 'Bank details verified.')}>
                        Verify
                      </button>
                    </div>
                  )}
                </div>
              )}
            </Section>
          )}

          {/* --------------------------------------------------- exceptions */}
          {ws.exceptions.length > 0 && (
            <Section title="Problems" id="ws-exceptions">
              <ul className="divide-y divide-border">
                {ws.exceptions.map((x) => (
                  <li key={x.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                    <span>
                      <strong className="font-semibold">{exceptionLabel(x.exception_type)}</strong>
                      {x.is_blocking && x.status === 'open' && <span className="ml-1 text-xs text-brand-risk-text">blocking</span>}
                      <span className="block text-muted">{x.description}</span>
                      {x.resolution && <span className="block text-xs text-muted">Resolved: {x.resolution}</span>}
                    </span>
                    <span className="flex items-center gap-2">
                      <StatusBadge status={x.status} />
                      <span className="text-xs text-muted">{OWNER_LABEL[x.owner_role]}</span>
                      {x.status === 'open' && p?.manage && ws.employee.employment_status === 'active' && (x.exception_type === 'no_show' || x.exception_type === 'probation_not_confirmed') && (
                        <button className="btn-primary min-h-11" disabled={busy} onClick={() => setOffboard({ type: x.exception_type as 'no_show' | 'probation_not_confirmed', exceptionId: x.id })}>
                          Start offboarding
                        </button>
                      )}
                      {x.status === 'open' && (
                        <button className="btn-secondary min-h-11" disabled={busy} onClick={() => setPrompt({ kind: 'resolve', id: x.id })}>
                          Resolve
                        </button>
                      )}
                    </span>
                  </li>
                ))}
              </ul>
            </Section>
          )}

          {/* ---------------------------------------------------- probation */}
          {ws.probation && ws.probation.length > 0 && (
            <Section title="Probation" id="ws-prob">
              <ul className="space-y-1 text-sm">
                {ws.probation.map((pp) => (
                  <li key={pp.id} className="flex flex-wrap items-center gap-2">
                    <StatusBadge status={pp.status} />
                    {fmtDate(pp.start_date)} – {fmtDate(pp.end_date)} · review by {fmtDate(pp.review_due_date)}
                  </li>
                ))}
              </ul>
              <p className="text-xs text-muted">Reviews and decisions are on the Probation tab.</p>
            </Section>
          )}

          {/* ----------------------------------------------------- timeline */}
          <details className="card">
            <summary className="cursor-pointer text-sm font-semibold text-ink">History ({ws.timeline.length})</summary>
            <ul className="mt-2 space-y-1 text-sm">
              {ws.timeline.map((h, i) => (
                <li key={i} className="flex justify-between gap-3">
                  <span className="text-ink">{h.action.replace(/_/g, ' ')}</span>
                  <span className="shrink-0 text-xs text-muted">
                    {h.by ?? 'System'} · {fmtDateTime(h.at)}
                  </span>
                </li>
              ))}
            </ul>
          </details>
        </div>
      )}

      {/* ------------------------------------------------------ dialogs */}
      {ws && (
        <>
          <ReasonModal
            open={prompt?.kind === 'cancel' || prompt?.kind === 'withdraw'}
            title={prompt?.kind === 'withdraw' ? 'Candidate withdrew' : 'Cancel onboarding'}
            prompt="Reason"
            danger
            confirmLabel={prompt?.kind === 'withdraw' ? 'Record withdrawal' : 'Cancel onboarding'}
            onCancel={() => setPrompt(null)}
            onConfirm={async (r) => {
              const err = await act(() => (prompt?.kind === 'withdraw' ? withdrawOnboarding(ws.instance.id, r) : cancelOnboarding(ws.instance.id, r)), 'Onboarding ended. The employee record is kept and set to inactive.')
              if (!err) setPrompt(null)
              return err
            }}
          >
            <p>Open tasks are cancelled, the invitation is revoked and the employee record is kept as inactive.</p>
          </ReasonModal>
          <ReasonModal
            open={prompt?.kind === 'reissue'}
            title="Reissue invitation"
            prompt="Why reissue?"
            confirmLabel="Reissue and send"
            onCancel={() => setPrompt(null)}
            onConfirm={async (r) => {
              const err = await invite(true, r)
              if (!err) setPrompt(null)
              return err
            }}
          />
          <ReasonModal
            open={prompt?.kind === 'close'}
            title="Close onboarding"
            prompt="Closing notes"
            optional
            confirmLabel="Close onboarding"
            onCancel={() => setPrompt(null)}
            onConfirm={async (r) => {
              const err = await act(() => closeOnboarding(ws.instance.id, r || null), 'Onboarding completed.')
              if (!err) setPrompt(null)
              return err
            }}
          />
          <ReasonModal
            open={prompt?.kind === 'task_changes' || prompt?.kind === 'section_changes' || prompt?.kind === 'pay_changes'}
            title="Request changes"
            prompt="What needs to change?"
            confirmLabel="Send back"
            onCancel={() => setPrompt(null)}
            onConfirm={async (r) => {
              const pr = prompt
              const err = await act(
                () =>
                  pr?.kind === 'task_changes'
                    ? reviewTask(pr.task.id, 'changes_required', r)
                    : pr?.kind === 'section_changes'
                      ? reviewSection(ws.instance.id, pr.section, 'changes_required', r)
                      : reviewPay(ws.instance.id, 'changes_required', r),
                'Sent back with your note.'
              )
              if (!err) setPrompt(null)
              return err
            }}
          />
          <ReasonModal
            open={prompt?.kind === 'waive'}
            title={prompt?.kind === 'waive' ? `Waive “${prompt.task.item_label}”` : 'Waive'}
            prompt="Why is it not needed?"
            confirmLabel="Waive"
            onCancel={() => setPrompt(null)}
            onConfirm={async (r) => {
              const err = prompt?.kind === 'waive' ? await act(() => waiveTask(prompt.task.id, r), 'Task waived.') : null
              if (!err) setPrompt(null)
              return err
            }}
          />
          <ReasonModal
            open={prompt?.kind === 'bank_reject' || prompt?.kind === 'doc_reject'}
            title={prompt?.kind === 'bank_reject' ? 'Reject bank details' : 'Reject document'}
            prompt="Tell the employee what is wrong"
            danger
            confirmLabel="Reject"
            onCancel={() => setPrompt(null)}
            onConfirm={async (r) => {
              const pr = prompt
              const err = await act(async () => {
                if (pr?.kind === 'bank_reject') return verifyPaymentDetails(pr.id, 'rejected', r)
                if (pr?.kind === 'doc_reject') {
                  const { error } = await supabase.rpc('reject_document', { p_document_id: pr.id, p_reason: r })
                  return { error: error?.message ?? null }
                }
                return { error: null }
              }, 'Rejected. The employee has been asked to fix it.')
              if (!err) setPrompt(null)
              return err
            }}
          />
          <ReasonModal
            open={prompt?.kind === 'resolve'}
            title="Resolve problem"
            prompt="How was it resolved?"
            confirmLabel="Resolve"
            onCancel={() => setPrompt(null)}
            onConfirm={async (r) => {
              const err = prompt?.kind === 'resolve' ? await act(() => resolveException(prompt.id, r), 'Resolved.') : null
              if (!err) setPrompt(null)
              return err
            }}
          />
          {panel === 'setup' && <SetupEditor ws={ws} onClose={() => setPanel(null)} act={act} />}
          {panel === 'pay' && <PayEditor ws={ws} onClose={() => setPanel(null)} act={act} />}
          {panel === 'exception' && <ExceptionEditor ws={ws} onClose={() => setPanel(null)} act={act} />}
          {panel === 'dayone' && <DayOneEditor ws={ws} onClose={() => setPanel(null)} act={act} />}
          {panel === 'activate' && <ActivateDialog ws={ws} onClose={() => setPanel(null)} act={act} />}
          {panel === 'activate_anyway' && <ActivateAnywayDialog ws={ws} onClose={() => setPanel(null)} act={act} />}
          {panel === 'contract' && <ContractUpload ws={ws} onClose={() => setPanel(null)} act={act} />}
          {offboard && (
            <StartOffboarding
              entityId={ws.instance.entity_id}
              employee={{ id: ws.employee.id, name: ws.employee.name }}
              presetType={offboard.type}
              sourceExceptionId={offboard.exceptionId}
              onClose={() => setOffboard(null)}
              onStarted={(id) => navigate(`/offboarding?open=${id}`)}
            />
          )}
        </>
      )}
    </Drawer>
  )
}

function sectionName(s: string) {
  return groupBySection([{ section: s } as OnboardingTask])[0]?.label ?? s
}

type Act = (fn: () => Promise<{ error: string | null }>, ok?: string) => Promise<string | null>

// ---------------------------------------------------------------- setup
function SetupCard({ ws, onEdit }: { ws: Workspace; onEdit?: () => void }) {
  const [names, setNames] = useState<{ branch?: string; position?: string; manager?: string }>({})
  useEffect(() => {
    ;(async () => {
      const i = ws.instance
      const [l, p, m] = await Promise.all([
        i.home_location_id ? supabase.from('locations').select('name').eq('id', i.home_location_id).maybeSingle() : Promise.resolve({ data: null }),
        i.position_id ? supabase.from('positions').select('title').eq('id', i.position_id).maybeSingle() : Promise.resolve({ data: null }),
        i.reporting_manager_employee_id ? supabase.from('employees').select('full_name').eq('id', i.reporting_manager_employee_id).maybeSingle() : Promise.resolve({ data: null }),
      ])
      setNames({
        branch: (l.data as { name?: string } | null)?.name,
        position: (p.data as { title?: string } | null)?.title,
        manager: (m.data as { full_name?: string } | null)?.full_name,
      })
    })()
  }, [ws.instance])
  const rows: [string, string | null | undefined][] = [
    ['Branch', names.branch],
    ['Job', names.position],
    ['Reporting manager', names.manager],
    ['Employment type', EMPLOYMENT_TYPES.find((t) => t.value === ws.instance.employment_type)?.label ?? ws.instance.employment_type],
    ['Start date', fmtDate(ws.instance.actual_start_date ?? ws.instance.proposed_start_date)],
    ['Email', ws.employee.email],
    ['Mobile', ws.employee.phone],
  ]
  return (
    <Section
      title="Setup"
      id="ws-setup"
      actions={
        onEdit && (
          <button className="btn-secondary min-h-11" onClick={onEdit}>
            Edit
          </button>
        )
      }
    >
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
        {rows.map(([k, v]) => (
          <div key={k} className="contents">
            <dt className="text-muted">{k}</dt>
            <dd className={v ? 'text-ink' : 'text-brand-risk-text'}>{v || 'Not set'}</dd>
          </div>
        ))}
      </dl>
    </Section>
  )
}

function SetupEditor({ ws, onClose, act }: { ws: Workspace; onClose: () => void; act: Act }) {
  const [pk, setPk] = useState<Pickers | null>(null)
  const i = ws.instance
  const [f, setF] = useState({
    home_location_id: i.home_location_id ?? '',
    position_id: i.position_id ?? '',
    reporting_manager_employee_id: i.reporting_manager_employee_id ?? '',
    employment_type: i.employment_type ?? 'full_time',
    proposed_start_date: i.proposed_start_date ?? '',
    reason: '',
  })
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => {
    loadPickers(i.entity_id).then(setPk)
  }, [i.entity_id])
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }))
  async function save() {
    if (!f.reason.trim()) return setErr('A reason is required.')
    const patch: Record<string, string | null> = {}
    ;(['home_location_id', 'position_id', 'reporting_manager_employee_id', 'employment_type', 'proposed_start_date'] as const).forEach((k) => {
      const before = (i as unknown as Record<string, string | null>)[k] ?? ''
      if (f[k] !== before) patch[k] = f[k] || null
    })
    if (Object.keys(patch).length === 0) return onClose()
    const e = await act(() => updateSetup(i.id, patch, f.reason.trim(), i.row_version), 'Setup updated.')
    if (e) setErr(e)
    else onClose()
  }
  const sel = (k: 'home_location_id' | 'position_id' | 'reporting_manager_employee_id', opts: { id: string; name: string }[] | undefined) => (
    <select className="input" value={f[k]} onChange={set(k)}>
      <option value="">—</option>
      {opts?.map((o) => (
        <option key={o.id} value={o.id}>
          {o.name}
        </option>
      ))}
    </select>
  )
  return (
    <Modal
      open
      title="Edit setup"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save}>
            Save
          </button>
        </>
      }
    >
      <label className="block">
        <span className="label">Branch</span>
        {sel('home_location_id', pk?.locations)}
      </label>
      <label className="block">
        <span className="label">Job</span>
        {sel('position_id', pk?.positions)}
      </label>
      <label className="block">
        <span className="label">Reporting manager</span>
        {sel('reporting_manager_employee_id', pk?.managers)}
      </label>
      <label className="block">
        <span className="label">Employment type</span>
        <select className="input" value={f.employment_type} onChange={set('employment_type')}>
          {EMPLOYMENT_TYPES.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label}
            </option>
          ))}
        </select>
      </label>
      <label className="block">
        <span className="label">Start date</span>
        <input type="date" className="input" value={f.proposed_start_date} onChange={set('proposed_start_date')} />
      </label>
      <label className="block">
        <span className="label">Reason *</span>
        <textarea className="input min-h-16" value={f.reason} onChange={set('reason')} />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

// ------------------------------------------------------------------ pay
function PayEditor({ ws, onClose, act }: { ws: Workspace; onClose: () => void; act: Act }) {
  const c = ws.compensation
  const [f, setF] = useState({
    payType: (c?.pay_type ?? 'monthly') as 'monthly' | 'hourly',
    amount: String((c?.pay_type === 'hourly' ? c?.hourly_rate : c?.basic_monthly) ?? ''),
    overtime: c?.overtime_eligible ?? true,
    effectiveFrom: c?.effective_from ?? ws.instance.proposed_start_date ?? '',
    reason: c?.reason ?? 'Starting pay',
    variance: c?.variance_reason ?? '',
  })
  const [err, setErr] = useState<string | null>(null)
  const amount = Number(f.amount)
  const offer = c?.offer_amount ?? null
  const differs = offer != null && f.payType === 'monthly' && amount > 0 && amount !== offer
  async function save() {
    if (!(amount > 0)) return setErr('Enter an amount above zero.')
    if (differs && !f.variance.trim()) return setErr('Explain why the pay differs from the accepted offer.')
    const e = await act(
      () =>
        setPendingPay(ws.instance.id, {
          effectiveFrom: f.effectiveFrom || null,
          payType: f.payType,
          basicMonthly: f.payType === 'monthly' ? amount : null,
          hourlyRate: f.payType === 'hourly' ? amount : null,
          overtimeEligible: f.overtime,
          reason: f.reason.trim() || null,
          varianceReason: f.variance.trim() || null,
        }),
      'Pay saved and sent to payroll for review.'
    )
    if (e) setErr(e)
    else onClose()
  }
  return (
    <Modal
      open
      title="Starting pay"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save}>
            Save for review
          </button>
        </>
      }
    >
      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="label">Pay type</span>
          <select className="input" value={f.payType} onChange={(e) => setF({ ...f, payType: e.target.value as 'monthly' | 'hourly' })}>
            <option value="monthly">Monthly salary</option>
            <option value="hourly">Hourly</option>
          </select>
        </label>
        <label className="block">
          <span className="label">{f.payType === 'monthly' ? 'Basic per month (AED)' : 'Rate per hour (AED)'}</span>
          <input type="number" min="0" step="0.01" inputMode="decimal" className="input" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} />
        </label>
        <label className="block">
          <span className="label">Effective from</span>
          <input type="date" className="input" value={f.effectiveFrom} onChange={(e) => setF({ ...f, effectiveFrom: e.target.value })} />
        </label>
        <label className="flex items-center gap-2 pt-6 text-sm">
          <input type="checkbox" checked={f.overtime} onChange={(e) => setF({ ...f, overtime: e.target.checked })} /> Overtime eligible
        </label>
      </div>
      {offer != null && <p className="text-xs text-muted">Accepted offer: {fmtMoney(offer)} per month.</p>}
      {differs && (
        <label className="block">
          <span className="label">Why does it differ from the offer? *</span>
          <textarea className="input min-h-16" value={f.variance} onChange={(e) => setF({ ...f, variance: e.target.value })} />
        </label>
      )}
      <label className="block">
        <span className="label">Note</span>
        <input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} />
      </label>
      <p className="text-xs text-muted">Housing, transport and other allowances are added in Payroll after activation.</p>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

// ------------------------------------------------------------ exception
function ExceptionEditor({ ws, onClose, act }: { ws: Workspace; onClose: () => void; act: Act }) {
  const [f, setF] = useState({ type: 'other', description: '', owner: 'hr', blocking: true, due: '' })
  const [err, setErr] = useState<string | null>(null)
  async function save() {
    if (!f.description.trim()) return setErr('Describe the problem.')
    const e = await act(() => raiseException(ws.instance.id, f.type, f.description.trim(), f.owner, f.blocking, f.due || null), 'Problem recorded.')
    if (e) setErr(e)
    else onClose()
  }
  return (
    <Modal
      open
      title="Raise a problem"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save}>
            Record
          </button>
        </>
      }
    >
      <label className="block">
        <span className="label">Type</span>
        <select className="input" value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>
          {EXCEPTION_TYPES.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label}
            </option>
          ))}
        </select>
      </label>
      <label className="block">
        <span className="label">What happened *</span>
        <textarea className="input min-h-16" value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} />
      </label>
      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="label">Who must act</span>
          <select className="input" value={f.owner} onChange={(e) => setF({ ...f, owner: e.target.value })}>
            <option value="hr">HR</option>
            <option value="location_manager">Branch manager</option>
            <option value="payroll">Payroll</option>
            <option value="approver">Approver</option>
          </select>
        </label>
        <label className="block">
          <span className="label">Due</span>
          <input type="date" className="input" value={f.due} onChange={(e) => setF({ ...f, due: e.target.value })} />
        </label>
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={f.blocking} onChange={(e) => setF({ ...f, blocking: e.target.checked })} /> Blocks activation until resolved
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

// -------------------------------------------------------------- day one
function DayOneEditor({ ws, onClose, act }: { ws: Workspace; onClose: () => void; act: Act }) {
  const [outcome, setOutcome] = useState<'started' | 'no_show' | 'delayed'>('started')
  const [date, setDate] = useState('')
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  async function save() {
    if (outcome !== 'started' && !reason.trim()) return setErr('A reason is required.')
    if (outcome === 'delayed' && !date) return setErr('Choose the new start date.')
    const e = await act(
      () => recordDayOne(ws.instance.id, outcome, outcome === 'delayed' ? date : null, reason.trim() || null),
      outcome === 'started' ? 'Day one recorded. Work through the day-one checklist.' : outcome === 'delayed' ? 'Start moved; probation moved with it.' : 'No-show recorded for HR.'
    )
    if (e) setErr(e)
    else onClose()
  }
  return (
    <Modal
      open
      title={`Day one — ${ws.employee.name}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save}>
            Save
          </button>
        </>
      }
    >
      <fieldset className="space-y-2">
        {(
          [
            ['started', 'Arrived and started'],
            ['delayed', 'Start is delayed'],
            ['no_show', 'Did not arrive'],
          ] as const
        ).map(([k, l]) => (
          <label key={k} className="flex items-center gap-2 text-sm">
            <input type="radio" name="dayone" checked={outcome === k} onChange={() => setOutcome(k)} /> {l}
          </label>
        ))}
      </fieldset>
      {outcome === 'delayed' && (
        <label className="block">
          <span className="label">New start date *</span>
          <input type="date" className="input" value={date} onChange={(e) => setDate(e.target.value)} />
        </label>
      )}
      {outcome !== 'started' && (
        <label className="block">
          <span className="label">Reason *</span>
          <textarea className="input min-h-16" value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>
      )}
      {outcome === 'no_show' && <p className="text-xs text-muted">HR gets a blocking follow-up. The employee stays active until HR decides.</p>}
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

// ----------------------------------------------------------- activation
function ActivateDialog({ ws, onClose, act }: { ws: Workspace; onClose: () => void; act: Act }) {
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  async function go() {
    setBusy(true)
    const e = await act(() => approveAndActivate(ws.instance.id, ws.instance.row_version, reason.trim() || null), `${ws.employee.name} is now active.`)
    setBusy(false)
    if (e) setErr(e)
    else onClose()
  }
  const start = ws.instance.proposed_start_date
  return (
    <Modal
      open
      title={`Activate ${ws.employee.name}?`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn-primary" onClick={go} disabled={busy}>
            {busy ? 'Activating…' : 'Approve and activate'}
          </button>
        </>
      }
    >
      <p>This happens in one step, and the checks run again on the server first:</p>
      <ul className="list-disc space-y-1 pl-5">
        <li>employment becomes active from {fmtDate(start)}</li>
        <li>the approved starting pay becomes the first pay version</li>
        <li>probation opens (up to six months)</li>
        <li>day-one and first-weeks tasks are created, and the employee, manager and HR are notified</li>
      </ul>
      <label className="block">
        <span className="label">Note (optional)</span>
        <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

// ------------------------------------------------ activate with open items
function ActivateAnywayDialog({ ws, onClose, act }: { ws: Workspace; onClose: () => void; act: Act }) {
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  async function go() {
    if (!reason.trim()) return setErr('Give a reason.')
    setBusy(true)
    const e = await act(
      () => activateWithOpenItems(ws.instance.id, ws.instance.row_version, reason.trim()),
      `${ws.employee.name} is now active. The open onboarding items stay on this page until they are done.`
    )
    setBusy(false)
    if (e) setErr(e)
    else onClose()
  }
  const blockers = ws.readiness.blockers
  return (
    <Modal
      open
      title={`Activate ${ws.employee.name} before onboarding is complete?`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn-primary" onClick={go} disabled={busy || !reason.trim()}>
            {busy ? 'Activating…' : 'Activate anyway'}
          </button>
        </>
      }
    >
      <p>They become active from {fmtDate(ws.instance.proposed_start_date)} and can be scheduled and clock in. These stay open:</p>
      <ul className="max-h-48 list-disc space-y-1 overflow-y-auto pl-5 text-sm">
        {blockers.map((b, n) => (
          <li key={n}>{b.message}</li>
        ))}
      </ul>
      <p className="text-xs text-muted">
        Starting pay is applied only once payroll has approved it — until then payroll shows “No pay set”. The employee is reminded daily and HR every
        Monday until everything is done. Home branch, start date and duplicate checks still apply.
      </p>
      <label className="block">
        <span className="label">Reason *</span>
        <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. starts tomorrow, visa in process" />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

// ------------------------------------------------------ contract upload
function ContractUpload({ ws, onClose, act }: { ws: Workspace; onClose: () => void; act: Act }) {
  const [file, setFile] = useState<File | null>(null)
  const [expiry, setExpiry] = useState('')
  const [err, setErr] = useState<string | null>(null)
  async function go() {
    if (!file) return setErr('Choose the contract file.')
    const ext = file.name.split('.').pop()?.toLowerCase() ?? ''
    if (!['pdf', 'jpg', 'jpeg', 'png'].includes(ext)) return setErr('Only PDF, JPG and PNG files are accepted.')
    const e = await act(async () => {
      const { data, error } = await supabase.rpc('stage_document_upload', {
        p_employee_id: ws.employee.id,
        p_doc_type: 'contract',
        p_file_extension: ext,
        p_expiry_date: expiry || null,
        p_notes: 'Employment contract (onboarding)',
      })
      if (error) return { error: error.message }
      const staged = data as { id: string; storage_path: string }
      const up = await supabase.storage.from('employee-documents').upload(staged.storage_path, file, { upsert: false })
      if (up.error) return { error: `Upload failed: ${up.error.message}` }
      const { data: c, error: cErr } = await supabase.rpc('confirm_document_upload', { p_document_id: staged.id })
      if (cErr) return { error: cErr.message }
      return { error: (c as { ok: boolean }).ok ? null : 'The upload did not complete — please try again.' }
    }, 'Contract uploaded. Once approved, the employee can read and accept it in the portal.')
    if (e) setErr(e)
    else onClose()
  }
  return (
    <Modal
      open
      title="Upload employment contract"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={go}>
            Upload
          </button>
        </>
      }
    >
      <label className="block">
        <span className="label">Contract file (PDF, JPG or PNG)</span>
        <input type="file" accept=".pdf,.jpg,.jpeg,.png" className="input" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
      </label>
      <label className="block">
        <span className="label">Contract end date (limited contracts)</span>
        <input type="date" className="input" value={expiry} onChange={(e) => setExpiry(e.target.value)} />
      </label>
      <p className="text-xs text-muted">A contract uploaded by an Entity Admin is approved by the Owner (existing document rule).</p>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}
