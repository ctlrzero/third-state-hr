import { useCallback, useEffect, useState } from 'react'
import { StatusBadge } from '../../components/StatusBadge'
import { EmptyState } from '../../components/EmptyState'
import { Alert, Drawer, Field, Modal, Skeleton } from '../../components/ui'
import {
  adminUpsertEntity,
  adminUpsertLocation,
  getEntityDependencySummary,
  listEntities,
  listLocations,
  type DependencySummary,
  type EntityInput,
  type EntityRow,
  type LocationInput,
  type LocationRow,
} from '../../lib/api/admin'
import { useAuth } from '../../auth/AuthContext'

const EMIRATES = ['Abu Dhabi', 'Dubai', 'Sharjah', 'Ajman', 'Umm Al Quwain', 'Ras Al Khaimah', 'Fujairah']

const DEP_LABEL: Record<keyof DependencySummary, string> = {
  active_employees: 'Active employees',
  future_shifts: 'Future shifts',
  open_leave_requests: 'Open leave requests',
  draft_payroll_runs: 'Draft payroll runs',
}

type Editing =
  | { kind: 'entity'; row: EntityRow | null }
  | { kind: 'location'; row: LocationRow | null; entityId: string }

export function EntitiesTab({ isOwner }: { isOwner: boolean }) {
  const { refreshProfile } = useAuth()
  const [entities, setEntities] = useState<EntityRow[] | null>(null)
  const [locations, setLocations] = useState<LocationRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [editing, setEditing] = useState<Editing | null>(null)

  const load = useCallback(async () => {
    const [e, l] = await Promise.all([listEntities(), listLocations(null)])
    if (e.error || l.error) setError(e.error ?? l.error)
    setEntities(e.data ?? [])
    setLocations(l.data ?? [])
  }, [])

  useEffect(() => {
    load()
  }, [load])

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm text-muted">
          {isOwner
            ? 'Entities and branches are never deleted — inactivate them instead so history stays intact.'
            : 'Entity details are managed by the Owner. You can manage branches for your entity.'}
        </p>
        {isOwner && (
          <button className="btn-primary" onClick={() => setEditing({ kind: 'entity', row: null })}>
            New entity
          </button>
        )}
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
      {entities === null ? (
        <Skeleton rows={2} className="h-32" />
      ) : entities.length === 0 ? (
        <EmptyState title="No entities" />
      ) : (
        entities.map((ent) => {
          const branches = locations.filter((l) => l.entity_id === ent.id)
          return (
            <section key={ent.id} className="card space-y-3" aria-label={ent.name}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <h3 className="text-base font-semibold text-ink">
                    {ent.name} {ent.code && <span className="text-sm font-normal text-muted">· {ent.code}</span>}
                  </h3>
                  <p className="text-sm text-muted">
                    {[ent.emirate, ent.trade_license_no && `Licence ${ent.trade_license_no}`, ent.default_currency, ent.payroll_day && `Payroll day ${ent.payroll_day}`]
                      .filter(Boolean)
                      .join(' · ') || 'No details yet'}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <StatusBadge status={ent.is_active === false ? 'inactive' : 'active'} />
                  {isOwner && (
                    <button className="btn-secondary" onClick={() => setEditing({ kind: 'entity', row: ent })} aria-label={`Edit ${ent.name}`}>
                      Edit
                    </button>
                  )}
                </div>
              </div>
              <div>
                <div className="mb-2 flex items-center justify-between">
                  <h4 className="text-sm font-semibold text-ink">Branches ({branches.length})</h4>
                  <button className="btn-ghost" onClick={() => setEditing({ kind: 'location', row: null, entityId: ent.id })}>
                    Add branch
                  </button>
                </div>
                {branches.length === 0 ? (
                  <p className="text-sm text-muted">No branches yet.</p>
                ) : (
                  <ul className="divide-y divide-border rounded-lg border border-border">
                    {branches.map((b) => (
                      <li key={b.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
                        <span className="min-w-0">
                          <span className="font-medium text-ink">{b.name}</span>
                          {b.code && <span className="ml-1 text-sm text-muted">· {b.code}</span>}
                          {b.address && <span className="block text-sm text-muted">{b.address}</span>}
                        </span>
                        <span className="flex items-center gap-2">
                          <StatusBadge status={b.is_active === false ? 'inactive' : 'active'} />
                          <button
                            className="btn-secondary"
                            onClick={() => setEditing({ kind: 'location', row: b, entityId: ent.id })}
                            aria-label={`Edit ${b.name}`}
                          >
                            Edit
                          </button>
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </section>
          )
        })
      )}

      {editing?.kind === 'entity' && (
        <EntityDrawer
          row={editing.row}
          onClose={() => setEditing(null)}
          onSaved={(msg) => {
            setEditing(null)
            setNotice(msg)
            load()
            refreshProfile()
          }}
        />
      )}
      {editing?.kind === 'location' && (
        <LocationDrawer
          row={editing.row}
          entityId={editing.entityId}
          onClose={() => setEditing(null)}
          onSaved={(msg) => {
            setEditing(null)
            setNotice(msg)
            load()
          }}
        />
      )}
    </div>
  )
}

/** Confirmation that shows what still depends on the entity/branch before inactivating. */
function InactivateConfirm({
  target,
  entityId,
  locationId,
  onCancel,
  onConfirm,
  saving,
}: {
  target: string
  entityId: string | null
  locationId: string | null
  onCancel: () => void
  onConfirm: () => void
  saving: boolean
}) {
  const [summary, setSummary] = useState<DependencySummary | null>(null)
  const [state, setState] = useState<'loading' | 'ready' | 'unavailable' | 'error'>('loading')
  useEffect(() => {
    getEntityDependencySummary(entityId, locationId).then((res) => {
      if (res.notAvailable) setState('unavailable')
      else if (res.error) setState('error')
      else {
        setSummary(res.data)
        setState('ready')
      }
    })
  }, [entityId, locationId])
  const blocking = summary ? Object.values(summary).some((n) => Number(n) > 0) : false
  return (
    <Modal
      open
      title={`Inactivate ${target}?`}
      onClose={onCancel}
      footer={
        <>
          <button className="btn-secondary" onClick={onCancel}>
            Keep active
          </button>
          <button className="btn-danger" onClick={onConfirm} disabled={saving || state === 'loading'}>
            {saving ? 'Saving…' : 'Inactivate'}
          </button>
        </>
      }
    >
      <p>Nothing is deleted. It will be hidden from new schedules, hires and payroll runs.</p>
      {state === 'loading' && <Skeleton rows={1} className="h-16" />}
      {state === 'unavailable' && <Alert tone="warning">The dependency check isn't available yet — review open items manually first.</Alert>}
      {state === 'error' && <Alert tone="warning">Couldn't load the dependency summary.</Alert>}
      {summary && (
        <>
          <dl className="grid grid-cols-2 gap-2">
            {(Object.keys(DEP_LABEL) as (keyof DependencySummary)[]).map((k) => (
              <div key={k} className={`rounded-lg p-2 ${Number(summary[k]) > 0 ? 'bg-brand-warning-soft' : 'bg-surface-alt'}`}>
                <dt className="text-xs text-muted">{DEP_LABEL[k]}</dt>
                <dd className="text-lg font-semibold">{summary[k] ?? 0}</dd>
              </div>
            ))}
          </dl>
          {blocking && <p className="text-brand-warning-solid">Resolve or reassign these items first where possible.</p>}
        </>
      )}
    </Modal>
  )
}

function EntityDrawer({ row, onClose, onSaved }: { row: EntityRow | null; onClose: () => void; onSaved: (msg: string) => void }) {
  const [form, setForm] = useState<EntityInput>({
    id: row?.id ?? null,
    name: row?.name ?? '',
    code: row?.code ?? '',
    trade_license_no: row?.trade_license_no ?? '',
    emirate: row?.emirate ?? 'Dubai',
    default_currency: row?.default_currency ?? 'AED',
    payroll_day: row?.payroll_day ?? 28,
    is_active: row?.is_active ?? true,
  })
  const [errors, setErrors] = useState<Partial<Record<keyof EntityInput, string>>>({})
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)

  function set<K extends keyof EntityInput>(k: K, v: EntityInput[K]) {
    setForm((f) => ({ ...f, [k]: v }))
  }

  function validate() {
    const e: typeof errors = {}
    if (!form.name.trim()) e.name = 'Name is required.'
    if (form.code && !/^[A-Za-z0-9_-]{2,12}$/.test(form.code)) e.code = 'Use 2–12 letters, numbers, - or _.'
    if (form.payroll_day != null && (form.payroll_day < 1 || form.payroll_day > 28)) e.payroll_day = 'Choose a day between 1 and 28.'
    if (!/^[A-Z]{3}$/.test(form.default_currency)) e.default_currency = 'Use a 3-letter currency code, e.g. AED.'
    setErrors(e)
    return Object.keys(e).length === 0
  }

  async function persist() {
    setSaving(true)
    setServerError(null)
    const res = await adminUpsertEntity({ ...form, name: form.name.trim(), code: form.code.trim().toUpperCase() })
    setSaving(false)
    setConfirming(false)
    if (res.notAvailable) return setServerError('Editing entities is not available yet.')
    if (res.error) return setServerError(res.error)
    onSaved(row ? `${form.name} updated.` : `${form.name} created.`)
  }

  function submit() {
    if (!validate()) return
    if (row && row.is_active !== false && !form.is_active) setConfirming(true)
    else persist()
  }

  return (
    <Drawer
      open
      title={row ? `Edit ${row.name}` : 'New entity'}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={saving}>
            {saving ? 'Saving…' : 'Save'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Legal / trading name" error={errors.name} required>
          {(p) => <input {...p} className="input" value={form.name} onChange={(e) => set('name', e.target.value)} data-autofocus />}
        </Field>
        <Field label="Short code" error={errors.code} hint="Used in reports and exports, e.g. TSC-DXB.">
          {(p) => <input {...p} className="input" value={form.code} onChange={(e) => set('code', e.target.value)} />}
        </Field>
        <Field label="Trade licence number">
          {(p) => <input {...p} className="input" value={form.trade_license_no} onChange={(e) => set('trade_license_no', e.target.value)} />}
        </Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Emirate">
            {(p) => (
              <select {...p} className="input" value={form.emirate} onChange={(e) => set('emirate', e.target.value)}>
                {EMIRATES.map((em) => (
                  <option key={em}>{em}</option>
                ))}
              </select>
            )}
          </Field>
          <Field label="Currency" error={errors.default_currency}>
            {(p) => (
              <input {...p} className="input" value={form.default_currency} maxLength={3} onChange={(e) => set('default_currency', e.target.value.toUpperCase())} />
            )}
          </Field>
        </div>
        <Field label="Payroll day of month" error={errors.payroll_day} hint="1–28 so it exists in every month.">
          {(p) => (
            <input
              {...p}
              type="number"
              min={1}
              max={28}
              className="input"
              value={form.payroll_day ?? ''}
              onChange={(e) => set('payroll_day', e.target.value === '' ? null : Number(e.target.value))}
            />
          )}
        </Field>
        {row && (
          <label className="flex min-h-11 items-center gap-2 text-sm">
            <input type="checkbox" className="h-5 w-5 accent-brand-blue" checked={form.is_active} onChange={(e) => set('is_active', e.target.checked)} />
            Active
          </label>
        )}
        {serverError && <Alert tone="error">{serverError}</Alert>}
      </div>
      {confirming && row && (
        <InactivateConfirm target={row.name} entityId={row.id} locationId={null} onCancel={() => setConfirming(false)} onConfirm={persist} saving={saving} />
      )}
    </Drawer>
  )
}

function LocationDrawer({
  row,
  entityId,
  onClose,
  onSaved,
}: {
  row: LocationRow | null
  entityId: string
  onClose: () => void
  onSaved: (msg: string) => void
}) {
  const [form, setForm] = useState<LocationInput>({
    id: row?.id ?? null,
    entity_id: entityId,
    name: row?.name ?? '',
    code: row?.code ?? '',
    address: row?.address ?? '',
    is_active: row?.is_active ?? true,
  })
  const [errors, setErrors] = useState<{ name?: string; code?: string }>({})
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)

  async function persist() {
    setSaving(true)
    setServerError(null)
    const res = await adminUpsertLocation({ ...form, name: form.name.trim(), code: form.code.trim().toUpperCase() })
    setSaving(false)
    setConfirming(false)
    if (res.notAvailable) return setServerError('Editing branches is not available yet.')
    if (res.error) return setServerError(res.error)
    onSaved(row ? `${form.name} updated.` : `${form.name} added.`)
  }

  function submit() {
    const e: typeof errors = {}
    if (!form.name.trim()) e.name = 'Branch name is required.'
    if (form.code && !/^[A-Za-z0-9_-]{2,12}$/.test(form.code)) e.code = 'Use 2–12 letters, numbers, - or _.'
    setErrors(e)
    if (Object.keys(e).length) return
    if (row && row.is_active !== false && !form.is_active) setConfirming(true)
    else persist()
  }

  return (
    <Drawer
      open
      title={row ? `Edit ${row.name}` : 'Add branch'}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={saving}>
            {saving ? 'Saving…' : 'Save'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Branch name" error={errors.name} required>
          {(p) => <input {...p} className="input" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} data-autofocus />}
        </Field>
        <Field label="Branch code" error={errors.code}>
          {(p) => <input {...p} className="input" value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} />}
        </Field>
        <Field label="Address">
          {(p) => <textarea {...p} rows={2} className="input" value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} />}
        </Field>
        {row && (
          <label className="flex min-h-11 items-center gap-2 text-sm">
            <input type="checkbox" className="h-5 w-5 accent-brand-blue" checked={form.is_active} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
            Active
          </label>
        )}
        {serverError && <Alert tone="error">{serverError}</Alert>}
      </div>
      {confirming && row && (
        <InactivateConfirm target={row.name} entityId={entityId} locationId={row.id} onCancel={() => setConfirming(false)} onConfirm={persist} saving={saving} />
      )}
    </Drawer>
  )
}
