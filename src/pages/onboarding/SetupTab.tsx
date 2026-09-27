import { useCallback, useEffect, useState } from 'react'
import { useAuth } from '../../auth/AuthContext'
import { Alert, Modal, Skeleton } from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import { confirmDialog } from '../../lib/confirm'
import {
  deactivateTemplate,
  getNumbering,
  getSettings,
  listPolicies,
  listTemplates,
  listTemplateTasks,
  seedDefaultTemplate,
  setNumbering,
  setSettings,
  upsertPolicy,
  type OnboardingPolicy,
  type OnboardingSettings,
  type OnboardingTemplate,
} from '../../lib/api/onboarding'
import { OWNER_LABEL, PHASE_LABEL, SECTION_LABEL } from '../../lib/onboarding'
import { Section } from './shared'

/** Company onboarding setup: rules, employee numbers, templates, policies. Owner / entity admin only. */
export default function SetupTab({ entityId, onChanged }: { entityId: string; onChanged: () => void }) {
  const { profile } = useAuth()
  const isOwner = profile?.role === 'owner'
  const [settings, setS] = useState<OnboardingSettings | null>(null)
  const [numbering, setN] = useState<{ prefix: string; next_value: number; pad_width: number } | null>(null)
  const [templates, setTemplates] = useState<OnboardingTemplate[] | null>(null)
  const [policies, setPolicies] = useState<OnboardingPolicy[] | null>(null)
  const [viewing, setViewing] = useState<OnboardingTemplate | null>(null)
  const [editingPolicy, setEditingPolicy] = useState<OnboardingPolicy | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const [s, n, t, p] = await Promise.all([getSettings(entityId), getNumbering(entityId), listTemplates(entityId), listPolicies(entityId)])
    setS(s.data)
    setN(n)
    setTemplates(t.data)
    setPolicies(p.data)
    if (t.error) setError(t.error)
  }, [entityId])
  useEffect(() => {
    load()
  }, [load])

  async function run(fn: () => Promise<{ error: string | null }>, ok: string) {
    setBusy(true)
    setError(null)
    const r = await fn()
    setBusy(false)
    if (r.error) return setError(r.error)
    setNotice(ok)
    await load()
    onChanged()
  }

  if (!settings || !numbering || !templates || !policies) return <Skeleton rows={4} className="h-20" />
  const active = templates.filter((t) => t.is_active)
  const placeholder = policies.filter((p) => p.body.startsWith('Replace this text'))

  return (
    <div className="space-y-4 pt-2">
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

      <Section
        title="Templates"
        id="setup-templates"
        actions={
          active.length === 0 && (
            <button className="btn-primary min-h-9" disabled={busy} onClick={() => run(() => seedDefaultTemplate(entityId), 'Standard template added with 19 tasks.')}>
              Add standard template
            </button>
          )
        }
      >
        {templates.length === 0 ? (
          <p className="text-sm text-muted">
            The standard UAE café template covers personal details, passport, visa, Emirates ID, bank details, handbook and privacy notice, contract, pay review, branch setup, day one and the day-7 and day-30 check-ins.
          </p>
        ) : (
          <ul className="divide-y divide-border">
            {templates.map((t) => (
              <li key={t.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                <span>
                  <span className="font-medium">{t.name}</span> · version {t.version_number}
                  <span className="block text-xs text-muted">
                    {t.applies_to_position_ids?.length ? 'Specific jobs' : t.applies_to_employment_types?.length ? t.applies_to_employment_types.join(', ').replace(/_/g, ' ') : 'Everyone (default)'}
                  </span>
                </span>
                <span className="flex items-center gap-2">
                  <StatusBadge status={t.is_active ? 'active' : 'inactive'} />
                  <button className="btn-ghost min-h-9" onClick={() => setViewing(t)}>
                    View tasks
                  </button>
                  {t.is_active && (
                    <button
                      className="btn-ghost min-h-9"
                      disabled={busy}
                      onClick={async () => {
                        if (await confirmDialog(`Deactivate “${t.name}”? Onboardings already running keep their copy.`)) run(() => deactivateTemplate(t.id), 'Template deactivated.')
                      }}
                    >
                      Deactivate
                    </button>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
        <p className="text-xs text-muted">Each onboarding keeps a copy of the template it started with, so changes never affect people already onboarding.</p>
      </Section>

      <Section title="Policies employees accept" id="setup-policies">
        {placeholder.length > 0 && <Alert tone="warning">Replace the placeholder text in {placeholder.map((p) => p.title).join(', ')} before inviting anyone.</Alert>}
        {policies.length === 0 ? (
          <p className="text-sm text-muted">Added with the standard template.</p>
        ) : (
          <ul className="divide-y divide-border">
            {policies.map((p) => (
              <li key={p.id} className="flex items-center justify-between gap-2 py-2 text-sm">
                <span>
                  {p.title} <span className="text-xs text-muted">version {p.version}</span>
                </span>
                <button className="btn-ghost min-h-9" onClick={() => setEditingPolicy(p)}>
                  Edit
                </button>
              </li>
            ))}
          </ul>
        )}
      </Section>

      <SettingsCard settings={settings} isOwner={isOwner} busy={busy} onSave={(s) => run(() => setSettings(entityId, s), 'Onboarding rules saved.')} />
      <NumberingCard numbering={numbering} busy={busy} onSave={(n) => run(() => setNumbering(entityId, n.prefix, n.next_value, n.pad_width), 'Employee numbering saved.')} />

      {viewing && <TemplateTasks template={viewing} onClose={() => setViewing(null)} />}
      {editingPolicy && (
        <PolicyEditor
          policy={editingPolicy}
          onClose={() => setEditingPolicy(null)}
          onSave={async (p) => {
            const r = await upsertPolicy(entityId, p.policy_key, p.version, p.title, p.body)
            if (r.error) return r.error
            setEditingPolicy(null)
            setNotice(p.version === editingPolicy.version ? 'Policy updated.' : 'New policy version published. Staff will be asked to accept it.')
            await load()
            return null
          }}
        />
      )}
    </div>
  )
}

function SettingsCard({ settings, isOwner, busy, onSave }: { settings: OnboardingSettings; isOwner: boolean; busy: boolean; onSave: (s: OnboardingSettings) => void }) {
  const [f, setF] = useState(settings)
  useEffect(() => setF(settings), [settings])
  const num = (k: keyof OnboardingSettings, label: string, min: number, max: number, hint?: string) => (
    <label className="block">
      <span className="label">{label}</span>
      <input type="number" className="input" min={min} max={max} value={f[k] as number} onChange={(e) => setF({ ...f, [k]: Number(e.target.value) })} />
      {hint && <span className="mt-1 block text-xs text-muted">{hint}</span>}
    </label>
  )
  return (
    <Section
      title="Rules"
      id="setup-rules"
      actions={
        <button className="btn-primary min-h-9" disabled={busy} onClick={() => onSave(f)}>
          Save rules
        </button>
      }
    >
      <div className="grid gap-3 sm:grid-cols-2">
        {num('probation_months', 'Probation (months)', 0, 6, 'UAE maximum is 6 months.')}
        {num('probation_review_days_before', 'Probation review due (days before end)', 0, 60)}
        {num('invitation_valid_days', 'Invitation valid for (days)', 1, 60)}
        {num('default_task_sla_days', 'Default task deadline (days)', 1, 60)}
      </div>
      <label className="flex items-start gap-2 text-sm">
        <input
          type="checkbox"
          className="mt-1"
          checked={f.require_distinct_activation_approver}
          disabled={!isOwner && f.require_distinct_activation_approver}
          onChange={(e) => setF({ ...f, require_distinct_activation_approver: e.target.checked })}
        />
        <span>
          Activation must be approved by someone who did not enter or review the pay
          {!isOwner && <span className="block text-xs text-muted">Only the owner can turn this off.</span>}
        </span>
      </label>
    </Section>
  )
}

function NumberingCard({
  numbering,
  busy,
  onSave,
}: {
  numbering: { prefix: string; next_value: number; pad_width: number }
  busy: boolean
  onSave: (n: { prefix: string; next_value: number; pad_width: number }) => void
}) {
  const [f, setF] = useState(numbering)
  useEffect(() => setF(numbering), [numbering])
  const preview = `${f.prefix}${String(f.next_value).padStart(f.pad_width, '0')}`
  return (
    <Section
      title="Employee numbers"
      id="setup-numbers"
      actions={
        <button className="btn-primary min-h-9" disabled={busy} onClick={() => onSave(f)}>
          Save numbering
        </button>
      }
    >
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block">
          <span className="label">Prefix</span>
          <input className="input" value={f.prefix} onChange={(e) => setF({ ...f, prefix: e.target.value })} />
        </label>
        <label className="block">
          <span className="label">Next number</span>
          <input type="number" min={1} className="input" value={f.next_value} onChange={(e) => setF({ ...f, next_value: Number(e.target.value) })} />
        </label>
        <label className="block">
          <span className="label">Digits</span>
          <input type="number" min={1} max={10} className="input" value={f.pad_width} onChange={(e) => setF({ ...f, pad_width: Number(e.target.value) })} />
        </label>
      </div>
      <p className="text-sm text-muted">
        Next new starter gets <strong className="text-ink">{preview}</strong>. Numbers already used are skipped.
      </p>
    </Section>
  )
}

function TemplateTasks({ template, onClose }: { template: OnboardingTemplate; onClose: () => void }) {
  const [tasks, setTasks] = useState<Awaited<ReturnType<typeof listTemplateTasks>>['data']>(null)
  useEffect(() => {
    listTemplateTasks(template.id).then((r) => setTasks(r.data))
  }, [template.id])
  return (
    <Modal
      open
      title={`${template.name} — tasks`}
      onClose={onClose}
      footer={
        <button className="btn-secondary" onClick={onClose}>
          Close
        </button>
      }
    >
      {!tasks ? (
        <Skeleton rows={4} className="h-8" />
      ) : (
        <ol className="max-h-[60vh] space-y-2 overflow-y-auto">
          {tasks.map((t) => (
            <li key={t.id} className="text-sm">
              <span className="font-medium text-ink">{t.item_label}</span>
              {!t.is_required && <span className="text-xs text-muted"> (optional)</span>}
              <span className="block text-xs text-muted">
                {PHASE_LABEL[t.phase]} · {SECTION_LABEL[t.section] ?? t.section} · {OWNER_LABEL[t.owner_role]}
                {t.reviewer_role ? ` → ${OWNER_LABEL[t.reviewer_role]}` : ''}
                {t.is_statutory ? ' · required by law' : ''}
              </span>
            </li>
          ))}
        </ol>
      )}
      <p className="text-xs text-muted">Custom templates can be created through the create_onboarding_template API; an in-app editor is not built yet.</p>
    </Modal>
  )
}

function PolicyEditor({ policy, onClose, onSave }: { policy: OnboardingPolicy; onClose: () => void; onSave: (p: OnboardingPolicy) => Promise<string | null> }) {
  const [f, setF] = useState(policy)
  const [newVersion, setNewVersion] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  async function save() {
    if (!f.title.trim() || !f.body.trim()) return setErr('Title and text are required.')
    const version = newVersion ? String((Number(policy.version) || 1) + 1) : policy.version
    const e = await onSave({ ...f, version })
    if (e) setErr(e)
  }
  return (
    <Modal
      open
      title="Edit policy"
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
        <span className="label">Title</span>
        <input className="input" value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} />
      </label>
      <label className="block">
        <span className="label">Text</span>
        <textarea className="input min-h-48" value={f.body} onChange={(e) => setF({ ...f, body: e.target.value })} />
      </label>
      <label className="flex items-start gap-2 text-sm">
        <input type="checkbox" className="mt-1" checked={newVersion} onChange={(e) => setNewVersion(e.target.checked)} />
        <span>Publish as a new version (everyone must accept it again). Leave unticked to fix wording before anyone has accepted.</span>
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}
