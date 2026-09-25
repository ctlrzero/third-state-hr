import { useCallback, useEffect, useMemo, useState } from 'react'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import {
  Alert,
  Drawer,
  Field,
  Modal,
  PageHeader,
  ResponsiveTable,
  Skeleton,
  TabPanel,
  Tabs,
  type Column,
} from '../components/ui'
import {
  activateWorkflowRule,
  createWorkflowRule,
  deactivateWorkflowRule,
  getWorkflowRules,
  getWorkflowTriggerCatalog,
  getWorkflowRuns,
  testWorkflowRule,
  type WorkflowRule,
  type WorkflowRun,
} from '../lib/api/workflows'
import {
  MODULE_LABEL,
  ROLE_LABEL,
  TARGET_ROLES,
  effectiveTriggers,
  findTrigger,
  modulesWithTriggers,
  operatorsFor,
  triggersFor,
  type LiveCatalog,
  type TriggerDef,
  type WorkflowModule,
} from '../lib/workflowCatalog'
import { useAuth } from '../auth/AuthContext'
import { buildWorkflowSummary, validateWorkflowDraft } from '../lib/workflowSummary'
import { fmtDateTime } from '../lib/format'
import type { UserRole } from '../types/db'

type TabKey = 'rules' | 'runs'

export default function Workflows() {
  const { activeEntityId, entities } = useAuth()
  const entityName = entities.find((e) => e.id === activeEntityId)?.name ?? 'this entity'
  const [triggers, setTriggers] = useState<TriggerDef[]>(effectiveTriggers(null))
  const [tab, setTab] = useState<TabKey>('rules')
  const [rules, setRules] = useState<WorkflowRule[] | null>(null)
  const [runs, setRuns] = useState<WorkflowRun[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [builderOpen, setBuilderOpen] = useState(false)
  const [testing, setTesting] = useState<WorkflowRule | null>(null)
  const [toggling, setToggling] = useState<WorkflowRule | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    getWorkflowTriggerCatalog().then((r) => {
      if (r.data && !r.error) setTriggers(effectiveTriggers(r.data as LiveCatalog))
    })
  }, [])

  // Always scoped to the entity picked in the header switcher (the owner has
  // no home entity); switching clears the previous entity's rows first.
  const loadRules = useCallback(async () => {
    setRules(null)
    const res = await getWorkflowRules(null, activeEntityId)
    if (res.error) setError(res.error)
    setRules(res.data ?? [])
  }, [activeEntityId])

  const loadRuns = useCallback(async () => {
    setRuns(null)
    const res = await getWorkflowRuns(null, 100, activeEntityId)
    if (res.error) setError(res.error)
    setRuns(res.data ?? [])
  }, [activeEntityId])

  useEffect(() => {
    loadRules()
    loadRuns()
  }, [loadRules, loadRuns])

  const ruleName = useMemo(() => Object.fromEntries((rules ?? []).map((r) => [r.id, r.name])), [rules])

  async function confirmToggle() {
    if (!toggling) return
    setBusy(true)
    const res = toggling.is_active ? await deactivateWorkflowRule(toggling.id) : await activateWorkflowRule(toggling.id)
    setBusy(false)
    if (res.error) setError(res.error)
    else setNotice(`"${toggling.name}" is now ${toggling.is_active ? 'inactive' : 'active'}.`)
    setToggling(null)
    loadRules()
  }

  const runColumns: Column<WorkflowRun>[] = [
    { key: 'when', header: 'When', render: (r) => fmtDateTime(r.ran_at) },
    { key: 'rule', header: 'Rule', render: (r) => ruleName[r.rule_id] ?? 'Rule' },
    { key: 'event', header: 'Event', render: (r) => r.event_type.replace(/_/g, ' ') },
    {
      key: 'result',
      header: 'Result',
      render: (r) => (
        <StatusBadge status={r.result} tone={r.result === 'matched' ? 'success' : r.result === 'failed' ? 'risk' : 'neutral'} />
      ),
    },
  ]

  return (
    <div className="space-y-5">
      <PageHeader
        title="Workflows"
        description={`Automatic notifications for ${entityName}. Rules only notify — they never change records.`}
        actions={
          <button className="btn-primary" onClick={() => setBuilderOpen(true)}>
            New rule
          </button>
        }
      />
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

      <Tabs<TabKey>
        label="Workflow views"
        active={tab}
        onChange={setTab}
        tabs={[
          { key: 'rules', label: 'Rules' },
          { key: 'runs', label: 'Run history' },
        ]}
      />

      {tab === 'rules' && (
        <TabPanel id="rules">
          {rules === null ? (
            <Skeleton rows={3} className="h-24" />
          ) : rules.length === 0 ? (
            <EmptyState
              title="No workflow rules yet"
              description="Create a rule to notify the right person automatically."
              action={
                <button className="btn-primary mt-2" onClick={() => setBuilderOpen(true)}>
                  New rule
                </button>
              }
            />
          ) : (
            <ul className="space-y-3">
              {rules.map((r) => (
                <li key={r.id} className="card">
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="font-semibold text-ink">
                        {r.name}
                        {r.is_starter && <span className="ml-2 text-xs font-normal text-muted">Starter rule</span>}
                      </p>
                      <p className="mt-0.5 text-sm text-ink">{buildWorkflowSummary(r)}</p>
                      <p className="mt-1 text-xs text-muted">Message: “{r.action_message_template}”</p>
                    </div>
                    <StatusBadge status={r.is_active ? 'active' : 'inactive'} />
                  </div>
                  <div className="mt-3 flex flex-wrap gap-2">
                    <button className="btn-secondary" onClick={() => setTesting(r)}>
                      Test
                    </button>
                    <button className={r.is_active ? 'btn-secondary' : 'btn-primary'} onClick={() => setToggling(r)}>
                      {r.is_active ? 'Deactivate' : 'Activate'}
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </TabPanel>
      )}

      {tab === 'runs' && (
        <TabPanel id="runs">
          {runs === null ? (
            <Skeleton rows={4} />
          ) : runs.length === 0 ? (
            <EmptyState title="No runs yet" description="When an active rule fires, it is logged here. Tests are never logged." />
          ) : (
            <ResponsiveTable caption="Workflow run history" columns={runColumns} rows={runs} rowKey={(r) => r.id} />
          )}
        </TabPanel>
      )}

      {builderOpen && (
        <RuleBuilder
          triggers={triggers}
          entityId={activeEntityId}
          onClose={() => setBuilderOpen(false)}
          onCreated={(name) => {
            setBuilderOpen(false)
            setNotice(`Rule "${name}" created as inactive. Test it, then activate it.`)
            loadRules()
          }}
        />
      )}
      {testing && <TestPanel rule={testing} onClose={() => setTesting(null)} />}
      <Modal
        open={Boolean(toggling)}
        title={toggling?.is_active ? 'Deactivate rule?' : 'Activate rule?'}
        onClose={() => setToggling(null)}
        footer={
          <>
            <button className="btn-secondary" onClick={() => setToggling(null)}>
              Cancel
            </button>
            <button className={toggling?.is_active ? 'btn-danger' : 'btn-primary'} onClick={confirmToggle} disabled={busy}>
              {busy ? 'Saving…' : toggling?.is_active ? 'Deactivate' : 'Activate'}
            </button>
          </>
        }
      >
        {toggling && <p>{buildWorkflowSummary(toggling)}</p>}
        <p className="text-muted">
          {toggling?.is_active ? 'It will stop sending notifications immediately.' : 'It will start sending notifications for new events.'}
        </p>
      </Modal>
    </div>
  )
}

function RuleBuilder({
  triggers,
  entityId,
  onClose,
  onCreated,
}: {
  triggers: TriggerDef[]
  entityId: string | null
  onClose: () => void
  onCreated: (name: string) => void
}) {
  const modules = modulesWithTriggers(triggers)
  const [name, setName] = useState('')
  const [module, setModule] = useState<WorkflowModule>(modules[0])
  const [triggerEvent, setTriggerEvent] = useState(triggersFor(modules[0], triggers)[0]?.event ?? '')
  const [useCondition, setUseCondition] = useState(false)
  const [field, setField] = useState(triggersFor(modules[0], triggers)[0]?.fields[0]?.key ?? '')
  const [operator, setOperator] = useState('gt')
  const [value, setValue] = useState('')
  const [actionType, setActionType] = useState<'notify_role' | 'notify_employee'>('notify_role')
  const [targetRole, setTargetRole] = useState<UserRole>('entity_admin')
  const [message, setMessage] = useState('')
  const [showErrors, setShowErrors] = useState(false)
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)

  const trigger = triggers.find((t) => t.module === module && t.event === triggerEvent)
  const fields = trigger?.fields ?? []
  const fieldDef = fields.find((f) => f.key === field)
  const operators = operatorsFor(fieldDef?.kind)

  const draft = {
    name,
    module,
    trigger_event: triggerEvent,
    condition_field: useCondition ? field || null : null,
    condition_operator: useCondition ? operator || null : null,
    condition_value: useCondition ? value : null,
    action_type: actionType,
    action_target_role: actionType === 'notify_role' ? targetRole : null,
    action_message_template: message,
  }
  const validation = validateWorkflowDraft(draft)
  const errs = showErrors ? validation.errors : {}

  function changeModule(m: WorkflowModule) {
    setModule(m)
    const first = triggersFor(m, triggers)[0]
    setTriggerEvent(first?.event ?? '')
    setField(first?.fields[0]?.key ?? '')
  }

  function changeTrigger(ev: string) {
    setTriggerEvent(ev)
    setField(triggers.find((t) => t.module === module && t.event === ev)?.fields[0]?.key ?? '')
    setValue('')
  }

  async function save() {
    setShowErrors(true)
    if (!validation.ok) return
    setSaving(true)
    setServerError(null)
    const res = await createWorkflowRule({
      name: name.trim(),
      module,
      trigger_event: triggerEvent,
      condition_field: draft.condition_field,
      condition_operator: draft.condition_operator,
      condition_value: draft.condition_value?.trim() || null,
      action_type: actionType,
      action_target_role: draft.action_target_role,
      action_message_template: message.trim(),
      entity_id: entityId,
    })
    setSaving(false)
    if (res.error) {
      setServerError(res.error)
      return
    }
    onCreated(name.trim())
  }

  const step = 'space-y-3 rounded-lg border border-border p-3'
  const stepTitle = 'text-sm font-semibold text-ink'

  return (
    <Drawer
      open
      wide
      title="New workflow rule"
      description="Build the rule step by step. Nothing runs until you activate it."
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save} disabled={saving}>
            {saving ? 'Creating…' : 'Create rule'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="sticky top-0 z-10 -mx-1 rounded-lg bg-brand-primary px-4 py-3 text-white" aria-live="polite">
          <p className="text-xs uppercase tracking-wide text-white/70">Summary</p>
          <p className="mt-0.5 font-medium">{buildWorkflowSummary(draft)}</p>
        </div>

        <Field label="Rule name" error={errs.name} required>
          {(p) => <input {...p} className="input" value={name} onChange={(e) => setName(e.target.value)} data-autofocus />}
        </Field>

        <fieldset className={step}>
          <legend className={stepTitle}>1. Module</legend>
          <div className="flex flex-wrap gap-2">
            {modules.map((m) => (
              <label
                key={m}
                className={`flex min-h-11 cursor-pointer items-center gap-2 rounded-lg border px-3 text-sm ${
                  module === m ? 'border-brand-blue bg-brand-blue-soft text-brand-blue-text' : 'border-border'
                }`}
              >
                <input type="radio" name="module" className="sr-only" checked={module === m} onChange={() => changeModule(m)} />
                {MODULE_LABEL[m]}
              </label>
            ))}
          </div>
        </fieldset>

        <fieldset className={step}>
          <legend className={stepTitle}>2. When this happens</legend>
          <Field label="Trigger" error={errs.trigger}>
            {(p) => (
              <select {...p} className="input" value={triggerEvent} onChange={(e) => changeTrigger(e.target.value)}>
                {triggersFor(module, triggers).map((t) => (
                  <option key={t.event} value={t.event}>
                    {t.label}
                  </option>
                ))}
              </select>
            )}
          </Field>
        </fieldset>

        <fieldset className={step}>
          <legend className={stepTitle}>3. Only if (optional)</legend>
          <label className="flex min-h-11 items-center gap-2 text-sm">
            <input type="checkbox" className="h-5 w-5 accent-brand-blue" checked={useCondition} onChange={(e) => setUseCondition(e.target.checked)} disabled={fields.length === 0} />
            Add a condition
          </label>
          {useCondition && (
            <div className="grid gap-3 sm:grid-cols-3">
              <Field label="Field">
                {(p) => (
                  <select
                    {...p}
                    className="input"
                    value={field}
                    onChange={(e) => {
                      const next = fields.find((f) => f.key === e.target.value)
                      setField(e.target.value)
                      setValue('')
                      setOperator(operatorsFor(next?.kind)[0].value)
                    }}
                  >
                    {fields.map((f) => (
                      <option key={f.key} value={f.key}>
                        {f.label}
                      </option>
                    ))}
                  </select>
                )}
              </Field>
              <Field label="Operator">
                {(p) => (
                  <select {...p} className="input" value={operator} onChange={(e) => setOperator(e.target.value)}>
                    {operators.map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                )}
              </Field>
              <Field label="Value" error={errs.condition}>
                {(p) =>
                  fieldDef?.options ? (
                    <select {...p} className="input" value={value} onChange={(e) => setValue(e.target.value)}>
                      <option value="">Choose…</option>
                      {fieldDef.options.map((o) => (
                        <option key={o.value} value={o.value}>
                          {o.label}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input
                      {...p}
                      className="input"
                      type={fieldDef?.kind === 'date' ? 'date' : 'text'}
                      inputMode={fieldDef?.kind === 'number' ? 'decimal' : undefined}
                      value={value}
                      onChange={(e) => setValue(e.target.value)}
                    />
                  )
                }
              </Field>
            </div>
          )}
        </fieldset>

        <fieldset className={step}>
          <legend className={stepTitle}>4. Then</legend>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Action">
              {(p) => (
                <select {...p} className="input" value={actionType} onChange={(e) => setActionType(e.target.value as typeof actionType)}>
                  <option value="notify_role">Notify a role</option>
                  <option value="notify_employee">Notify the employee</option>
                </select>
              )}
            </Field>
            {actionType === 'notify_role' && (
              <Field label="Who" error={errs.target}>
                {(p) => (
                  <select {...p} className="input" value={targetRole} onChange={(e) => setTargetRole(e.target.value as UserRole)}>
                    {TARGET_ROLES.map((r) => (
                      <option key={r} value={r}>
                        {ROLE_LABEL[r]}
                      </option>
                    ))}
                  </select>
                )}
              </Field>
            )}
          </div>
          <Field label="Notification message" error={errs.message} hint="Keep it short and say what action is needed." required>
            {(p) => <textarea {...p} rows={2} className="input" value={message} onChange={(e) => setMessage(e.target.value)} />}
          </Field>
        </fieldset>
        {serverError && <Alert tone="error">{serverError}</Alert>}
      </div>
    </Drawer>
  )
}

function TestPanel({ rule, onClose }: { rule: WorkflowRule; onClose: () => void }) {
  // Only the rule's own condition field affects the result, so only ask for that.
  const trigger = findTrigger(rule.module, rule.trigger_event)
  const known = trigger?.fields.find((f) => f.key === rule.condition_field)
  const fields = rule.condition_field
    ? [known ?? { key: rule.condition_field, label: rule.condition_field.replace(/_/g, ' '), phrase: '', kind: 'text' as const }]
    : []
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(fields.map((f) => [f.key, f.key === rule.condition_field ? (rule.condition_value ?? '') : '']))
  )
  const [result, setResult] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [running, setRunning] = useState(false)

  async function run() {
    setRunning(true)
    setError(null)
    setResult(null)
    const sample: Record<string, unknown> = {}
    for (const f of fields) {
      const v = values[f.key] ?? ''
      if (v === '') continue
      sample[f.key] = f.kind === 'number' && !Number.isNaN(Number(v)) ? Number(v) : v
    }
    const res = await testWorkflowRule(rule.id, sample)
    setRunning(false)
    if (res.error) setError(res.error)
    else setResult(res.data ?? null)
  }

  return (
    <Drawer
      open
      title="Test rule"
      description="Try a sample event. Tests never send notifications or create run history."
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Close
          </button>
          <button className="btn-primary" onClick={run} disabled={running}>
            {running ? 'Testing…' : 'Run test'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <p className="rounded-lg bg-surface-alt p-3 text-sm">{buildWorkflowSummary(rule)}</p>
        {fields.length === 0 ? (
          <p className="text-sm text-muted">This rule has no condition, so every event matches.</p>
        ) : (
          fields.map((f, i) => (
            <Field key={f.key} label={`Sample ${f.label.toLowerCase()}`}>
              {(p) => (
                <input
                  {...p}
                  className="input"
                  inputMode={f.kind === 'number' ? 'decimal' : undefined}
                  value={values[f.key] ?? ''}
                  onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                  data-autofocus={i === 0 ? true : undefined}
                />
              )}
            </Field>
          ))
        )}
        <div aria-live="polite">
          {result === 'matched' && <Alert tone="success">Matched — this event would send: “{rule.action_message_template}”.</Alert>}
          {result && result !== 'matched' && <Alert tone="info">Skipped — this event would not trigger the rule.</Alert>}
          {error && <Alert tone="error">{error}</Alert>}
        </div>
      </div>
    </Drawer>
  )
}
