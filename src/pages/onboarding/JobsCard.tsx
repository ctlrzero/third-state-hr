import { useCallback, useEffect, useState } from 'react'
import { Alert, Modal, Skeleton } from '../../components/ui'
import { listPositions, upsertPosition, type Position } from '../../lib/api/onboarding'
import { Section } from './shared'

/** Jobs and their descriptions (new starters read the description in the portal). */
export default function JobsCard({ entityId }: { entityId: string }) {
  const [rows, setRows] = useState<Position[] | null>(null)
  const [editing, setEditing] = useState<Position | 'new' | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const load = useCallback(async () => setRows((await listPositions(entityId)).data), [entityId])
  useEffect(() => {
    load()
  }, [load])
  return (
    <Section
      title="Jobs"
      id="setup-jobs"
      actions={
        <button className="btn-secondary min-h-9" onClick={() => setEditing('new')}>
          Add job
        </button>
      }
    >
      {notice && (
        <Alert tone="success" onDismiss={() => setNotice(null)}>
          {notice}
        </Alert>
      )}
      {!rows ? (
        <Skeleton rows={2} className="h-10" />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted">No jobs yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {rows.map((p) => (
            <li key={p.id} className="flex items-center justify-between gap-2 py-2 text-sm">
              <span className="min-w-0">
                <span className="font-medium">{p.title}</span>
                {p.department && <span className="text-muted"> · {p.department}</span>}
                <span className={`block truncate text-xs ${p.description ? 'text-muted' : 'text-brand-warning-solid'}`}>
                  {p.description ?? 'No job description yet'}
                </span>
              </span>
              <button className="btn-ghost min-h-9" onClick={() => setEditing(p)}>
                Edit
              </button>
            </li>
          ))}
        </ul>
      )}
      {editing && (
        <JobEditor
          entityId={entityId}
          job={editing === 'new' ? null : editing}
          onClose={() => setEditing(null)}
          onSaved={(m) => {
            setEditing(null)
            setNotice(m)
            load()
          }}
        />
      )}
    </Section>
  )
}

function JobEditor({ entityId, job, onClose, onSaved }: { entityId: string; job: Position | null; onClose: () => void; onSaved: (m: string) => void }) {
  const [f, setF] = useState({ title: job?.title ?? '', department: job?.department ?? '', description: job?.description ?? '' })
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  async function save() {
    if (!f.title.trim()) return setErr('Job title is required.')
    setBusy(true)
    const r = await upsertPosition(entityId, job?.id ?? null, f.title.trim(), f.department.trim() || null, f.description.trim() || null)
    setBusy(false)
    if (r.error) return setErr(r.error)
    onSaved(job ? 'Job updated.' : 'Job added.')
  }
  return (
    <Modal
      open
      title={job ? `Edit ${job.title}` : 'Add job'}
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
        <span className="label">Title *</span>
        <input className="input" value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} data-autofocus />
      </label>
      <label className="block">
        <span className="label">Department</span>
        <input className="input" value={f.department} onChange={(e) => setF({ ...f, department: e.target.value })} placeholder="Floor, Kitchen, Bar…" />
      </label>
      <label className="block">
        <span className="label">Job description</span>
        <textarea
          className="input min-h-40"
          value={f.description}
          onChange={(e) => setF({ ...f, description: e.target.value })}
          placeholder="Main duties, who they report to, shift pattern, standards expected."
        />
        <span className="mt-1 block text-xs text-muted">New starters see this in their onboarding portal.</span>
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}
