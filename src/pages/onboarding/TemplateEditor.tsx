import { useEffect, useMemo, useState } from 'react'
import { Alert, Drawer, Skeleton } from '../../components/ui'
import {
  createTemplate,
  listPolicies,
  listPositions,
  listTemplateTasks,
  replaceTemplate,
  type OnboardingPolicy,
  type OnboardingTemplate,
  type Position,
  type TemplateTaskInput,
} from '../../lib/api/onboarding'
import { OWNER_LABEL, PHASE_LABEL, SECTION_LABEL, SECTION_ORDER, taskKey, validateTemplateTasks } from '../../lib/onboarding'
import { DOC_TYPES } from '../../lib/documents'
import { EMPLOYMENT_TYPES } from './pickers'

const KINDS: { value: TemplateTaskInput['kind']; label: string; hint: string }[] = [
  { value: 'manual', label: 'Checklist item', hint: 'Someone ticks it off' },
  { value: 'document', label: 'Document upload', hint: 'Done when the document is approved' },
  { value: 'acknowledgement', label: 'Policy to accept', hint: 'Done when the employee accepts the policy' },
  { value: 'profile', label: 'Personal details', hint: 'Done when HR approves the details' },
  { value: 'payment_details', label: 'Bank details', hint: 'Done when payroll verifies them' },
  { value: 'availability', label: 'Weekly availability', hint: 'Done when the employee confirms it' },
  { value: 'contract_acceptance', label: 'Contract acceptance', hint: 'Done when the employee accepts the contract' },
  { value: 'compensation', label: 'Starting pay', hint: 'Done when payroll approves the pay' },
]

type Row = TemplateTaskInput & { _id: string }

let seq = 0
const rid = () => `r${++seq}`

function blankRow(existing: Row[]): Row {
  let key = 'new_task'
  let n = 1
  while (existing.some((r) => r.item_key === key)) key = `new_task_${++n}`
  return {
    _id: rid(),
    item_key: key,
    item_label: '',
    section: 'operations',
    phase: 'pre_activation',
    kind: 'manual',
    owner_role: 'location_manager',
    reviewer_role: null,
    is_required: true,
    is_statutory: false,
    due_offset_days: null,
    depends_on: [],
  }
}

/**
 * Create a template, or edit one (saving creates the next version;
 * onboardings already running keep the copy they started with).
 */
export default function TemplateEditor({
  entityId,
  template,
  copyFrom,
  onClose,
  onSaved,
}: {
  entityId: string
  template: OnboardingTemplate | null
  copyFrom: OnboardingTemplate | null
  onClose: () => void
  onSaved: (msg: string) => void
}) {
  const source = template ?? copyFrom
  const [name, setName] = useState(template?.name ?? (copyFrom ? `${copyFrom.name} (copy)` : ''))
  const [description, setDescription] = useState(source?.description ?? '')
  const [types, setTypes] = useState<string[]>(source?.applies_to_employment_types ?? [])
  const [positionIds, setPositionIds] = useState<string[]>(source?.applies_to_position_ids ?? [])
  const [rows, setRows] = useState<Row[] | null>(source ? null : [])
  const [positions, setPositions] = useState<Position[]>([])
  const [policies, setPolicies] = useState<OnboardingPolicy[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    listPositions(entityId).then((r) => setPositions(r.data ?? []))
    listPolicies(entityId).then((r) => setPolicies(r.data ?? []))
    if (source)
      listTemplateTasks(source.id).then((r) =>
        setRows(
          (r.data ?? []).map((t) => ({
            _id: rid(),
            item_key: t.item_key,
            item_label: t.item_label,
            description: t.description ?? null,
            section: t.section,
            phase: t.phase,
            kind: t.kind,
            owner_role: t.owner_role,
            reviewer_role: t.reviewer_role,
            doc_type: t.doc_type ?? null,
            policy_key: t.policy_key ?? null,
            is_required: t.is_required,
            is_statutory: t.is_statutory,
            due_offset_days: t.due_offset_days,
            depends_on: t.depends_on ?? [],
          }))
        )
      )
  }, [entityId, source])

  const problems = useMemo(() => (rows ? validateTemplateTasks(rows) : []), [rows])

  function update(id: string, patch: Partial<Row>) {
    setRows((rs) => {
      if (!rs) return rs
      const before = rs.find((r) => r._id === id)
      return rs.map((r) => {
        if (r._id === id) return { ...r, ...patch }
        // Keep "waits for" links when a key is renamed.
        if (patch.item_key && before && r.depends_on.includes(before.item_key))
          return { ...r, depends_on: r.depends_on.map((d) => (d === before.item_key ? patch.item_key! : d)) }
        return r
      })
    })
  }
  function move(id: string, dir: -1 | 1) {
    setRows((rs) => {
      if (!rs) return rs
      const i = rs.findIndex((r) => r._id === id)
      const j = i + dir
      if (j < 0 || j >= rs.length) return rs
      const next = [...rs]
      ;[next[i], next[j]] = [next[j], next[i]]
      return next
    })
  }
  function remove(id: string) {
    setRows((rs) => {
      if (!rs) return rs
      const gone = rs.find((r) => r._id === id)?.item_key
      return rs.filter((r) => r._id !== id).map((r) => ({ ...r, depends_on: r.depends_on.filter((d) => d !== gone) }))
    })
  }

  async function save() {
    if (!rows) return
    if (!name.trim()) return setError('Give the template a name.')
    if (problems.length) return setError(problems[0])
    setBusy(true)
    setError(null)
    const tasks: TemplateTaskInput[] = rows.map(({ _id, ...t }, i) => {
      void _id
      return {
        ...t,
        item_label: t.item_label.trim(),
        reviewer_role: t.reviewer_role || null,
        doc_type: t.kind === 'document' ? t.doc_type : null,
        policy_key: t.kind === 'acknowledgement' ? t.policy_key : null,
        is_waivable: !t.is_statutory,
        sort_order: i + 1,
      }
    })
    const res = template
      ? await replaceTemplate(template.id, name.trim(), description.trim() || null, tasks, types, positionIds)
      : await createTemplate(entityId, name.trim(), description.trim() || null, tasks, types.length ? types : null, positionIds.length ? positionIds : null)
    setBusy(false)
    if (res.error) return setError(res.error)
    onSaved(template ? `Saved as version ${template.version_number + 1}.` : 'Template created.')
  }

  const keys = rows?.map((r) => r.item_key) ?? []

  return (
    <Drawer
      open
      wide
      title={template ? `Edit “${template.name}”` : 'New onboarding template'}
      description={template ? 'Saving creates a new version. People already onboarding keep their current checklist.' : undefined}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save} disabled={busy || !rows}>
            {busy ? 'Saving…' : template ? 'Save new version' : 'Create template'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        {error && (
          <Alert tone="error" onDismiss={() => setError(null)}>
            {error}
          </Alert>
        )}
        <label className="block">
          <span className="label">Name *</span>
          <input className="input" value={name} onChange={(e) => setName(e.target.value)} />
        </label>
        <label className="block">
          <span className="label">Description</span>
          <input className="input" value={description} onChange={(e) => setDescription(e.target.value)} />
        </label>

        <fieldset className="card space-y-2">
          <legend className="px-1 text-sm font-semibold text-ink">Used for</legend>
          <p className="text-xs text-muted">Leave both empty to use it for everyone. The most specific template wins: job first, then employment type.</p>
          <div className="flex flex-wrap gap-3">
            {EMPLOYMENT_TYPES.map((t) => (
              <label key={t.value} className="flex items-center gap-1.5 text-sm">
                <input type="checkbox" checked={types.includes(t.value)} onChange={(e) => setTypes(e.target.checked ? [...types, t.value] : types.filter((x) => x !== t.value))} />
                {t.label}
              </label>
            ))}
          </div>
          {positions.length > 0 && (
            <div className="flex flex-wrap gap-3">
              {positions.map((p) => (
                <label key={p.id} className="flex items-center gap-1.5 text-sm">
                  <input
                    type="checkbox"
                    checked={positionIds.includes(p.id)}
                    onChange={(e) => setPositionIds(e.target.checked ? [...positionIds, p.id] : positionIds.filter((x) => x !== p.id))}
                  />
                  {p.title}
                </label>
              ))}
            </div>
          )}
        </fieldset>

        {!rows ? (
          <Skeleton rows={4} className="h-24" />
        ) : (
          <ol className="space-y-3">
            {rows.map((r, i) => (
              <li key={r._id} className="card space-y-3">
                <div className="flex items-start gap-2">
                  <span className="mt-2 text-xs font-semibold text-muted">{i + 1}.</span>
                  <label className="flex-1">
                    <span className="sr-only">Task name</span>
                    <input
                      className="input font-medium"
                      placeholder="What needs to happen"
                      value={r.item_label}
                      onChange={(e) => {
                        const label = e.target.value
                        const auto = !r.item_label || r.item_key === taskKey(r.item_label) || r.item_key.startsWith('new_task')
                        update(r._id, auto ? { item_label: label, item_key: taskKey(label) } : { item_label: label })
                      }}
                    />
                  </label>
                  <span className="flex gap-1">
                    <button type="button" className="btn-ghost min-h-9 px-2" aria-label="Move up" onClick={() => move(r._id, -1)} disabled={i === 0}>
                      ↑
                    </button>
                    <button type="button" className="btn-ghost min-h-9 px-2" aria-label="Move down" onClick={() => move(r._id, 1)} disabled={i === rows.length - 1}>
                      ↓
                    </button>
                    <button type="button" className="btn-ghost min-h-9 px-2 text-brand-risk-text" aria-label="Remove task" onClick={() => remove(r._id)}>
                      ✕
                    </button>
                  </span>
                </div>
                <div className="grid gap-2 sm:grid-cols-3">
                  <Sel label="Type" value={r.kind} onChange={(v) => update(r._id, { kind: v as Row['kind'] })} options={KINDS.map((k) => [k.value, k.label])} />
                  {r.kind === 'document' && (
                    <Sel label="Document" value={r.doc_type ?? ''} onChange={(v) => update(r._id, { doc_type: v || null })} options={[['', 'Choose…'], ...DOC_TYPES.map((d) => [d.value, d.label] as [string, string])]} />
                  )}
                  {r.kind === 'acknowledgement' && (
                    <Sel label="Policy" value={r.policy_key ?? ''} onChange={(v) => update(r._id, { policy_key: v || null })} options={[['', 'Choose…'], ...policies.map((p) => [p.policy_key, p.title] as [string, string])]} />
                  )}
                  <Sel label="When" value={r.phase} onChange={(v) => update(r._id, { phase: v as Row['phase'] })} options={Object.entries(PHASE_LABEL)} />
                  <Sel label="Section" value={r.section} onChange={(v) => update(r._id, { section: v })} options={SECTION_ORDER.map((s) => [s, SECTION_LABEL[s]])} />
                  <Sel label="Done by" value={r.owner_role} onChange={(v) => update(r._id, { owner_role: v as Row['owner_role'] })} options={Object.entries(OWNER_LABEL)} />
                  <Sel
                    label="Checked by"
                    value={r.reviewer_role ?? ''}
                    onChange={(v) => update(r._id, { reviewer_role: (v || null) as Row['reviewer_role'] })}
                    options={[['', 'No check'], ['location_manager', 'Branch manager'], ['hr', 'HR'], ['payroll', 'Payroll']]}
                  />
                  <label className="block">
                    <span className="label text-xs">Due after (days)</span>
                    <input
                      type="number"
                      min={0}
                      className="input"
                      value={r.due_offset_days ?? ''}
                      placeholder="Default"
                      onChange={(e) => update(r._id, { due_offset_days: e.target.value === '' ? null : Number(e.target.value) })}
                    />
                  </label>
                </div>
                <p className="text-xs text-muted">
                  {KINDS.find((k) => k.value === r.kind)?.hint}. Due days count from the onboarding start ({PHASE_LABEL.pre_activation.toLowerCase()}) or the start date (after start).
                </p>
                <div className="flex flex-wrap items-center gap-4 text-sm">
                  <label className="flex items-center gap-1.5">
                    <input type="checkbox" checked={r.is_required} onChange={(e) => update(r._id, { is_required: e.target.checked })} /> Required
                  </label>
                  <label className="flex items-center gap-1.5">
                    <input type="checkbox" checked={r.is_statutory} onChange={(e) => update(r._id, { is_statutory: e.target.checked, is_required: e.target.checked || r.is_required })} /> Required
                    by law (cannot be waived)
                  </label>
                  {keys.filter((k) => k !== r.item_key).length > 0 && (
                    <details className="text-sm">
                      <summary className="cursor-pointer text-brand-blue">Waits for {r.depends_on.length ? `(${r.depends_on.length})` : ''}</summary>
                      <div className="mt-1 flex flex-wrap gap-3">
                        {rows
                          .filter((o) => o._id !== r._id)
                          .map((o) => (
                            <label key={o._id} className="flex items-center gap-1.5">
                              <input
                                type="checkbox"
                                checked={r.depends_on.includes(o.item_key)}
                                onChange={(e) =>
                                  update(r._id, { depends_on: e.target.checked ? [...r.depends_on, o.item_key] : r.depends_on.filter((d) => d !== o.item_key) })
                                }
                              />
                              {o.item_label || o.item_key}
                            </label>
                          ))}
                      </div>
                    </details>
                  )}
                </div>
              </li>
            ))}
          </ol>
        )}
        <button type="button" className="btn-secondary" onClick={() => setRows((rs) => [...(rs ?? []), blankRow(rs ?? [])])}>
          Add task
        </button>
        {problems.length > 0 && rows && rows.length > 0 && (
          <Alert tone="warning">
            <ul className="list-disc pl-4">
              {problems.map((p) => (
                <li key={p}>{p}</li>
              ))}
            </ul>
          </Alert>
        )}
        <p className="text-xs text-muted">
          Key documents (passport, visa, Emirates ID, contract), approved starting pay and contract acceptance are always checked before activation, even if a template leaves them out.
        </p>
      </div>
    </Drawer>
  )
}

function Sel({ label, value, onChange, options }: { label: string; value: string; onChange: (v: string) => void; options: [string, string][] }) {
  return (
    <label className="block">
      <span className="label text-xs">{label}</span>
      <select className="input" value={value} onChange={(e) => onChange(e.target.value)}>
        {options.map(([v, l]) => (
          <option key={v} value={v}>
            {l}
          </option>
        ))}
      </select>
    </label>
  )
}
