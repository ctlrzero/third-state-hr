import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import type {
  ApplicationInterviewFeedbackRow,
  CandidateSource,
  Employee,
  Interview,
  InterviewStage,
  JobApplication,
  JobRequisition,
  Location,
  Offer,
  Position,
  RequisitionStatus,
} from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'
import { confirmDialog } from '../lib/confirm'
import { fmtDateTime } from '../lib/format'

const REQ_STATUSES: { value: RequisitionStatus; label: string }[] = [
  { value: 'draft', label: 'Draft' },
  { value: 'open', label: 'Open' },
  { value: 'on_hold', label: 'On hold' },
  { value: 'closed', label: 'Closed' },
  { value: 'cancelled', label: 'Cancelled' },
]

const CANDIDATE_SOURCES: { value: CandidateSource; label: string }[] = [
  { value: 'referral', label: 'Referral' },
  { value: 'walk_in', label: 'Walk-in' },
  { value: 'online', label: 'Online' },
  { value: 'agency', label: 'Agency' },
  { value: 'other', label: 'Other' },
]

// job_applications_stage_check / candidates_status_check share this vocabulary.
const STAGES: { value: string; label: string }[] = [
  { value: 'applied', label: 'Applied' },
  { value: 'screening', label: 'Screening' },
  { value: 'interviewing', label: 'Interviewing' },
  { value: 'offer', label: 'Offer' },
  { value: 'hired', label: 'Hired' },
  { value: 'rejected', label: 'Rejected' },
  { value: 'withdrawn', label: 'Withdrawn' },
]

function money(n: number | null | undefined, currency: string) {
  const value = n ?? 0
  try {
    return new Intl.NumberFormat('en-AE', { style: 'currency', currency }).format(value)
  } catch {
    return value.toFixed(2)
  }
}

// Recruiting: requisitions -> candidates/applications -> interviews -> offer
// -> convert to employee. Built against the existing job_requisitions /
// candidates / job_applications / interview_stages / interviews / offers
// tables and the convert_offer_to_employee RPC — no schema changes.
// Visible to owner/entity_admin/location_manager per the existing RLS scope
// (candidates/requisitions ALL policy includes location_manager scoped to
// their own location; offers is owner/entity_admin only since compensation
// is compensation-adjacent).
// Recruiting admin module is owner/entity_admin/location_manager only (see
// RLS notes above). A plain employee -- including one assigned as an
// interviewer -- has no underlying table access here (candidates_access /
// requisitions_select exclude the 'employee' role entirely), so this was
// previously "safe" in the sense that no data could leak; but the page
// itself rendered its full admin shell (including the New Requisition
// action) for anyone who navigated here directly, which is a defense-in-
// depth gap. Gate it the same way Payroll.tsx gates PayrollManager vs
// MyPay: a hook-free wrapper decides, before any data fetching, whether to
// render the admin module at all. Their real destination is My Interviews.
export default function Recruiting() {
  const { profile } = useAuth()
  const canAccessRecruitingModule =
    profile?.role === 'owner' || profile?.role === 'entity_admin' || profile?.role === 'location_manager'

  if (!canAccessRecruitingModule) {
    return <Navigate to="/my-interviews" replace />
  }

  return <RecruitingAdmin />
}

function RecruitingAdmin() {
  const { profile, activeEntityId, entities } = useAuth()
  const canManageOffers = profile?.role === 'owner' || profile?.role === 'entity_admin'
  const currency = entities.find((e) => e.id === activeEntityId)?.default_currency || 'AED'

  const [requisitions, setRequisitions] = useState<JobRequisition[]>([])
  const [positions, setPositions] = useState<Pick<Position, 'id' | 'title' | 'department'>[]>([])
  const [locations, setLocations] = useState<Pick<Location, 'id' | 'name'>[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [statusFilter, setStatusFilter] = useState<RequisitionStatus | 'all'>('all')

  async function load() {
    if (!activeEntityId) return
    setLoading(true)
    setError(null)
    const [reqRes, posRes, locRes] = await Promise.all([
      supabase
        .from('job_requisitions')
        .select('*, locations(id, name), positions(id, title, department)')
        .eq('entity_id', activeEntityId)
        .order('created_at', { ascending: false }),
      supabase.from('positions').select('id, title, department').eq('entity_id', activeEntityId).order('title'),
      supabase.from('locations').select('id, name').eq('entity_id', activeEntityId).order('name'),
    ])
    if (reqRes.error) setError(reqRes.error.message)
    else setRequisitions((reqRes.data ?? []) as unknown as JobRequisition[])
    setPositions(posRes.data ?? [])
    setLocations(locRes.data ?? [])
    setLoading(false)
  }

  useEffect(() => {
    load()
    setSelectedId(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeEntityId])

  const visibleRequisitions = useMemo(
    () => (statusFilter === 'all' ? requisitions : requisitions.filter((r) => r.status === statusFilter)),
    [requisitions, statusFilter]
  )

  const selected = requisitions.find((r) => r.id === selectedId) ?? null

  if (selected) {
    return (
      <RequisitionDetail
        requisition={selected}
        currency={currency}
        canManageOffers={canManageOffers}
        onBack={() => {
          setSelectedId(null)
          load()
        }}
        onNotice={setNotice}
      />
    )
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">Recruiting</h1>
          <p className="text-xs text-muted">
            {loading ? 'Loading…' : `${visibleRequisitions.length} of ${requisitions.length} requisitions`}
          </p>
        </div>
        <button
          onClick={() => setCreateOpen(true)}
          className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark"
        >
          New requisition
        </button>
      </div>

      {error && (
        <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">
          {error}{' '}
          <button className="underline" onClick={() => setError(null)}>
            Dismiss
          </button>
        </p>
      )}
      {notice && (
        <p className="rounded-lg bg-brand-action-soft px-3 py-2 text-sm text-brand-action-text">
          {notice}{' '}
          <button className="underline" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted w-full sm:w-56">
        Status
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value as RequisitionStatus | 'all')}
          className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          <option value="all">All statuses</option>
          {REQ_STATUSES.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </select>
      </label>

      {loading ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-16 animate-pulse rounded-[14px] bg-surface" />
          ))}
        </div>
      ) : visibleRequisitions.length === 0 ? (
        <EmptyState
          title={requisitions.length === 0 ? 'No open roles yet' : 'No requisitions match this filter'}
          description={requisitions.length === 0 ? 'Create a requisition to start hiring for a role.' : undefined}
        />
      ) : (
        <ul className="space-y-3">
          {visibleRequisitions.map((req) => (
            <li key={req.id} className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <p className="font-medium text-ink">{req.positions?.title ?? '—'}</p>
                  <p className="text-xs text-muted">
                    {req.locations?.name ?? '—'} · Headcount {req.headcount}
                  </p>
                </div>
                <StatusBadge status={req.status} />
              </div>
              <button
                onClick={() => setSelectedId(req.id)}
                className="mt-3 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
              >
                Open
              </button>
            </li>
          ))}
        </ul>
      )}

      {createOpen && activeEntityId && (
        <NewRequisitionModal
          entityId={activeEntityId}
          positions={positions}
          locations={locations}
          onClose={() => setCreateOpen(false)}
          onCreated={() => {
            setCreateOpen(false)
            load()
          }}
        />
      )}
    </div>
  )
}

function NewRequisitionModal({
  entityId,
  positions,
  locations,
  onClose,
  onCreated,
}: {
  entityId: string
  positions: Pick<Position, 'id' | 'title' | 'department'>[]
  locations: Pick<Location, 'id' | 'name'>[]
  onClose: () => void
  onCreated: () => void
}) {
  const [locationId, setLocationId] = useState(locations[0]?.id ?? '')
  const [positionId, setPositionId] = useState(positions[0]?.id ?? '')
  const [headcount, setHeadcount] = useState('1')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!locationId || !positionId) {
      setError('Choose a location and a position.')
      return
    }
    setSubmitting(true)
    setError(null)
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const { error: insertError } = await supabase.from('job_requisitions').insert({
      entity_id: entityId,
      location_id: locationId,
      position_id: positionId,
      headcount: Number(headcount) || 1,
      created_by: user?.id ?? null,
    })
    setSubmitting(false)
    if (insertError) {
      setError(insertError.message)
      return
    }
    onCreated()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">New requisition</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="recruiting-position-1" className="mb-1 block text-sm font-medium text-ink">Position</label>
            <select id="recruiting-position-1"
              value={positionId}
              onChange={(e) => setPositionId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {positions.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.title}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="recruiting-location-2" className="mb-1 block text-sm font-medium text-ink">Location</label>
            <select id="recruiting-location-2"
              value={locationId}
              onChange={(e) => setLocationId(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="recruiting-headcount-3" className="mb-1 block text-sm font-medium text-ink">Headcount</label>
            <input id="recruiting-headcount-3"
              type="number"
              min="1"
              value={headcount}
              onChange={(e) => setHeadcount(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>

          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Creating…' : 'Create requisition'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Requisition detail: status, interview stages, applications pipeline
// ---------------------------------------------------------------------------

function RequisitionDetail({
  requisition,
  currency,
  canManageOffers,
  onBack,
  onNotice,
}: {
  requisition: JobRequisition
  currency: string
  canManageOffers: boolean
  onBack: () => void
  onNotice: (msg: string) => void
}) {
  const [stages, setStages] = useState<InterviewStage[]>([])
  const [applications, setApplications] = useState<JobApplication[]>([])
  const [interviewers, setInterviewers] = useState<Pick<Employee, 'id' | 'full_name' | 'auth_user_id'>[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [addCandidateOpen, setAddCandidateOpen] = useState(false)
  const [selectedApplicationId, setSelectedApplicationId] = useState<string | null>(null)

  async function load() {
    setLoading(true)
    setError(null)
    const [stageRes, appRes, empRes] = await Promise.all([
      supabase.from('interview_stages').select('*').eq('requisition_id', requisition.id).order('sequence'),
      supabase
        .from('job_applications')
        .select('*, candidates(id, full_name, contact_email, contact_phone, source)')
        .eq('requisition_id', requisition.id)
        .order('applied_at', { ascending: false }),
      supabase
        .from('employees')
        .select('id, full_name, auth_user_id')
        .eq('entity_id', requisition.entity_id)
        .not('auth_user_id', 'is', null)
        .order('full_name'),
    ])
    if (stageRes.error) setError(stageRes.error.message)
    else setStages(stageRes.data ?? [])
    setApplications((appRes.data ?? []) as unknown as JobApplication[])
    setInterviewers(empRes.data ?? [])
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [requisition.id])

  async function handleStatusChange(next: RequisitionStatus) {
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const patch: Record<string, unknown> = { status: next }
    if (next === 'open' && requisition.status !== 'open') {
      patch.opened_by = user?.id ?? null
      patch.opened_at = new Date().toISOString()
    }
    if ((next === 'closed' || next === 'cancelled') && requisition.status !== 'closed' && requisition.status !== 'cancelled') {
      patch.closed_by = user?.id ?? null
      patch.closed_at = new Date().toISOString()
    }
    const { error: updateError } = await supabase.from('job_requisitions').update(patch).eq('id', requisition.id)
    if (updateError) {
      setError(updateError.message)
      return
    }
    onNotice(`Requisition status set to ${REQ_STATUSES.find((s) => s.value === next)?.label}.`)
    onBack()
  }

  const selectedApplication = applications.find((a) => a.id === selectedApplicationId) ?? null

  return (
    <div className="space-y-5">
      <button onClick={onBack} className="text-sm text-brand-blue hover:underline">
        ← Back to requisitions
      </button>

      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-normal text-ink">{requisition.positions?.title}</h1>
          <p className="text-xs text-muted">
            {requisition.locations?.name} · Headcount {requisition.headcount}
          </p>
        </div>
        <select
          aria-label="Requisition status"
          value={requisition.status}
          onChange={(e) => handleStatusChange(e.target.value as RequisitionStatus)}
          className="rounded-lg border border-border bg-surface px-3 py-2 text-sm font-medium text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          {REQ_STATUSES.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </select>
      </div>

      {error && (
        <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">
          {error}{' '}
          <button className="underline" onClick={() => setError(null)}>
            Dismiss
          </button>
        </p>
      )}

      <InterviewStagesSection requisitionId={requisition.id} stages={stages} onChange={load} />

      <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm font-semibold text-ink">Candidates</h2>
          <button
            onClick={() => setAddCandidateOpen(true)}
            className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-blue-dark"
          >
            Add candidate
          </button>
        </div>
        {loading ? (
          <div className="h-16 animate-pulse rounded-lg bg-surface-alt" />
        ) : applications.length === 0 ? (
          <p className="text-sm text-muted">No candidates in this pipeline yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="table-stack w-full text-left text-sm">
              <thead className="border-b border-border text-xs uppercase tracking-wide text-muted">
                <tr>
                  <th className="py-2 pr-3 font-medium">Candidate</th>
                  <th className="py-2 pr-3 font-medium">Source</th>
                  <th className="py-2 pr-3 font-medium">Stage</th>
                  <th className="py-2 pr-3 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {applications.map((app) => (
                  <tr key={app.id}>
                    <td data-label="Candidate" className="py-2 pr-3 font-medium text-ink">{app.candidates?.full_name ?? '—'}</td>
                    <td data-label="Source" className="py-2 pr-3 capitalize text-muted">{app.candidates?.source?.replace('_', ' ')}</td>
                    <td data-label="Stage" className="py-2 pr-3">
                      <StatusBadge status={app.stage} />
                    </td>
                    <td data-label="Actions" className="py-2 pr-3 text-right">
                      <button
                        onClick={() => setSelectedApplicationId(app.id)}
                        className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                      >
                        Open
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {addCandidateOpen && (
        <AddCandidateModal
          entityId={requisition.entity_id}
          locationId={requisition.location_id}
          requisitionId={requisition.id}
          onClose={() => setAddCandidateOpen(false)}
          onAdded={() => {
            setAddCandidateOpen(false)
            load()
          }}
        />
      )}

      {selectedApplication && (
        <ApplicationDrawer
          application={selectedApplication}
          stages={stages}
          interviewers={interviewers}
          positionId={requisition.position_id}
          currency={currency}
          canManageOffers={canManageOffers}
          onClose={() => setSelectedApplicationId(null)}
          onChange={load}
          onNotice={onNotice}
        />
      )}
    </div>
  )
}

function InterviewStagesSection({
  requisitionId,
  stages,
  onChange,
}: {
  requisitionId: string
  stages: InterviewStage[]
  onChange: () => void
}) {
  const [name, setName] = useState('')
  const [error, setError] = useState<string | null>(null)

  async function handleAdd(e: FormEvent) {
    e.preventDefault()
    if (!name.trim()) return
    setError(null)
    const nextSequence = (stages[stages.length - 1]?.sequence ?? 0) + 1
    const { error: insertError } = await supabase
      .from('interview_stages')
      .insert({ requisition_id: requisitionId, name: name.trim(), sequence: nextSequence })
    if (insertError) {
      setError(insertError.message)
      return
    }
    setName('')
    onChange()
  }

  return (
    <div className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <h2 className="mb-3 text-sm font-semibold text-ink">Interview stages</h2>
      {stages.length === 0 ? (
        <p className="mb-3 text-sm text-muted">No stages defined yet — e.g. Phone screen, In-person, Trial shift.</p>
      ) : (
        <ol className="mb-3 flex flex-wrap gap-2">
          {stages.map((s) => (
            <li key={s.id} className="rounded-full bg-surface-alt px-3 py-1 text-xs text-ink">
              {s.sequence}. {s.name}
            </li>
          ))}
        </ol>
      )}
      <form onSubmit={handleAdd} className="flex items-end gap-2">
        <div className="flex-1">
          <label htmlFor="recruiting-add-stage-4" className="mb-1 block text-xs font-medium text-ink">Add stage</label>
          <input id="recruiting-add-stage-4"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. Trial shift"
            className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          />
        </div>
        <button type="submit" className="rounded-lg bg-brand-blue px-3 py-2 text-xs font-medium text-white hover:bg-brand-blue-dark">
          Add
        </button>
      </form>
      {error && <p className="mt-2 text-xs text-brand-risk-text">{error}</p>}
    </div>
  )
}

function AddCandidateModal({
  entityId,
  locationId,
  requisitionId,
  onClose,
  onAdded,
}: {
  entityId: string
  locationId: string
  requisitionId: string
  onClose: () => void
  onAdded: () => void
}) {
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [source, setSource] = useState<CandidateSource>('online')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!fullName.trim()) {
      setError('Enter the candidate’s name.')
      return
    }
    setSubmitting(true)
    setError(null)
    const {
      data: { user },
    } = await supabase.auth.getUser()

    const { data: candidate, error: candidateError } = await supabase
      .from('candidates')
      .insert({
        entity_id: entityId,
        location_id: locationId,
        full_name: fullName.trim(),
        contact_email: email || null,
        contact_phone: phone || null,
        source,
        created_by: user?.id ?? null,
      })
      .select('id')
      .single()

    if (candidateError || !candidate) {
      setSubmitting(false)
      setError(candidateError?.message ?? 'Could not create candidate.')
      return
    }

    const { error: applicationError } = await supabase.from('job_applications').insert({
      requisition_id: requisitionId,
      candidate_id: candidate.id,
    })
    setSubmitting(false)
    if (applicationError) {
      setError(applicationError.message)
      return
    }
    onAdded()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">Add candidate</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="recruiting-full-name-5" className="mb-1 block text-sm font-medium text-ink">Full name</label>
            <input id="recruiting-full-name-5"
              value={fullName}
              onChange={(e) => setFullName(e.target.value)}
              required
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label htmlFor="recruiting-email-6" className="mb-1 block text-sm font-medium text-ink">Email</label>
              <input id="recruiting-email-6"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
            <div>
              <label htmlFor="recruiting-phone-7" className="mb-1 block text-sm font-medium text-ink">Phone</label>
              <input id="recruiting-phone-7"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
            </div>
          </div>
          <div>
            <label htmlFor="recruiting-source-8" className="mb-1 block text-sm font-medium text-ink">Source</label>
            <select id="recruiting-source-8"
              value={source}
              onChange={(e) => setSource(e.target.value as CandidateSource)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {CANDIDATE_SOURCES.map((s) => (
                <option key={s.value} value={s.value}>
                  {s.label}
                </option>
              ))}
            </select>
          </div>

          {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {submitting ? 'Adding…' : 'Add to pipeline'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Application drawer: stage, interviews, offer, convert-to-employee
// ---------------------------------------------------------------------------

function ApplicationDrawer({
  application,
  stages,
  interviewers,
  positionId,
  currency,
  canManageOffers,
  onClose,
  onChange,
  onNotice,
}: {
  application: JobApplication
  stages: InterviewStage[]
  interviewers: Pick<Employee, 'id' | 'full_name' | 'auth_user_id'>[]
  positionId: string
  currency: string
  canManageOffers: boolean
  onClose: () => void
  onChange: () => void
  onNotice: (msg: string) => void
}) {
  const [interviews, setInterviews] = useState<Interview[]>([])
  const [feedbackRows, setFeedbackRows] = useState<ApplicationInterviewFeedbackRow[]>([])
  const [offer, setOffer] = useState<Offer | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [rejectReason, setRejectReason] = useState('')

  async function load() {
    setLoading(true)
    // Interview scheduling metadata (who/when/outcome) is a plain table
    // select — RLS already scopes it correctly for owner/entity_admin/
    // location_manager and it carries nothing sensitive. Feedback content is
    // fetched separately through the reveal-gated get_application_interview_feedback()
    // RPC (Phase 3.12) rather than embedded, since a raw nested select had no
    // gating at all — see the comment on Interview.interview_feedback (removed).
    const [ivRes, feedbackRes, offerRes] = await Promise.all([
      supabase
        .from('interviews')
        .select('*, interview_stages(id, name, sequence)')
        .eq('application_id', application.id)
        .order('scheduled_at'),
      supabase.rpc('get_application_interview_feedback', { p_application_id: application.id }),
      supabase.from('offers').select('*').eq('application_id', application.id).maybeSingle(),
    ])
    setInterviews((ivRes.data ?? []) as unknown as Interview[])
    setFeedbackRows((feedbackRes.data ?? []) as ApplicationInterviewFeedbackRow[])
    setOffer((offerRes.data ?? null) as Offer | null)
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [application.id])

  async function handleStageChange(stage: string) {
    if (stage === 'rejected' && !rejectReason.trim()) {
      setError('A rejection reason is required.')
      return
    }
    const { error: updateError } = await supabase
      .from('job_applications')
      .update({ stage, rejection_reason: stage === 'rejected' ? rejectReason.trim() : null })
      .eq('id', application.id)
    if (updateError) {
      setError(updateError.message)
      return
    }
    onChange()
    onClose()
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="max-h-[85vh] w-full max-w-2xl overflow-y-auto rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-1 flex items-start justify-between">
          <h2 className="text-base font-semibold text-ink">{application.candidates?.full_name}</h2>
          <StatusBadge status={application.stage} />
        </div>
        <p className="mb-4 text-xs text-muted">
          {application.candidates?.contact_email} {application.candidates?.contact_phone ? `· ${application.candidates.contact_phone}` : ''}
        </p>

        {error && <p className="mb-3 rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

        <div className="mb-5 space-y-2">
          <label className="block text-xs font-semibold uppercase tracking-wide text-muted">Move to stage</label>
          <div className="flex flex-wrap gap-2">
            {STAGES.map((s) => (
              <button
                key={s.value}
                onClick={() => handleStageChange(s.value)}
                className={`rounded-full px-3 py-1.5 text-xs font-medium ${
                  application.stage === s.value ? 'bg-brand-blue text-white' : 'border border-border text-ink hover:border-brand-blue/30'
                }`}
              >
                {s.label}
              </button>
            ))}
          </div>
          {application.stage !== 'rejected' && (
            <input
              aria-label="Rejection reason"
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
              placeholder="Reason (required to move to Rejected)"
              className="mt-1 w-full rounded-lg border border-border px-3 py-2 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          )}
          {application.stage === 'rejected' && application.rejection_reason && (
            <p className="text-xs text-brand-risk-text">Rejected: {application.rejection_reason}</p>
          )}
        </div>

        {loading ? (
          <div className="h-24 animate-pulse rounded-lg bg-surface-alt" />
        ) : (
          <>
            <InterviewsList
              applicationId={application.id}
              stages={stages}
              interviewers={interviewers}
              interviews={interviews}
              feedbackRows={feedbackRows}
              canReopenFeedback={canManageOffers}
              canCloseRound={canManageOffers}
              onChange={load}
            />

            {canManageOffers && (
              <OfferSection
                applicationId={application.id}
                positionId={positionId}
                offer={offer}
                currency={currency}
                onChange={() => {
                  load()
                  onChange()
                }}
                onNotice={onNotice}
              />
            )}
          </>
        )}

        <div className="mt-4 flex justify-end">
          <button onClick={onClose} className="text-sm text-muted hover:text-ink">
            Close
          </button>
        </div>
      </div>
    </div>
  )
}

function InterviewsList({
  applicationId,
  stages,
  interviewers,
  interviews,
  feedbackRows,
  canReopenFeedback,
  canCloseRound,
  onChange,
}: {
  applicationId: string
  stages: InterviewStage[]
  interviewers: Pick<Employee, 'id' | 'full_name' | 'auth_user_id'>[]
  interviews: Interview[]
  feedbackRows: ApplicationInterviewFeedbackRow[]
  canReopenFeedback: boolean
  canCloseRound: boolean
  onChange: () => void
}) {
  const [stageId, setStageId] = useState(stages[0]?.id ?? '')
  const [interviewerAuthId, setInterviewerAuthId] = useState(interviewers[0]?.auth_user_id ?? '')
  const [scheduledAt, setScheduledAt] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [cancellingId, setCancellingId] = useState<string | null>(null)
  const [cancelReason, setCancelReason] = useState('')
  const [reopeningId, setReopeningId] = useState<string | null>(null)
  const [reopenReason, setReopenReason] = useState('')
  const [reschedulingId, setReschedulingId] = useState<string | null>(null)
  const [rescheduleAt, setRescheduleAt] = useState('')
  const [rescheduleInterviewerAuthId, setRescheduleInterviewerAuthId] = useState('')
  const [rescheduleReason, setRescheduleReason] = useState('')
  const [busyId, setBusyId] = useState<string | null>(null)
  const [closingRoundStageId, setClosingRoundStageId] = useState<string | null>(null)
  const [closeRoundReason, setCloseRoundReason] = useState('')
  const [closeRoundBusy, setCloseRoundBusy] = useState(false)

  async function handleAdd(e: FormEvent) {
    e.preventDefault()
    if (!stageId || !interviewerAuthId || !scheduledAt) {
      setError('Choose a stage, an interviewer, and a date/time.')
      return
    }
    setError(null)
    const { error: insertError } = await supabase.from('interviews').insert({
      application_id: applicationId,
      stage_id: stageId,
      interviewer_id: interviewerAuthId,
      scheduled_at: new Date(scheduledAt).toISOString(),
    })
    if (insertError) {
      setError(insertError.message)
      return
    }
    setScheduledAt('')
    onChange()
  }

  async function handleOutcome(id: string, outcome: 'pass' | 'fail') {
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const { error: updateError } = await supabase
      .from('interviews')
      .update({ outcome, recorded_by: user?.id ?? null, recorded_at: new Date().toISOString() })
      .eq('id', id)
    if (updateError) {
      setError(updateError.message)
      return
    }
    onChange()
  }

  // Cancellation is server-enforced via cancel_interview() — the RPC re-checks
  // owner/entity_admin-in-entity or location_manager-in-location itself, so
  // this button being visible is only a convenience, not the access control.
  async function handleCancel(id: string) {
    if (!cancelReason.trim()) {
      setError('A cancellation reason is required.')
      return
    }
    setBusyId(id)
    setError(null)
    const { error: rpcError } = await supabase.rpc('cancel_interview', { p_interview_id: id, p_reason: cancelReason.trim() })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setCancellingId(null)
    setCancelReason('')
    onChange()
  }

  // Reschedule is server-enforced via reschedule_interview() — same
  // authorization re-check as cancel_interview(), plus its own idempotency
  // guard (blocks a second reschedule from the same source interview). The
  // RPC cancels the source (if not already cancelled) and creates a linked
  // follow-up in one call, so this is never two separate client requests
  // that could race or leave an orphaned cancellation with no follow-up.
  async function handleReschedule(id: string) {
    if (!rescheduleAt) {
      setError('Choose a new date/time.')
      return
    }
    setBusyId(id)
    setError(null)
    const interviewer = interviewers.find((e) => e.auth_user_id === rescheduleInterviewerAuthId)
    const { error: rpcError } = await supabase.rpc('reschedule_interview', {
      p_interview_id: id,
      p_new_scheduled_at: new Date(rescheduleAt).toISOString(),
      p_new_interviewer_id: interviewer?.auth_user_id ?? null,
      p_format: null,
      p_meeting_location: null,
      p_reason: rescheduleReason.trim() || null,
    })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setReschedulingId(null)
    setRescheduleAt('')
    setRescheduleInterviewerAuthId('')
    setRescheduleReason('')
    onChange()
  }

  // Reopen is restricted to owner/entity_admin by reopen_interview_feedback()
  // itself — location_manager is deliberately excluded there even if
  // canReopenFeedback were somehow true on the client.
  async function handleReopen(id: string) {
    if (!reopenReason.trim()) {
      setError('A reason is required to reopen submitted feedback.')
      return
    }
    setBusyId(id)
    setError(null)
    const { error: rpcError } = await supabase.rpc('reopen_interview_feedback', {
      p_interview_id: id,
      p_reason: reopenReason.trim(),
    })
    setBusyId(null)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setReopeningId(null)
    setReopenReason('')
    onChange()
  }

  // Closing a round is restricted to owner/entity_admin by close_interview_round()
  // itself — canCloseRound being true on the client is only a convenience for
  // which button renders, not the access control. Forces reveal for a round
  // where not every interviewer will submit (a straggler, someone who left,
  // etc.) — sticky, audited, and requires a reason.
  async function handleCloseRound(stageIdToClose: string) {
    if (!closeRoundReason.trim()) {
      setError('A reason is required to close an interview round.')
      return
    }
    setCloseRoundBusy(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('close_interview_round', {
      p_application_id: applicationId,
      p_stage_id: stageIdToClose,
      p_reason: closeRoundReason.trim(),
    })
    setCloseRoundBusy(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setClosingRoundStageId(null)
    setCloseRoundReason('')
    onChange()
  }

  // Group interviews into rounds (application_id + stage_id) in stage
  // sequence order, so the "X of Y submitted" / reveal / close-round controls
  // sit once above each stage's interviews rather than being repeated or lost
  // in a flat list.
  const stageOrder = stages.length > 0 ? stages : []
  const groupedStageIds = Array.from(new Set(interviews.map((iv) => iv.stage_id)))
  const orderedStageIds = [
    ...stageOrder.map((s) => s.id).filter((id) => groupedStageIds.includes(id)),
    ...groupedStageIds.filter((id) => !stageOrder.some((s) => s.id === id)),
  ]

  return (
    <div className="mb-5 border-t border-border pt-4">
      <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Interviews</p>
      {interviews.length === 0 ? (
        <p className="mb-3 text-sm text-muted">No interviews scheduled yet.</p>
      ) : (
        <div className="mb-3 space-y-4">
          {orderedStageIds.map((groupStageId) => {
            const stageInterviews = interviews.filter((iv) => iv.stage_id === groupStageId)
            const stageMeta = feedbackRows.find((f) => f.stage_id === groupStageId)
            const stageName = stageInterviews[0]?.interview_stages?.name ?? stages.find((s) => s.id === groupStageId)?.name ?? 'Stage'
            return (
              <div key={groupStageId}>
                <div className="mb-2 flex flex-wrap items-center justify-between gap-2 rounded-lg bg-surface-alt px-3 py-2">
                  <div className="text-xs text-ink">
                    <span className="font-semibold">{stageName}</span>
                    {stageMeta && (
                      <span className="ml-2 text-muted">
                        {stageMeta.round_submitted_count} of {stageMeta.round_required_count} interviewer
                        {stageMeta.round_required_count === 1 ? '' : 's'} submitted
                        {stageMeta.round_revealed ? ' · feedback revealed' : ' · feedback private until complete'}
                        {stageMeta.round_closed ? ` · round closed${stageMeta.round_closed_by_name ? ` by ${stageMeta.round_closed_by_name}` : ''}` : ''}
                      </span>
                    )}
                  </div>
                  {canCloseRound && stageMeta && !stageMeta.round_revealed && (
                    <button
                      onClick={() => setClosingRoundStageId(closingRoundStageId === groupStageId ? null : groupStageId)}
                      className="rounded-full border border-border px-2 py-1 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                    >
                      Close round
                    </button>
                  )}
                </div>

                {closingRoundStageId === groupStageId && (
                  <div className="mb-2 flex flex-wrap items-center gap-2 rounded-lg border border-border bg-surface p-2 text-xs">
                    <input
                      aria-label="Reason for closing the round"
                      value={closeRoundReason}
                      onChange={(e) => setCloseRoundReason(e.target.value)}
                      placeholder="Reason (required, audited) — e.g. a panelist never submitted"
                      className="flex-1 rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                    />
                    <button
                      onClick={() => handleCloseRound(groupStageId)}
                      disabled={closeRoundBusy}
                      className="rounded-lg bg-brand-blue px-2 py-1.5 font-medium text-white disabled:opacity-60"
                    >
                      {closeRoundBusy ? 'Closing…' : 'Confirm close round'}
                    </button>
                    <button onClick={() => setClosingRoundStageId(null)} className="text-muted hover:text-ink">
                      Back
                    </button>
                  </div>
                )}

                <ul className="space-y-2">
                  {stageInterviews.map((iv) => (
                    <InterviewRow
                      key={iv.id}
                      iv={iv}
                      interviewer={interviewers.find((e) => e.auth_user_id === iv.interviewer_id)}
                      feedback={feedbackRows.find((f) => f.interview_id === iv.id) ?? null}
                      canReopenFeedback={canReopenFeedback}
                      interviews={interviews}
                      interviewers={interviewers}
                      busyId={busyId}
                      reschedulingId={reschedulingId}
                      setReschedulingId={setReschedulingId}
                      rescheduleAt={rescheduleAt}
                      setRescheduleAt={setRescheduleAt}
                      rescheduleInterviewerAuthId={rescheduleInterviewerAuthId}
                      setRescheduleInterviewerAuthId={setRescheduleInterviewerAuthId}
                      rescheduleReason={rescheduleReason}
                      setRescheduleReason={setRescheduleReason}
                      handleReschedule={handleReschedule}
                      cancellingId={cancellingId}
                      setCancellingId={setCancellingId}
                      cancelReason={cancelReason}
                      setCancelReason={setCancelReason}
                      handleCancel={handleCancel}
                      handleOutcome={handleOutcome}
                      reopeningId={reopeningId}
                      setReopeningId={setReopeningId}
                      reopenReason={reopenReason}
                      setReopenReason={setReopenReason}
                      handleReopen={handleReopen}
                    />
                  ))}
                </ul>
              </div>
            )
          })}
        </div>
      )}
      {stages.length === 0 || interviewers.length === 0 ? (
        <p className="text-xs text-muted">
          {stages.length === 0 ? 'Add an interview stage above before scheduling.' : 'No employees with a linked login are available as interviewers yet.'}
        </p>
      ) : (
        <form onSubmit={handleAdd} className="flex flex-wrap items-end gap-2">
          <div>
            <label htmlFor="recruiting-stage-9" className="mb-1 block text-xs font-medium text-ink">Stage</label>
            <select id="recruiting-stage-9"
              value={stageId}
              onChange={(e) => setStageId(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {stages.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="recruiting-interviewer-10" className="mb-1 block text-xs font-medium text-ink">Interviewer</label>
            <select id="recruiting-interviewer-10"
              value={interviewerAuthId}
              onChange={(e) => setInterviewerAuthId(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            >
              {interviewers.map((e) => (
                <option key={e.id} value={e.auth_user_id ?? ''}>
                  {e.full_name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="recruiting-when-11" className="mb-1 block text-xs font-medium text-ink">When</label>
            <input id="recruiting-when-11"
              type="datetime-local"
              value={scheduledAt}
              onChange={(e) => setScheduledAt(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <button type="submit" className="rounded-lg bg-brand-blue px-3 py-2 text-xs font-medium text-white hover:bg-brand-blue-dark">
            Schedule
          </button>
        </form>
      )}
      {error && <p className="mt-2 text-xs text-brand-risk-text">{error}</p>}
    </div>
  )
}

function InterviewRow({
  iv,
  interviewer,
  feedback,
  canReopenFeedback,
  interviews,
  interviewers,
  busyId,
  reschedulingId,
  setReschedulingId,
  rescheduleAt,
  setRescheduleAt,
  rescheduleInterviewerAuthId,
  setRescheduleInterviewerAuthId,
  rescheduleReason,
  setRescheduleReason,
  handleReschedule,
  cancellingId,
  setCancellingId,
  cancelReason,
  setCancelReason,
  handleCancel,
  handleOutcome,
  reopeningId,
  setReopeningId,
  reopenReason,
  setReopenReason,
  handleReopen,
}: {
  iv: Interview
  interviewer: Pick<Employee, 'id' | 'full_name' | 'auth_user_id'> | undefined
  feedback: ApplicationInterviewFeedbackRow | null
  canReopenFeedback: boolean
  interviews: Interview[]
  interviewers: Pick<Employee, 'id' | 'full_name' | 'auth_user_id'>[]
  busyId: string | null
  reschedulingId: string | null
  setReschedulingId: (id: string | null) => void
  rescheduleAt: string
  setRescheduleAt: (v: string) => void
  rescheduleInterviewerAuthId: string
  setRescheduleInterviewerAuthId: (v: string) => void
  rescheduleReason: string
  setRescheduleReason: (v: string) => void
  handleReschedule: (id: string) => void
  cancellingId: string | null
  setCancellingId: (id: string | null) => void
  cancelReason: string
  setCancelReason: (v: string) => void
  handleCancel: (id: string) => void
  handleOutcome: (id: string, outcome: 'pass' | 'fail') => void
  reopeningId: string | null
  setReopeningId: (id: string | null) => void
  reopenReason: string
  setReopenReason: (v: string) => void
  handleReopen: (id: string) => void
}) {
  // Which source interviews already have a follow-up — reschedule_interview()
  // itself blocks a second reschedule from the same source (idempotency), so
  // this is purely to hide the button/avoid a guaranteed-to-fail click; the
  // RPC's own check is the real guard, not this derived set.
  const rescheduledFromIds = new Set(
    interviews.filter((other) => other.rescheduled_from_interview_id).map((other) => other.rescheduled_from_interview_id as string)
  )
  const cancelled = Boolean(iv.cancelled_at)
  const alreadyRescheduled = rescheduledFromIds.has(iv.id)
  const rescheduledFrom = iv.rescheduled_from_interview_id
    ? interviews.find((other) => other.id === iv.rescheduled_from_interview_id)
    : null

  return (
    <li className="rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-ink">
                    {fmtDateTime(iv.scheduled_at)} · {interviewer?.full_name ?? 'Unassigned'}
                  </span>
                  <span className="flex items-center gap-1">
                    {cancelled ? (
                      <StatusBadge status="cancelled" />
                    ) : iv.outcome === 'pending' ? (
                      <span className="flex gap-1">
                        <button onClick={() => handleOutcome(iv.id, 'pass')} className="rounded-full bg-brand-action-soft px-2 py-1 font-medium text-brand-action-text">
                          Pass
                        </button>
                        <button onClick={() => handleOutcome(iv.id, 'fail')} className="rounded-full bg-brand-risk-soft px-2 py-1 font-medium text-brand-risk-text">
                          Fail
                        </button>
                      </span>
                    ) : (
                      <StatusBadge status={iv.outcome} tone={iv.outcome === 'pass' ? 'success' : 'risk'} />
                    )}
                    {!alreadyRescheduled && (
                      <button
                        onClick={() => {
                          setReschedulingId(reschedulingId === iv.id ? null : iv.id)
                          setRescheduleInterviewerAuthId(iv.interviewer_id)
                        }}
                        className="rounded-full border border-border px-2 py-1 font-medium text-brand-blue hover:border-brand-blue/30"
                      >
                        Reschedule
                      </button>
                    )}
                    {!cancelled && (
                      <button
                        onClick={() => setCancellingId(cancellingId === iv.id ? null : iv.id)}
                        className="rounded-full border border-border px-2 py-1 font-medium text-muted hover:border-brand-risk/40 hover:text-brand-risk"
                      >
                        Cancel
                      </button>
                    )}
                  </span>
                </div>

                {cancelled && iv.cancellation_reason && (
                  <p className="mt-1 text-brand-risk-text">Cancelled: {iv.cancellation_reason}</p>
                )}
                {rescheduledFrom && (
                  <p className="mt-1 text-muted">
                    Rescheduled from {fmtDateTime(rescheduledFrom.scheduled_at)}
                  </p>
                )}
                {alreadyRescheduled && <p className="mt-1 text-muted">Rescheduled — see the follow-up interview below.</p>}

                {reschedulingId === iv.id && (
                  <div className="mt-2 flex flex-wrap items-end gap-2 rounded-lg border border-border bg-surface p-2">
                    <div>
                      <label htmlFor="recruiting-new-date-time-12" className="mb-1 block text-xs font-medium text-ink">New date/time</label>
                      <input id="recruiting-new-date-time-12"
                        type="datetime-local"
                        value={rescheduleAt}
                        onChange={(e) => setRescheduleAt(e.target.value)}
                        className="rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                      />
                    </div>
                    <div>
                      <label htmlFor="recruiting-interviewer-13" className="mb-1 block text-xs font-medium text-ink">Interviewer</label>
                      <select id="recruiting-interviewer-13"
                        value={rescheduleInterviewerAuthId}
                        onChange={(e) => setRescheduleInterviewerAuthId(e.target.value)}
                        className="rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                      >
                        {interviewers.map((e) => (
                          <option key={e.id} value={e.auth_user_id ?? ''}>
                            {e.full_name}
                          </option>
                        ))}
                      </select>
                    </div>
                    <input
                      aria-label="Reason for rescheduling"
                      value={rescheduleReason}
                      onChange={(e) => setRescheduleReason(e.target.value)}
                      placeholder="Reason (optional)"
                      className="flex-1 rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                    />
                    <button
                      onClick={() => handleReschedule(iv.id)}
                      disabled={busyId === iv.id}
                      className="rounded-lg bg-brand-blue px-2 py-1.5 font-medium text-white disabled:opacity-60"
                    >
                      {busyId === iv.id ? 'Rescheduling…' : 'Confirm reschedule'}
                    </button>
                    <button onClick={() => setReschedulingId(null)} className="text-muted hover:text-ink">
                      Back
                    </button>
                  </div>
                )}

                {cancellingId === iv.id && (
                  <div className="mt-2 flex flex-wrap items-center gap-2 rounded-lg border border-border bg-surface p-2">
                    <input
                      aria-label="Cancellation reason"
                      value={cancelReason}
                      onChange={(e) => setCancelReason(e.target.value)}
                      placeholder="Cancellation reason (required)"
                      className="flex-1 rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                    />
                    <button
                      onClick={() => handleCancel(iv.id)}
                      disabled={busyId === iv.id}
                      className="rounded-lg bg-brand-risk px-2 py-1.5 font-medium text-white disabled:opacity-60"
                    >
                      {busyId === iv.id ? 'Cancelling…' : 'Confirm cancel'}
                    </button>
                    <button onClick={() => setCancellingId(null)} className="text-muted hover:text-ink">
                      Back
                    </button>
                  </div>
                )}

                {feedback && !feedback.feedback_visible && (
                  <div className="mt-2 rounded-lg border border-border bg-surface p-2 text-muted">
                    Feedback stays private until every interviewer for this stage submits, or a Recruiting Admin closes the round.
                  </div>
                )}
                {feedback && feedback.feedback_visible && (
                  <div className="mt-2 rounded-lg border border-border bg-surface p-2">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="font-medium text-ink">
                        Feedback:{' '}
                        {feedback.feedback_status === 'submitted'
                          ? 'Submitted'
                          : feedback.feedback_status === 'reopened'
                            ? 'Reopened'
                            : feedback.feedback_status === 'draft'
                              ? 'Draft'
                              : 'Not started'}
                        {feedback.recommendation ? ` · ${feedback.recommendation.replace('_', ' ')}` : ''}
                      </span>
                      {feedback.feedback_status === 'submitted' && canReopenFeedback && (
                        <button
                          onClick={() => setReopeningId(reopeningId === iv.id ? null : iv.id)}
                          className="rounded-full border border-border px-2 py-1 font-medium text-brand-blue hover:border-brand-blue/30"
                        >
                          Reopen
                        </button>
                      )}
                    </div>
                    {feedback.strengths && <p className="mt-1 text-muted">Strengths: {feedback.strengths}</p>}
                    {feedback.concerns && <p className="text-muted">Concerns: {feedback.concerns}</p>}
                    {feedback.notes && <p className="text-muted">Notes: {feedback.notes}</p>}
                    {feedback.feedback_status !== 'submitted' && feedback.feedback_status !== null && (
                      <p className="mt-1 text-muted">Interviewer hasn't submitted final feedback yet.</p>
                    )}
                    {feedback.feedback_status === null && (
                      <p className="mt-1 text-muted">No feedback saved yet.</p>
                    )}
                    {reopeningId === iv.id && (
                      <div className="mt-2 flex flex-wrap items-center gap-2">
                        <input
                          aria-label="Reason for reopening"
                          value={reopenReason}
                          onChange={(e) => setReopenReason(e.target.value)}
                          placeholder="Reason for reopening (required, audited)"
                          className="flex-1 rounded-lg border border-border px-2 py-1.5 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                        />
                        <button
                          onClick={() => handleReopen(iv.id)}
                          disabled={busyId === iv.id}
                          className="rounded-lg bg-brand-blue px-2 py-1.5 font-medium text-white disabled:opacity-60"
                        >
                          {busyId === iv.id ? 'Reopening…' : 'Confirm reopen'}
                        </button>
                        <button onClick={() => setReopeningId(null)} className="text-muted hover:text-ink">
                          Back
                        </button>
                      </div>
                    )}
                  </div>
                )}
              </li>
  )
}

function OfferSection({
  applicationId,
  positionId,
  offer,
  currency,
  onChange,
  onNotice,
}: {
  applicationId: string
  positionId: string
  offer: Offer | null
  currency: string
  onChange: () => void
  onNotice: (msg: string) => void
}) {
  const [salary, setSalary] = useState('')
  const [startDate, setStartDate] = useState('')
  const [declineReason, setDeclineReason] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function handleCreate(e: FormEvent) {
    e.preventDefault()
    if (!salary || !startDate) {
      setError('Enter a salary and a start date.')
      return
    }
    setBusy(true)
    setError(null)
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const { error: insertError } = await supabase.from('offers').insert({
      application_id: applicationId,
      position_id: positionId,
      proposed_salary_amount: Number(salary),
      proposed_start_date: startDate,
      created_by: user?.id ?? null,
    })
    setBusy(false)
    if (insertError) {
      setError(insertError.message)
      return
    }
    onChange()
  }

  async function handleSend() {
    if (!offer) return
    const {
      data: { user },
    } = await supabase.auth.getUser()
    const { error: updateError } = await supabase
      .from('offers')
      .update({ status: 'sent', sent_by: user?.id ?? null, sent_at: new Date().toISOString() })
      .eq('id', offer.id)
    if (updateError) {
      setError(updateError.message)
      return
    }
    onChange()
  }

  async function handleDecision(status: 'accepted' | 'declined' | 'rescinded') {
    if (!offer) return
    if (status !== 'accepted' && !declineReason.trim()) {
      setError('A reason is required to decline or rescind an offer.')
      return
    }
    const { error: updateError } = await supabase
      .from('offers')
      .update({
        status,
        decided_at: new Date().toISOString(),
        decision_reason: status === 'accepted' ? null : declineReason.trim(),
      })
      .eq('id', offer.id)
    if (updateError) {
      setError(updateError.message)
      return
    }
    onChange()
  }

  async function handleConvert() {
    if (!offer) return
    if (!(await confirmDialog('Convert this accepted offer into a new employee record (pre-boarding)?'))) return
    setBusy(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('convert_offer_to_employee', { p_offer_id: offer.id })
    setBusy(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    onNotice('Converted to a new employee record (pre-boarding). Add payroll and compensation details separately.')
    onChange()
  }

  return (
    <div className="border-t border-border pt-4">
      <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Offer</p>
      {error && <p className="mb-2 text-xs text-brand-risk-text">{error}</p>}

      {!offer ? (
        <form onSubmit={handleCreate} className="flex flex-wrap items-end gap-2">
          <div>
            <label htmlFor="recruiting-proposed-salary-14" className="mb-1 block text-xs font-medium text-ink">Proposed salary</label>
            <input id="recruiting-proposed-salary-14"
              type="number"
              min="0"
              step="0.01"
              value={salary}
              onChange={(e) => setSalary(e.target.value)}
              className="w-32 rounded-lg border border-border px-3 py-2 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <div>
            <label htmlFor="recruiting-start-date-15" className="mb-1 block text-xs font-medium text-ink">Start date</label>
            <input id="recruiting-start-date-15"
              type="date"
              value={startDate}
              onChange={(e) => setStartDate(e.target.value)}
              className="rounded-lg border border-border px-3 py-2 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <button type="submit" disabled={busy} className="rounded-lg bg-brand-blue px-3 py-2 text-xs font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60">
            Create draft offer
          </button>
        </form>
      ) : (
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <StatusBadge status={offer.status} />
            <span className="text-sm text-ink">
              {money(offer.proposed_salary_amount, currency)} · starts {offer.proposed_start_date}
            </span>
          </div>
          {offer.decision_reason && <p className="text-xs text-brand-risk-text">Reason: {offer.decision_reason}</p>}

          {offer.status === 'draft' && (
            <button onClick={handleSend} className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-blue-dark">
              Send offer
            </button>
          )}

          {offer.status === 'sent' && (
            <div className="space-y-2">
              <input
                aria-label="Reason for declining or rescinding"
                value={declineReason}
                onChange={(e) => setDeclineReason(e.target.value)}
                placeholder="Reason (required if declining/rescinding)"
                className="w-full rounded-lg border border-border px-3 py-2 text-xs text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              />
              <div className="flex gap-2">
                <button onClick={() => handleDecision('accepted')} className="rounded-lg bg-brand-action-soft px-3 py-1.5 text-xs font-medium text-brand-action-text">
                  Mark accepted
                </button>
                <button onClick={() => handleDecision('declined')} className="rounded-lg bg-brand-risk-soft px-3 py-1.5 text-xs font-medium text-brand-risk-text">
                  Mark declined
                </button>
                <button onClick={() => handleDecision('rescinded')} className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-muted">
                  Rescind
                </button>
              </div>
            </div>
          )}

          {offer.status === 'accepted' && !offer.converted_employee_id && (
            <button
              onClick={handleConvert}
              disabled={busy}
              className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
            >
              {busy ? 'Converting…' : 'Convert to employee'}
            </button>
          )}

          {offer.converted_employee_id && (
            <p className="text-xs text-brand-action-text">Converted to a new employee record.</p>
          )}
        </div>
      )}
    </div>
  )
}
