import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { StatusBadge } from '../../components/StatusBadge'
import { EmptyState } from '../../components/EmptyState'
import { Alert, Drawer, Field, Modal, NotAvailable, ResponsiveTable, Skeleton, type Column } from '../../components/ui'
import {
  adminGrantAccess,
  adminListUserAccess,
  adminRevokeAccess,
  listEntities,
  listLocations,
  type EntityRow,
  type LocationRow,
  type UserAccessRow,
} from '../../lib/api/admin'
import { ROLE_LABEL } from '../../lib/workflowCatalog'
import { fmtDateTime } from '../../lib/format'
import type { UserRole } from '../../types/db'

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

export function UsersTab({ isOwner, activeEntityId }: { isOwner: boolean; activeEntityId: string | null }) {
  const [rows, setRows] = useState<UserAccessRow[] | null>(null)
  const [unavailable, setUnavailable] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [entities, setEntities] = useState<EntityRow[]>([])
  const [locations, setLocations] = useState<LocationRow[]>([])
  const [granting, setGranting] = useState(false)
  const [revoking, setRevoking] = useState<UserAccessRow | null>(null)
  const [search, setSearch] = useState('')
  const [allEntities, setAllEntities] = useState(false)

  const load = useCallback(async () => {
    setRows(null)
    const res = await adminListUserAccess(isOwner && allEntities ? null : activeEntityId)
    if (res.notAvailable) setUnavailable(true)
    else if (res.error) setError(res.error)
    setRows(res.data ?? [])
  }, [activeEntityId, isOwner, allEntities])

  useEffect(() => {
    load()
    listEntities().then((r) => setEntities(r.data ?? []))
    listLocations(null).then((r) => setLocations(r.data ?? []))
  }, [load])

  const entityName = useMemo(() => Object.fromEntries(entities.map((e) => [e.id, e.name])), [entities])
  const locationName = useMemo(() => Object.fromEntries(locations.map((l) => [l.id, l.name])), [locations])

  const filtered = (rows ?? []).filter((r) => {
    const q = search.trim().toLowerCase()
    if (!q) return true
    return [r.email, r.full_name, r.role].some((v) => (v ?? '').toLowerCase().includes(q))
  })

  const columns: Column<UserAccessRow>[] = [
    {
      key: 'user',
      header: 'User',
      render: (r) => (
        <span>
          <span className="block font-medium">{r.full_name || r.email || 'Unknown'}</span>
          {r.full_name && <span className="block text-xs text-muted">{r.email}</span>}
        </span>
      ),
    },
    { key: 'role', header: 'Role', render: (r) => ROLE_LABEL[r.role] ?? r.role },
    { key: 'entity', header: 'Entity', render: (r) => (r.entity_id ? (entityName[r.entity_id] ?? '—') : 'All entities') },
    { key: 'branch', header: 'Branch', render: (r) => (r.location_id ? (locationName[r.location_id] ?? '—') : '—') },
    {
      key: 'status',
      header: 'Status',
      render: (r) => <StatusBadge status={r.is_pending ? 'pending_activation' : r.is_active ? 'active' : 'inactive'} />,
    },
    { key: 'last', header: 'Last sign-in', render: (r) => (r.is_pending ? 'Invite not yet accepted' : fmtDateTime(r.last_sign_in_at)) },
  ]

  if (unavailable) return <NotAvailable feature="User access management" />

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="w-full sm:w-72">
          <Field label="Search users">
            {(p) => <input {...p} type="search" className="input" value={search} onChange={(e) => setSearch(e.target.value)} />}
          </Field>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          {isOwner && (
            <label className="flex min-h-11 items-center gap-2 text-sm">
              <input type="checkbox" className="h-5 w-5 accent-brand-blue" checked={allEntities} onChange={(e) => setAllEntities(e.target.checked)} />
              Show all entities
            </label>
          )}
          <button className="btn-primary" onClick={() => setGranting(true)}>
            Grant access
          </button>
        </div>
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
      {rows === null ? (
        <Skeleton rows={4} />
      ) : filtered.length === 0 ? (
        <EmptyState title={search ? 'No matching users' : 'No users yet'} />
      ) : (
        <ResponsiveTable
          caption="Users and pending invites"
          columns={columns}
          rows={filtered}
          rowKey={(r) => r.grant_id ?? r.user_id ?? `${r.email}-${r.role}`}
          actions={(r) =>
            (r.is_active || r.is_pending) && (isOwner || r.role !== 'owner') ? (
              <button className="btn-secondary" onClick={() => setRevoking(r)} aria-label={`Revoke access for ${r.email ?? r.full_name}`}>
                Revoke
              </button>
            ) : null
          }
        />
      )}

      {granting && (
        <GrantDrawer
          isOwner={isOwner}
          entities={entities}
          locations={locations}
          defaultEntityId={activeEntityId}
          onClose={() => setGranting(false)}
          onDone={(email) => {
            setGranting(false)
            setNotice(`Access granted to ${email}. They'll get access the next time they sign in.`)
            load()
          }}
        />
      )}
      {revoking && (
        <RevokeModal
          row={revoking}
          onClose={() => setRevoking(null)}
          onDone={() => {
            setNotice(`Access revoked for ${revoking.email ?? revoking.full_name}.`)
            setRevoking(null)
            load()
          }}
        />
      )}
    </div>
  )
}

function GrantDrawer({
  isOwner,
  entities,
  locations,
  defaultEntityId,
  onClose,
  onDone,
}: {
  isOwner: boolean
  entities: EntityRow[]
  locations: LocationRow[]
  defaultEntityId: string | null
  onClose: () => void
  onDone: (email: string) => void
}) {
  // Entity Admin can never grant Owner — enforced server-side too.
  const roles: UserRole[] = isOwner ? ['owner', 'entity_admin', 'location_manager', 'staff'] : ['entity_admin', 'location_manager', 'staff']
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<UserRole>('staff')
  const [entityId, setEntityId] = useState(defaultEntityId ?? entities[0]?.id ?? '')
  const [locationId, setLocationId] = useState('')
  const [employeeId, setEmployeeId] = useState('')
  const [employees, setEmployees] = useState<{ id: string; full_name: string; email: string | null }[]>([])
  const [errors, setErrors] = useState<{ email?: string; entity?: string; location?: string; employee?: string }>({})
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)

  useEffect(() => {
    if (!entityId) return
    supabase
      .from('employees')
      .select('id, full_name, email')
      .eq('entity_id', entityId)
      .is('auth_user_id', null)
      .order('full_name')
      .then(({ data }) => setEmployees((data ?? []) as typeof employees))
  }, [entityId])

  // Scope rules (API contract §3): owner → nothing; entity_admin → entity;
  // location_manager → entity + branch; staff → entity + linked employee.
  const activeEntities = entities.filter((e) => e.is_active !== false)
  const branchOptions = locations.filter((l) => l.entity_id === entityId && l.is_active !== false)
  const needsEntity = role !== 'owner'
  const needsBranch = role === 'location_manager'
  const needsEmployee = role === 'staff'

  async function submit() {
    const e: typeof errors = {}
    if (!EMAIL_RE.test(email.trim())) e.email = 'Enter a valid email address.'
    if (needsEntity && !entityId) e.entity = 'Choose an entity.'
    if (needsBranch && !locationId) e.location = 'Location managers need a branch.'
    if (needsEmployee && !employeeId) e.employee = 'Staff access must be linked to their employee record.'
    setErrors(e)
    if (Object.keys(e).length) return
    setSaving(true)
    setServerError(null)
    const res = await adminGrantAccess(
      email.trim().toLowerCase(),
      role,
      needsEntity ? entityId : null,
      needsBranch ? locationId : null,
      needsEmployee ? employeeId : null
    )
    setSaving(false)
    if (res.notAvailable) return setServerError('Granting access is not available yet.')
    if (res.error) return setServerError(res.error)
    onDone(email.trim())
  }

  return (
    <Drawer
      open
      title="Grant access"
      description="Give someone a role in Third State HR. Access applies from their next sign-in."
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={saving}>
            {saving ? 'Granting…' : 'Grant access'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Email" error={errors.email} required>
          {(p) => <input {...p} type="email" autoComplete="off" className="input" value={email} onChange={(e) => setEmail(e.target.value)} data-autofocus />}
        </Field>
        <Field label="Role" required hint={!isOwner ? 'Only the Owner can grant Owner access.' : undefined}>
          {(p) => (
            <select {...p} className="input" value={role} onChange={(e) => setRole(e.target.value as UserRole)}>
              {roles.map((r) => (
                <option key={r} value={r}>
                  {ROLE_LABEL[r]}
                </option>
              ))}
            </select>
          )}
        </Field>
        {needsEntity && (
          <Field label="Entity" error={errors.entity} required>
            {(p) => (
              <select {...p} className="input" value={entityId} onChange={(e) => setEntityId(e.target.value)} disabled={!isOwner}>
                {activeEntities.map((en) => (
                  <option key={en.id} value={en.id}>
                    {en.name}
                  </option>
                ))}
              </select>
            )}
          </Field>
        )}
        {needsBranch && (
          <Field label="Branch" error={errors.location} required>
            {(p) => (
              <select {...p} className="input" value={locationId} onChange={(e) => setLocationId(e.target.value)}>
                <option value="">Choose a branch</option>
                {branchOptions.map((l) => (
                  <option key={l.id} value={l.id}>
                    {l.name}
                  </option>
                ))}
              </select>
            )}
          </Field>
        )}
        {needsEmployee && (
          <Field label="Linked employee" error={errors.employee} required hint="Only employees without a login are listed.">
            {(p) => (
              <select {...p} className="input" value={employeeId} onChange={(e) => setEmployeeId(e.target.value)}>
                <option value="">Choose an employee</option>
                {employees.map((em) => (
                  <option key={em.id} value={em.id}>
                    {em.full_name}
                    {em.email ? ` (${em.email})` : ''}
                  </option>
                ))}
              </select>
            )}
          </Field>
        )}
        {serverError && <Alert tone="error">{serverError}</Alert>}
      </div>
    </Drawer>
  )
}

function RevokeModal({ row, onClose, onDone }: { row: UserAccessRow; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  async function submit() {
    if (!reason.trim()) return setErr('A reason is required.')
    setSaving(true)
    const res = await adminRevokeAccess(row.user_id, row.grant_id, reason.trim())
    setSaving(false)
    if (res.notAvailable) return setErr('Revoking access is not available yet.')
    if (res.error) return setErr(res.error)
    onDone()
  }
  return (
    <Modal
      open
      title="Revoke access?"
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-danger" onClick={submit} disabled={saving}>
            {saving ? 'Revoking…' : 'Revoke access'}
          </button>
        </>
      }
    >
      <p>
        <strong>{row.full_name || row.email}</strong> ({ROLE_LABEL[row.role]}) will lose access immediately. Their employee record and history are kept.
      </p>
      <Field label="Reason" error={err} required>
        {(p) => <textarea {...p} rows={3} className="input" value={reason} onChange={(e) => setReason(e.target.value)} data-autofocus />}
      </Field>
    </Modal>
  )
}
