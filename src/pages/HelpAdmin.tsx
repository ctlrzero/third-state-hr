import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { HelpMarkdown } from '../components/HelpMarkdown'
import { StatusBadge } from '../components/StatusBadge'
import { Alert, Drawer, Field, Modal, PageHeader, Skeleton } from '../components/ui'
import {
  helpAdminGet,
  helpAdminList,
  helpAdminMarkReviewed,
  helpAdminPublish,
  helpAdminRestore,
  helpAdminSaveDraft,
  helpAdminVersions,
  helpUploadShot,
  type HelpAdminRow,
  type HelpFields,
  type HelpVersion,
} from '../lib/api/help'
import { HELP_ALL_ROLES, HELP_CATEGORIES, HELP_ROLE_LABEL, isReviewDue } from '../lib/help'
import { fmtDate, fmtDateTime } from '../lib/format'
import { ArticleView } from './HelpArticle'

const EMPTY: HelpFields = { title: '', category: 'employee', audience: ['staff'], summary: '', body_md: '', related: [], route: null }

function ReviewBadge({ date }: { date: string | null }) {
  return isReviewDue(date) ? <StatusBadge status="Review due" tone="warning" /> : null
}

export default function HelpAdmin() {
  const [rows, setRows] = useState<HelpAdminRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [slug, setSlug] = useState<string | null>(null)
  const [isNew, setIsNew] = useState(false)

  const reload = useCallback(async () => {
    const r = await helpAdminList()
    if (r.error) setError(r.error)
    setRows(r.data ?? [])
  }, [])
  useEffect(() => {
    reload()
  }, [reload])

  return (
    <div className="space-y-4">
      <PageHeader
        title="Manage help articles"
        description="Write, preview and publish the guides people see in Help & Guides."
        actions={
          <>
            <Link to="/help" className="btn-secondary">
              Back to Help
            </Link>
            <button
              type="button"
              className="btn-primary"
              onClick={() => {
                setIsNew(true)
                setSlug('')
              }}
            >
              New article
            </button>
          </>
        }
      />
      {error && <Alert tone="error" onDismiss={() => setError(null)}>{error}</Alert>}
      {notice && <Alert tone="success" onDismiss={() => setNotice(null)}>{notice}</Alert>}

      <div className="grid gap-4 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <aside aria-label="Articles" className={`${slug !== null ? 'hidden lg:block' : ''}`}>
          {!rows ? (
            <Skeleton rows={5} className="h-14" />
          ) : (
            <ul className="space-y-2">
              {rows.map((r) => (
                <li key={r.slug}>
                  <button
                    type="button"
                    onClick={() => {
                      setIsNew(false)
                      setSlug(r.slug)
                    }}
                    aria-current={slug === r.slug ? 'true' : undefined}
                    className={`block min-h-11 w-full rounded-xl border px-3 py-2.5 text-left focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-blue ${
                      slug === r.slug ? 'border-brand-blue bg-brand-blue-soft' : 'border-border bg-surface hover:border-brand-blue'
                    }`}
                  >
                    <span className="block text-sm font-semibold text-ink">{r.title}</span>
                    <span className="mt-1.5 flex flex-wrap gap-1.5">
                      <StatusBadge status={r.status} />
                      {r.has_draft && r.status === 'published' && <StatusBadge status="Unpublished changes" tone="info" />}
                      <ReviewBadge date={r.last_reviewed} />
                    </span>
                  </button>
                </li>
              ))}
              {rows.length === 0 && <li className="text-sm text-muted">No articles yet. Choose “New article” to start.</li>}
            </ul>
          )}
        </aside>

        <section aria-label="Editor" className={slug === null ? 'hidden lg:block' : ''}>
          {slug === null ? (
            <p className="rounded-[14px] border border-dashed border-border bg-surface px-6 py-10 text-center text-sm text-muted">
              Choose an article on the left to edit it.
            </p>
          ) : (
            <Editor
              key={isNew ? 'new' : slug}
              slug={slug}
              isNew={isNew}
              onBack={() => setSlug(null)}
              onChanged={async (msg, newSlug) => {
                setNotice(msg)
                if (newSlug) {
                  setIsNew(false)
                  setSlug(newSlug)
                }
                await reload()
              }}
            />
          )}
        </section>
      </div>
    </div>
  )
}

function Editor({
  slug: initialSlug,
  isNew,
  onBack,
  onChanged,
}: {
  slug: string
  isNew: boolean
  onBack: () => void
  onChanged: (msg: string, newSlug?: string) => Promise<void>
}) {
  const [slug, setSlug] = useState(initialSlug)
  const [f, setF] = useState<HelpFields | null>(isNew ? EMPTY : null)
  const [meta, setMeta] = useState<{ status: string; last_reviewed: string | null; current_version: number; hasDraft: boolean } | null>(null)
  const [relatedText, setRelatedText] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [mode, setMode] = useState<'edit' | 'preview'>('edit')
  const [publishOpen, setPublishOpen] = useState(false)
  const [note, setNote] = useState('')
  const [historyOpen, setHistoryOpen] = useState(false)
  const [shotKeyName, setShotKeyName] = useState('')
  const [shotAlt, setShotAlt] = useState('')
  const bodyRef = useRef<HTMLTextAreaElement>(null)

  const load = useCallback(async () => {
    if (isNew) return
    const r = await helpAdminGet(initialSlug)
    if (r.error || !r.data) return setError(r.error ?? 'Could not open this article.')
    const fields = r.data.draft ?? r.data.live
    setF(fields)
    setRelatedText(fields.related.join(', '))
    setMeta({ status: r.data.status, last_reviewed: r.data.last_reviewed, current_version: r.data.current_version, hasDraft: Boolean(r.data.draft) })
    setDirty(false)
  }, [initialSlug, isNew])
  useEffect(() => {
    load()
  }, [load])

  if (!f) return error ? <Alert tone="error">{error}</Alert> : <Skeleton rows={6} className="h-12" />

  const set = (patch: Partial<HelpFields>) => {
    setF({ ...f, ...patch })
    setDirty(true)
  }
  const current = (): HelpFields => ({
    ...f,
    related: relatedText.split(',').map((s) => s.trim()).filter(Boolean),
    route: f.route?.trim() ? f.route.trim() : null,
  })

  async function save(): Promise<boolean> {
    setBusy(true)
    setError(null)
    const r = await helpAdminSaveDraft(slug, current())
    setBusy(false)
    if (r.error) {
      setError(r.error)
      return false
    }
    setDirty(false)
    await onChanged('Draft saved.', isNew ? slug : undefined)
    if (!isNew) await load()
    return true
  }

  async function publish() {
    if (dirty && !(await save())) return
    setBusy(true)
    const r = await helpAdminPublish(slug, note)
    setBusy(false)
    if (r.error) {
      setPublishOpen(false)
      return setError(r.error)
    }
    setPublishOpen(false)
    setNote('')
    await onChanged(`Published as version ${r.data?.version}.`)
    await load()
  }

  async function markReviewed() {
    setBusy(true)
    const r = await helpAdminMarkReviewed(slug)
    setBusy(false)
    if (r.error) return setError(r.error)
    await onChanged('Marked as reviewed today.')
    await load()
  }

  async function upload(file: File | undefined) {
    if (!file) return
    const key = shotKeyName.trim() || file.name.replace(/\.[^.]+$/, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
    setBusy(true)
    const r = await helpUploadShot(file, key)
    setBusy(false)
    if (r.error) return setError(r.error)
    setShotKeyName(key)
  }

  function insertSnippet() {
    const key = shotKeyName.trim()
    if (!key) return
    const snippet = `\n![${shotAlt.trim() || 'Describe the picture'}](shot:${key} "1. First part | 2. Second part")\n`
    const el = bodyRef.current
    const at = el ? el.selectionStart : f!.body_md.length
    set({ body_md: f!.body_md.slice(0, at) + snippet + f!.body_md.slice(at) })
  }

  const unsavedNote = dirty ? 'You have unsaved changes.' : meta?.hasDraft ? 'This article has unpublished changes.' : null

  return (
    <div className="space-y-4 rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" className="btn-ghost lg:hidden" onClick={onBack}>
          ← Articles
        </button>
        {meta && <StatusBadge status={meta.status} />}
        {meta && <ReviewBadge date={meta.last_reviewed} />}
        {meta && (
          <span className="text-xs text-muted">
            {meta.current_version > 0 ? `Version ${meta.current_version} · ` : ''}Last reviewed {fmtDate(meta.last_reviewed)}
          </span>
        )}
      </div>
      {error && <Alert tone="error" onDismiss={() => setError(null)}>{error}</Alert>}
      {unsavedNote && <p className="text-xs font-medium text-brand-warning-solid">{unsavedNote}</p>}

      <div className="flex flex-wrap gap-2" role="toolbar" aria-label="Article actions">
        <button type="button" className="btn-primary" disabled={busy || !f.title.trim()} onClick={save}>
          Save draft
        </button>
        <button type="button" className="btn-secondary" aria-pressed={mode === 'preview'} onClick={() => setMode(mode === 'preview' ? 'edit' : 'preview')}>
          {mode === 'preview' ? 'Back to editing' : 'Preview'}
        </button>
        <button type="button" className="btn-secondary" disabled={busy || !f.title.trim()} onClick={() => setPublishOpen(true)}>
          Publish
        </button>
        {!isNew && (
          <>
            <button type="button" className="btn-secondary" onClick={() => setHistoryOpen(true)}>
              Version history
            </button>
            <button type="button" className="btn-secondary" disabled={busy || meta?.status !== 'published'} onClick={markReviewed}>
              Mark as reviewed
            </button>
          </>
        )}
      </div>

      {mode === 'preview' ? (
        <div className="rounded-xl border border-border bg-surface-alt p-4">
          <p className="mb-3 text-xs font-medium text-muted">Preview: this is how readers will see it.</p>
          <ArticleView
            article={{ ...current(), category: f.category, last_reviewed: meta?.last_reviewed ?? null, route: current().route }}
            related={current().related.map((s) => ({ slug: s, title: s, category: 'employee' as const, audience: [], summary: '', related: [], route: null, last_reviewed: null }))}
          />
        </div>
      ) : (
        <div className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Web address (slug)" required hint={isNew ? 'Lowercase letters, numbers and dashes. It cannot be changed later.' : undefined}>
              {(p) => <input {...p} className="input min-h-11 w-full" value={slug} disabled={!isNew} onChange={(e) => { setSlug(e.target.value.toLowerCase()); setDirty(true) }} />}
            </Field>
            <Field label="Title" required>
              {(p) => <input {...p} className="input min-h-11 w-full" value={f.title} onChange={(e) => set({ title: e.target.value })} />}
            </Field>
            <Field label="Topic">
              {(p) => (
                <select {...p} className="input min-h-11 w-full" value={f.category} onChange={(e) => set({ category: e.target.value })}>
                  {HELP_CATEGORIES.map((c) => <option key={c.key} value={c.key}>{c.label}</option>)}
                </select>
              )}
            </Field>
            <Field label="Screen it explains (optional)" hint="For example /leave">
              {(p) => <input {...p} className="input min-h-11 w-full" value={f.route ?? ''} onChange={(e) => set({ route: e.target.value })} />}
            </Field>
          </div>
          <Field label="Short summary">
            {(p) => <input {...p} className="input min-h-11 w-full" value={f.summary} onChange={(e) => set({ summary: e.target.value })} />}
          </Field>
          <fieldset>
            <legend className="label">Who can read it</legend>
            <div className="flex flex-wrap gap-x-4">
              {HELP_ALL_ROLES.map((role) => (
                <label key={role} className="flex min-h-11 items-center gap-2 text-sm text-ink">
                  <input
                    type="checkbox"
                    className="h-5 w-5"
                    checked={f.audience.includes(role)}
                    onChange={(e) => set({ audience: e.target.checked ? [...f.audience, role] : f.audience.filter((x) => x !== role) })}
                  />
                  {HELP_ROLE_LABEL[role]}
                </label>
              ))}
            </div>
            <p className="text-xs text-muted">Owners and Company Admins can always read every published article.</p>
          </fieldset>
          <Field label="Related guides" hint="Web addresses of other articles, separated by commas.">
            {(p) => <input {...p} className="input min-h-11 w-full" value={relatedText} onChange={(e) => { setRelatedText(e.target.value); setDirty(true) }} />}
          </Field>

          <div className="rounded-xl border border-border bg-surface-alt p-3">
            <p className="text-sm font-semibold text-ink">Add a screenshot</p>
            <div className="mt-2 grid gap-3 sm:grid-cols-[1fr_1fr_auto]">
              <Field label="Picture name">
                {(p) => <input {...p} className="input min-h-11 w-full" value={shotKeyName} placeholder="leave-request-form" onChange={(e) => setShotKeyName(e.target.value)} />}
              </Field>
              <Field label="What it shows">
                {(p) => <input {...p} className="input min-h-11 w-full" value={shotAlt} onChange={(e) => setShotAlt(e.target.value)} />}
              </Field>
              <div className="flex items-end">
                <button type="button" className="btn-secondary" disabled={!shotKeyName.trim()} onClick={insertSnippet}>
                  Insert into text
                </button>
              </div>
            </div>
            <label className="mt-3 block text-sm text-ink">
              <span className="label">Upload a PNG or JPG</span>
              <input type="file" accept="image/png,image/jpeg" className="block min-h-11 w-full text-sm" disabled={busy} onChange={(e) => { upload(e.target.files?.[0]); e.target.value = '' }} />
            </label>
            <p className="mt-1 text-xs text-muted">Numbered parts go in the quotes after the picture name, like “1. Tap Clock in | 2. Wait for the tick”.</p>
          </div>

          <div className="grid gap-4 xl:grid-cols-2">
            <Field label="Article text (Markdown)">
              {(p) => (
                <textarea {...p} ref={bodyRef} rows={22} className="input w-full font-mono text-[13px] leading-6" value={f.body_md} onChange={(e) => set({ body_md: e.target.value })} />
              )}
            </Field>
            <div>
              <p className="label">Live preview</p>
              <div className="max-h-[36rem] overflow-y-auto rounded-xl border border-border bg-surface p-4">
                <HelpMarkdown source={f.body_md} />
              </div>
            </div>
          </div>
        </div>
      )}

      <Modal
        open={publishOpen}
        title="Publish this article"
        onClose={() => setPublishOpen(false)}
        footer={
          <>
            <button type="button" className="btn-secondary" onClick={() => setPublishOpen(false)}>
              Cancel
            </button>
            <button type="button" className="btn-primary" disabled={busy || !note.trim()} onClick={publish}>
              Publish
            </button>
          </>
        }
      >
        <p>Readers will see this version straight away. It also marks the article as reviewed today.</p>
        <Field label="What changed?" required hint="A short note for the version history.">
          {(p) => <input {...p} data-autofocus className="input min-h-11 w-full" value={note} onChange={(e) => setNote(e.target.value)} />}
        </Field>
      </Modal>

      <HistoryDrawer
        open={historyOpen}
        slug={slug}
        onClose={() => setHistoryOpen(false)}
        onRestored={async () => {
          setHistoryOpen(false)
          await onChanged('Version restored into a draft. Review it, then publish.')
          await load()
        }}
      />
    </div>
  )
}

function HistoryDrawer({ open, slug, onClose, onRestored }: { open: boolean; slug: string; onClose: () => void; onRestored: () => void }) {
  const [versions, setVersions] = useState<HelpVersion[] | null>(null)
  const [viewing, setViewing] = useState<HelpVersion | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    if (!open) return
    setViewing(null)
    setVersions(null)
    helpAdminVersions(slug).then((r) => {
      if (r.error) setError(r.error)
      setVersions(r.data ?? [])
    })
  }, [open, slug])

  async function restore(v: HelpVersion) {
    const r = await helpAdminRestore(slug, v.version)
    if (r.error) return setError(r.error)
    onRestored()
  }

  return (
    <Drawer open={open} wide title={viewing ? `Version ${viewing.version}` : 'Version history'} onClose={onClose}>
      {error && <Alert tone="error" onDismiss={() => setError(null)}>{error}</Alert>}
      {viewing ? (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            <button type="button" className="btn-secondary" onClick={() => setViewing(null)}>
              Back to list
            </button>
            <button type="button" className="btn-primary" onClick={() => restore(viewing)}>
              Restore as draft
            </button>
          </div>
          <h3 className="text-base font-semibold text-ink">{viewing.snapshot.title}</h3>
          <HelpMarkdown source={viewing.snapshot.body_md} />
        </div>
      ) : !versions ? (
        <Skeleton rows={3} />
      ) : versions.length === 0 ? (
        <p className="text-sm text-muted">This article has not been published yet.</p>
      ) : (
        <ul className="space-y-2">
          {versions.map((v) => (
            <li key={v.version} className="rounded-xl border border-border p-3">
              <p className="text-sm font-semibold text-ink">Version {v.version}</p>
              <p className="text-xs text-muted">
                {fmtDateTime(v.created_at)}
                {v.created_by_name ? ` · ${v.created_by_name}` : ''}
              </p>
              {v.change_note && <p className="mt-1 text-sm text-ink">{v.change_note}</p>}
              <div className="mt-2 flex gap-2">
                <button type="button" className="btn-secondary" onClick={() => setViewing(v)}>
                  View
                </button>
                <button type="button" className="btn-secondary" onClick={() => restore(v)}>
                  Restore as draft
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </Drawer>
  )
}
