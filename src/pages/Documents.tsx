import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import {
  DOC_TYPES, canRoleSeeDocType, docTypeLabel, expiryStatus, type ExpiryStatus,
  REQ_STATUS_LABEL, type DocumentRequirement, type DocumentRequirementStatus,
} from '../lib/documents'
import type { DocumentReviewStatus, Employee, EmployeeDocument } from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'
import { confirmDialog } from '../lib/confirm'

const BUCKET = 'employee-documents'

const REVIEW_FILTERS: { value: DocumentReviewStatus | 'all' | 'current'; label: string }[] = [
  { value: 'current', label: 'Current' },
  { value: 'pending_review', label: 'Pending review' },
  { value: 'rejected', label: 'Rejected' },
  { value: 'superseded', label: 'Superseded' },
  { value: 'archived', label: 'Archived' },
  { value: 'all', label: 'All versions' },
]

// UX-05 Documents, expiry and renewal review.
//
// review_status (approval workflow) and expiry status (computed from
// expiry_date) are deliberately independent — a document can be Approved
// and Expiring at the same time, and this screen shows both badges rather
// than conflating them.
export default function Documents() {
  const { profile, activeEntityId, session } = useAuth()
  const currentUserId = session?.user.id ?? null
  const canManage = profile?.role === 'owner' || profile?.role === 'entity_admin' || profile?.role === 'location_manager'

  const [documents, setDocuments] = useState<EmployeeDocument[]>([])
  const [employees, setEmployees] = useState<Pick<Employee, 'id' | 'full_name'>[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const [tab, setTab] = useState<'register' | 'checklist'>('register')
  const [search, setSearch] = useState('')
  const [typeFilter, setTypeFilter] = useState<string>('all')
  const [expiryFilter, setExpiryFilter] = useState<ExpiryStatus | 'all'>('all')
  const [reviewFilter, setReviewFilter] = useState<DocumentReviewStatus | 'all' | 'current'>('current')
  const [uploadOpen, setUploadOpen] = useState(false)
  const [uploadPreEmployee, setUploadPreEmployee] = useState<string | null>(null)
  const [uploadPreDocType, setUploadPreDocType] = useState<string | null>(null)
  // Tracked explicitly rather than inferred from uploadPreEmployee — a staff
  // member fulfilling their own missing/rejected requirement also needs
  // preEmployeeId set (to their own id, for the read-only display + RPC
  // call), but that is a self-upload, not a manager uploading "on behalf".
  const [uploadKind, setUploadKind] = useState<'self' | 'assisted'>('self')
  const [reviewDoc, setReviewDoc] = useState<EmployeeDocument | null>(null)
  const [renewalDoc, setRenewalDoc] = useState<EmployeeDocument | null>(null)
  const [renewalAssisted, setRenewalAssisted] = useState(false)
  const [myRequirements, setMyRequirements] = useState<DocumentRequirement[]>([])

  async function load() {
    if (!activeEntityId) return
    setLoading(true)
    setError(null)

    // Phase 2.10: a location_manager now goes through get_documents_for_review()
    // rather than a raw table select. Row-level security can only include or
    // exclude a whole row, not redact individual columns — this RPC is what
    // lets a location_manager see limited metadata (doc type, expiry,
    // review/version state) for a sensitive doc_type while storage_path and
    // notes come back null for exactly those rows, so there is nothing to
    // sign a URL from even if the "View" action were mistakenly wired up.
    // Owner/entity_admin keep the original raw select — their access is
    // already unredacted and unchanged by this phase.
    const [docsRes, employeesRes, requirementsRes] = await Promise.all([
      profile?.role === 'location_manager'
        ? supabase.rpc('get_documents_for_review', { p_entity_id: activeEntityId }).then((res) => ({
            data: (res.data ?? []).map((row: Record<string, unknown>) => ({
              ...row,
              employees: { id: row.employee_id, full_name: row.employee_name },
            })),
            error: res.error,
          }))
        : supabase
            .from('employee_documents')
            .select(
              'id, employee_id, doc_type, storage_path, expiry_date, notes, review_status, version_number, supersedes_document_id, is_current, submitted_by, submitted_at, reviewed_by, reviewed_at, rejection_reason, archived_at, archived_by, created_at, updated_at, upload_confirmed, uploaded_by, upload_method, employees!inner(id, full_name, entity_id)'
            )
            .eq('employees.entity_id', activeEntityId)
            .order('submitted_at', { ascending: false }),
      canManage
        ? supabase.from('employees').select('id, full_name').eq('entity_id', activeEntityId).order('full_name')
        : Promise.resolve({ data: [] as { id: string; full_name: string }[], error: null }),
      // Requirements an admin has actually asked this employee for (seeded
      // via seed_document_requirements_for_employee — never auto-created),
      // so "My documents" can offer an upload action for those even when
      // nothing is expiring. Defaults to the caller's own employee record.
      !canManage
        ? supabase.rpc('get_document_requirements_for_employee', {})
        : Promise.resolve({ data: [] as DocumentRequirement[], error: null }),
    ])

    if (docsRes.error) setError(docsRes.error.message)
    else setDocuments((docsRes.data ?? []) as unknown as EmployeeDocument[])
    setEmployees(employeesRes.data ?? [])
    if (requirementsRes.error) setError(requirementsRes.error.message)
    setMyRequirements((requirementsRes.data ?? []) as unknown as DocumentRequirement[])
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeEntityId])

  const visibleDocTypes = useMemo(() => DOC_TYPES.filter((t) => canRoleSeeDocType(profile?.role, t.value)), [profile])

  function renewalFor(currentDocId: string) {
    return documents
      .filter((d) => d.supersedes_document_id === currentDocId)
      .sort((a, b) => b.submitted_at.localeCompare(a.submitted_at))[0]
  }

  // ---- Manager / owner register ----
  const managerRows = useMemo(() => {
    const q = search.trim().toLowerCase()
    return documents.filter((doc) => {
      if (typeFilter !== 'all' && doc.doc_type !== typeFilter) return false
      if (expiryFilter !== 'all' && expiryStatus(doc.expiry_date) !== expiryFilter) return false
      if (reviewFilter === 'current') {
        if (!(doc.is_current || doc.review_status === 'pending_review')) return false
      } else if (reviewFilter !== 'all' && doc.review_status !== reviewFilter) {
        return false
      }
      const name = doc.employees?.full_name?.toLowerCase() ?? ''
      if (q && !name.includes(q) && !doc.doc_type.toLowerCase().includes(q)) return false
      return true
    })
  }, [documents, search, typeFilter, expiryFilter, reviewFilter])

  // ---- Employee "My documents" ----
  const myCurrentDocs = useMemo(() => documents.filter((d) => d.is_current), [documents])

  async function handleView(doc: EmployeeDocument) {
    if (!doc.storage_path) {
      setError('This document type is not visible to your role — only limited metadata (expiry, review status) is shown.')
      return
    }
    const { error: logError } = await supabase.rpc('log_document_access', {
      p_document_id: doc.id,
      p_action: 'download',
    })
    if (logError) {
      setError(`Not authorized to open that file: ${logError.message}`)
      return
    }
    const { data, error: signError } = await supabase.storage.from(BUCKET).createSignedUrl(doc.storage_path, 60)
    if (signError || !data) {
      setError(`Couldn't open that file: ${signError?.message ?? 'unknown error'}`)
      return
    }
    window.open(data.signedUrl, '_blank', 'noopener,noreferrer')
  }

  async function handleApprove(doc: EmployeeDocument) {
    const { error: rpcError } = await supabase.rpc('approve_document', { p_document_id: doc.id })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setReviewDoc(null)
    await load()
  }

  async function handleReject(doc: EmployeeDocument, reason: string) {
    const { error: rpcError } = await supabase.rpc('reject_document', { p_document_id: doc.id, p_reason: reason })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setReviewDoc(null)
    await load()
  }

  async function handleArchive(doc: EmployeeDocument) {
    if (!(await confirmDialog(`Archive this ${docTypeLabel(doc.doc_type)}? It will stay on record but stop showing as current.`))) return
    const { error: rpcError } = await supabase.rpc('archive_document', { p_document_id: doc.id })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    await load()
  }

  async function handleDiscardPending(doc: EmployeeDocument) {
    if (!(await confirmDialog('Discard this pending upload? This cannot be undone.'))) return
    // Storage RLS requires the row to still exist (pending_review, not
    // current) at the moment the object is removed, so remove the file
    // before deleting the row, not after.
    await supabase.storage.from(BUCKET).remove([doc.storage_path])
    const { error: rpcError } = await supabase.rpc('delete_pending_document', { p_document_id: doc.id })
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    await load()
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <EntityEyebrow />
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">
            {canManage ? 'Documents' : 'My documents'}
          </h1>
          <p className="text-xs text-muted">
            {loading ? 'Loading…' : canManage ? `${managerRows.length} of ${documents.length} document versions` : ''}
          </p>
        </div>
        {canManage && (
          <button
            onClick={() => {
              setUploadKind('self')
              setUploadOpen(true)
            }}
            className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark"
          >
            Upload document
          </button>
        )}
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

      {profile?.role === 'owner' && <EntityAdminSelfApprovalToggle />}
      {(profile?.role === 'owner' || profile?.role === 'entity_admin') && (
        <CleanupIncompleteUploadsButton onDone={setNotice} onError={setError} />
      )}

      {canManage && (
        <div className="flex gap-1 border-b border-border">
          <button
            onClick={() => setTab('register')}
            className={`-mb-px px-4 py-2 text-sm font-medium ${tab === 'register' ? 'border-b-2 border-brand-blue text-brand-blue' : 'text-muted hover:text-ink'}`}
          >
            Document register
          </button>
          <button
            onClick={() => setTab('checklist')}
            className={`-mb-px px-4 py-2 text-sm font-medium ${tab === 'checklist' ? 'border-b-2 border-brand-blue text-brand-blue' : 'text-muted hover:text-ink'}`}
          >
            Employee checklist
          </button>
        </div>
      )}

      {canManage ? (
        tab === 'register' ? (
          <ManagerRegister
            rows={managerRows}
            totalCount={documents.length}
            loading={loading}
            docTypes={visibleDocTypes}
            search={search}
            setSearch={setSearch}
            typeFilter={typeFilter}
            setTypeFilter={setTypeFilter}
            expiryFilter={expiryFilter}
            setExpiryFilter={setExpiryFilter}
            reviewFilter={reviewFilter}
            setReviewFilter={setReviewFilter}
            onView={handleView}
            onReview={setReviewDoc}
            onArchive={handleArchive}
            onDiscardPending={handleDiscardPending}
            onRenew={(doc) => {
              setRenewalAssisted(true)
              setRenewalDoc(doc)
            }}
            pendingRenewalFor={
              new Set(
                documents
                  .filter((d) => d.review_status === 'pending_review' && d.upload_confirmed && d.supersedes_document_id)
                  .map((d) => d.supersedes_document_id as string)
              )
            }
          />
        ) : (
          <ChecklistTab
            employees={employees}
            docTypes={visibleDocTypes}
            loading={loading}
            onUploadOnBehalf={(employeeId, docType) => {
              setUploadKind('assisted')
              setUploadPreEmployee(employeeId)
              setUploadPreDocType(docType)
              setUploadOpen(true)
            }}
          />
        )
      ) : (
        <MyDocuments
          currentDocs={myCurrentDocs}
          renewalFor={renewalFor}
          requirements={myRequirements}
          documents={documents}
          loading={loading}
          onView={handleView}
          onUploadRenewal={(doc) => {
            setRenewalAssisted(false)
            setRenewalDoc(doc)
          }}
          onUploadRequirement={(employeeId, docType) => {
            setUploadKind('self')
            setUploadPreEmployee(employeeId)
            setUploadPreDocType(docType)
            setUploadOpen(true)
          }}
        />
      )}

      {uploadOpen && (
        <UploadDocumentModal
          employees={employees}
          docTypes={visibleDocTypes}
          preEmployeeId={uploadPreEmployee}
          preDocType={uploadPreDocType}
          uploadMethod={uploadKind}
          onClose={() => {
            setUploadOpen(false)
            setUploadPreEmployee(null)
            setUploadPreDocType(null)
            setUploadKind('self')
          }}
          onUploaded={(message) => {
            setUploadOpen(false)
            setUploadPreEmployee(null)
            setUploadPreDocType(null)
            setUploadKind('self')
            setNotice(message)
            load()
          }}
          onError={setError}
        />
      )}

      {reviewDoc && (
        <ReviewDrawer
          doc={reviewDoc}
          history={documents.filter(
            (d) => d.employee_id === reviewDoc.employee_id && d.doc_type === reviewDoc.doc_type
          )}
          currentUserId={currentUserId}
          isOwner={profile?.role === 'owner'}
          onClose={() => setReviewDoc(null)}
          onView={handleView}
          onApprove={handleApprove}
          onReject={handleReject}
        />
      )}

      {renewalDoc && (
        <RenewalModal
          currentDoc={renewalDoc}
          assisted={renewalAssisted}
          onClose={() => setRenewalDoc(null)}
          onSubmitted={(message) => {
            setRenewalDoc(null)
            setNotice(message)
            load()
          }}
        />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Owner/entity_admin: incomplete-upload cleanup (Phase 2.10)
// ---------------------------------------------------------------------------

// A staged upload (stage_document_upload / stage_document_renewal) that
// never got confirmed — the browser closed, the network dropped between the
// storage upload and the confirm call — leaves a harmless, inspectable
// pending row rather than an invisible orphaned file. This is a manual sweep
// (no scheduler in this app), matching how the rest of this codebase treats
// anything that touches multiple systems as a deliberate, explicit action.
function CleanupIncompleteUploadsButton({
  onDone,
  onError,
}: {
  onDone: (message: string) => void
  onError: (message: string) => void
}) {
  const [running, setRunning] = useState(false)

  async function handleRun() {
    setRunning(true)
    const { data, error } = await supabase.rpc('cleanup_incomplete_document_uploads', { p_older_than_hours: 24 })
    setRunning(false)
    if (error) {
      onError(error.message)
      return
    }
    onDone(`Cleanup complete — removed ${data ?? 0} incomplete upload(s) older than 24 hours.`)
  }

  return (
    <button
      onClick={handleRun}
      disabled={running}
      className="self-start rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-muted hover:border-brand-blue/30 hover:text-ink disabled:opacity-60"
    >
      {running ? 'Cleaning up…' : 'Clean up incomplete uploads'}
    </button>
  )
}

// ---------------------------------------------------------------------------
// Owner-only: Entity Admin self-approval setting
// ---------------------------------------------------------------------------

// Entity Admins may only self-approve their own non-sensitive uploads once
// the owner has formally turned this on (public.entity_admin_self_approval_enabled()).
// It's off by default and never applies to sensitive document types
// regardless of this setting — that's enforced in the database, not here.
function EntityAdminSelfApprovalToggle() {
  const [enabled, setEnabled] = useState<boolean | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    supabase.rpc('entity_admin_self_approval_enabled').then(({ data, error: rpcError }) => {
      if (!rpcError) setEnabled(Boolean(data))
    })
  }, [])

  async function toggle() {
    if (enabled === null) return
    setSaving(true)
    setError(null)
    const next = !enabled
    const { error: rpcError } = await supabase.rpc('set_entity_admin_self_approval', { p_enabled: next })
    setSaving(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    setEnabled(next)
  }

  if (enabled === null) return null

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-[14px] border border-border bg-surface p-4 shadow-card">
      <div>
        <p className="text-sm font-medium text-ink">Entity Admin self-approval</p>
        <p className="text-xs text-muted">
          When on, an Entity Admin may approve their own uploads of ordinary operational documents. Sensitive
          documents (passport, Emirates ID, visa, contract, bank/payment, compensation) always require Owner
          approval regardless of this setting.
        </p>
        {error && <p className="mt-1 text-xs text-brand-risk-text">{error}</p>}
      </div>
      <button
        onClick={toggle}
        disabled={saving}
        className={`rounded-full px-3 py-1.5 text-xs font-semibold transition disabled:opacity-60 ${
          enabled ? 'bg-brand-action-soft text-brand-action-text' : 'bg-surface-alt text-muted'
        }`}
      >
        {enabled ? 'Enabled' : 'Disabled'}
      </button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Manager / owner register
// ---------------------------------------------------------------------------

function ManagerRegister({
  rows,
  totalCount,
  loading,
  docTypes,
  search,
  setSearch,
  typeFilter,
  setTypeFilter,
  expiryFilter,
  setExpiryFilter,
  reviewFilter,
  setReviewFilter,
  onView,
  onReview,
  onArchive,
  onDiscardPending,
  onRenew,
  pendingRenewalFor,
}: {
  rows: EmployeeDocument[]
  totalCount: number
  loading: boolean
  docTypes: typeof DOC_TYPES extends readonly (infer T)[] ? T[] : never
  search: string
  setSearch: (v: string) => void
  typeFilter: string
  setTypeFilter: (v: string) => void
  expiryFilter: ExpiryStatus | 'all'
  setExpiryFilter: (v: ExpiryStatus | 'all') => void
  reviewFilter: DocumentReviewStatus | 'all' | 'current'
  setReviewFilter: (v: DocumentReviewStatus | 'all' | 'current') => void
  onView: (doc: EmployeeDocument) => void
  onReview: (doc: EmployeeDocument) => void
  onArchive: (doc: EmployeeDocument) => void
  onDiscardPending: (doc: EmployeeDocument) => void
  onRenew: (doc: EmployeeDocument) => void
  pendingRenewalFor: Set<string>
}) {
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted w-full sm:w-64">
          Search
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search by employee or type"
            className="w-full flex-1 rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20 sm:w-64 sm:flex-none"
          />
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted">
          Review status
          <select
            value={reviewFilter}
            onChange={(e) => setReviewFilter(e.target.value as DocumentReviewStatus | 'all' | 'current')}
            className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            {REVIEW_FILTERS.map((f) => (
              <option key={f.value} value={f.value}>
                {f.label}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted">
          Document type
          <select
            value={typeFilter}
            onChange={(e) => setTypeFilter(e.target.value)}
            className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            <option value="all">All document types</option>
            {docTypes.map((t) => (
              <option key={t.value} value={t.value}>
                {t.label}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-muted">
          Expiry
          <select
            value={expiryFilter}
            onChange={(e) => setExpiryFilter(e.target.value as ExpiryStatus | 'all')}
            className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
          >
            <option value="all">All expiry statuses</option>
            <option value="current">Current</option>
            <option value="expiring">Expiring soon</option>
            <option value="expired">Expired</option>
            <option value="non_expiring">No expiry set</option>
          </select>
        </label>
      </div>

      {loading ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-16 animate-pulse rounded-[14px] bg-surface md:h-12" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <EmptyState
          title={totalCount === 0 ? 'No documents on file yet' : 'No documents match your filters'}
          description={
            totalCount === 0
              ? 'Upload a passport, visa, contract or other record to get started.'
              : 'Try clearing the search or filters.'
          }
        />
      ) : (
        <>
          <div className="hidden overflow-hidden rounded-[14px] border border-border bg-surface shadow-card md:block">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-surface-alt text-xs uppercase tracking-wide text-muted">
                <tr>
                  <th className="px-4 py-3 font-medium">Employee</th>
                  <th className="px-4 py-3 font-medium">Type</th>
                  <th className="px-4 py-3 font-medium">Version</th>
                  <th className="px-4 py-3 font-medium">Expiry</th>
                  <th className="px-4 py-3 font-medium">Approval</th>
                  <th className="px-4 py-3 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {rows.map((doc) => (
                  <tr key={doc.id} className="hover:bg-surface-alt/60">
                    <td className="px-4 py-3 font-medium text-ink">{doc.employees?.full_name ?? '—'}</td>
                    <td className="px-4 py-3 capitalize text-muted">{docTypeLabel(doc.doc_type)}</td>
                    <td className="px-4 py-3 text-muted">v{doc.version_number}</td>
                    <td className="px-4 py-3 text-muted">
                      {doc.is_current ? (
                        <StatusBadge status={expiryStatus(doc.expiry_date)} />
                      ) : (
                        <span className="text-xs">—</span>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <StatusBadge status={doc.review_status} />
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex justify-end gap-2">
                        {doc.review_status === 'pending_review' ? (
                          <>
                            <button
                              onClick={() => onReview(doc)}
                              className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                            >
                              Review
                            </button>
                            {!doc.is_current && (
                              <button
                                onClick={() => onDiscardPending(doc)}
                                className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-risk-text hover:border-brand-risk/30"
                              >
                                Discard
                              </button>
                            )}
                          </>
                        ) : (
                          <>
                            <button
                              onClick={() => onView(doc)}
                              className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                            >
                              View
                            </button>
                            {doc.review_status === 'approved' && doc.is_current && !pendingRenewalFor.has(doc.id) && (
                              <button
                                onClick={() => onRenew(doc)}
                                className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                              >
                                Renew
                              </button>
                            )}
                            {doc.review_status === 'approved' && (
                              <button
                                onClick={() => onArchive(doc)}
                                className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-muted hover:border-ink/20"
                              >
                                Archive
                              </button>
                            )}
                          </>
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <ul className="space-y-3 md:hidden">
            {rows.map((doc) => (
              <li key={doc.id} className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="truncate font-medium text-ink">{doc.employees?.full_name}</p>
                    <p className="truncate text-sm capitalize text-muted">
                      {docTypeLabel(doc.doc_type)} · v{doc.version_number}
                    </p>
                  </div>
                  <StatusBadge status={doc.review_status} />
                </div>
                {doc.is_current && (
                  <p className="mt-2 text-xs text-muted">
                    {doc.expiry_date ? `Expires ${doc.expiry_date}` : 'No expiry date set'}
                  </p>
                )}
                <div className="mt-3 flex gap-2">
                  {doc.review_status === 'pending_review' ? (
                    <>
                      <button
                        onClick={() => onReview(doc)}
                        className="flex-1 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue"
                      >
                        Review
                      </button>
                      {!doc.is_current && (
                        <button
                          onClick={() => onDiscardPending(doc)}
                          className="flex-1 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-risk-text"
                        >
                          Discard
                        </button>
                      )}
                    </>
                  ) : (
                    <>
                      <button
                        onClick={() => onView(doc)}
                        className="flex-1 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue"
                      >
                        View
                      </button>
                      {doc.review_status === 'approved' && doc.is_current && !pendingRenewalFor.has(doc.id) && (
                        <button
                          onClick={() => onRenew(doc)}
                          className="flex-1 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue"
                        >
                          Renew
                        </button>
                      )}
                      {doc.review_status === 'approved' && (
                        <button
                          onClick={() => onArchive(doc)}
                          className="flex-1 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-muted"
                        >
                          Archive
                        </button>
                      )}
                    </>
                  )}
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Employee "My documents"
// ---------------------------------------------------------------------------

// A staff member may only ever initiate an upload for two reasons: their own
// document is actually expiring/expired (renewal), or an admin/manager has
// explicitly asked for something via seed_document_requirements_for_employee
// (a missing, rejected, or otherwise-open requirement). A document that is
// simply "current" offers no upload action at all — nothing to renew, and
// nothing requested.
const OPEN_REQUIREMENT_STATUSES: DocumentRequirementStatus[] = ['missing', 'pending_review', 'rejected']

function MyDocuments({
  currentDocs,
  renewalFor,
  requirements,
  documents,
  loading,
  onView,
  onUploadRenewal,
  onUploadRequirement,
}: {
  currentDocs: EmployeeDocument[]
  renewalFor: (currentDocId: string) => EmployeeDocument | undefined
  requirements: DocumentRequirement[]
  documents: EmployeeDocument[]
  loading: boolean
  onView: (doc: EmployeeDocument) => void
  onUploadRenewal: (doc: EmployeeDocument) => void
  onUploadRequirement: (employeeId: string, docType: string) => void
}) {
  if (loading) {
    return (
      <div className="space-y-2">
        {[0, 1, 2].map((i) => (
          <div key={i} className="h-20 animate-pulse rounded-[14px] bg-surface" />
        ))}
      </div>
    )
  }

  // Requirements already satisfied by a current, approved document don't
  // need a call to action — they're just what's rendered below as a normal
  // document row. Only surface the ones still needing the employee's input.
  const openRequirements = requirements.filter((r) => OPEN_REQUIREMENT_STATUSES.includes(r.status))

  if (currentDocs.length === 0 && openRequirements.length === 0) {
    return (
      <EmptyState
        title="No documents on file yet"
        description="Documents your admin uploads for you — passport, visa, contract and more — will show up here."
      />
    )
  }

  return (
    <div className="space-y-5">
      {openRequirements.length > 0 && (
        <section>
          <h2 className="mb-2 text-sm font-semibold text-ink">Requested by your admin</h2>
          <ul className="space-y-3">
            {openRequirements.map((req) => {
              const linkedDoc = req.document_id ? documents.find((d) => d.id === req.document_id) : undefined
              return (
                <li key={req.id} className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <p className="font-medium capitalize text-ink">{docTypeLabel(req.doc_type)}</p>
                    <StatusBadge status={req.status} tone={req.status === 'missing' ? 'risk' : undefined} />
                  </div>

                  {req.status === 'pending_review' && (
                    <p className="mt-2 text-xs text-muted">Uploaded — awaiting review.</p>
                  )}

                  {req.status === 'rejected' && (
                    <p className="mt-2 text-xs text-brand-risk-text">
                      {linkedDoc?.rejection_reason ? `Rejected: ${linkedDoc.rejection_reason}` : 'Your last upload was rejected.'}
                    </p>
                  )}

                  {(req.status === 'missing' || req.status === 'rejected') && (
                    <button
                      onClick={() => onUploadRequirement(req.employee_id, req.doc_type)}
                      className="mt-3 rounded-lg bg-brand-blue-soft px-3 py-1.5 text-xs font-medium text-brand-blue-text hover:bg-brand-blue-soft/70"
                    >
                      {req.status === 'rejected' ? 'Resubmit' : 'Upload'}
                    </button>
                  )}
                </li>
              )
            })}
          </ul>
        </section>
      )}

      {currentDocs.length > 0 && (
        <section>
          {openRequirements.length > 0 && <h2 className="mb-2 text-sm font-semibold text-ink">Your documents</h2>}
          <ul className="space-y-3">
            {currentDocs.map((doc) => {
              const pending = renewalFor(doc.id)
              const expiry = expiryStatus(doc.expiry_date)
              const canRenew = expiry === 'expiring' || expiry === 'expired'
              return (
                <li key={doc.id} className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div>
                      <p className="font-medium capitalize text-ink">{docTypeLabel(doc.doc_type)}</p>
                      <p className="text-xs text-muted">
                        {doc.expiry_date ? `Expires ${doc.expiry_date}` : 'No expiry date set'}
                      </p>
                    </div>
                    <StatusBadge status={expiry} />
                  </div>

                  <div className="mt-3 flex flex-wrap items-center gap-2">
                    <button
                      onClick={() => onView(doc)}
                      className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                    >
                      View current version
                    </button>

                    {/* Only an expiring/expired document may be renewed by the employee themselves — a
                        document in good standing has nothing to act on until it's close to expiry or an
                        admin specifically requests a fresh copy (handled by the section above). */}
                    {canRenew && !pending && (
                      <button
                        onClick={() => onUploadRenewal(doc)}
                        className="rounded-lg bg-brand-blue-soft px-3 py-1.5 text-xs font-medium text-brand-blue-text hover:bg-brand-blue-soft/70"
                      >
                        Upload renewal
                      </button>
                    )}
                  </div>

                  {pending?.review_status === 'pending_review' && (
                    <p className="mt-3 rounded-lg bg-brand-warning-soft px-3 py-2 text-xs text-brand-warning-solid">
                      Your renewal is pending review. The document above stays your current approved version until a
                      decision is made.
                    </p>
                  )}

                  {pending?.review_status === 'rejected' && (
                    <div className="mt-3 rounded-lg bg-brand-risk-soft px-3 py-2 text-xs text-brand-risk-text">
                      {/* Not gated on canRenew — a reviewer already engaged with this renewal and
                          rejected it, so resubmitting completes that review cycle rather than starting
                          an unprompted upload. */}
                      <p className="font-medium">Your last renewal was rejected: {pending.rejection_reason}</p>
                      <button
                        onClick={() => onUploadRenewal(doc)}
                        className="mt-2 rounded-lg border border-brand-risk/30 px-3 py-1 font-medium hover:bg-brand-risk-soft/60"
                      >
                        Resubmit
                      </button>
                    </div>
                  )}
                </li>
              )
            })}
          </ul>
        </section>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Manager review drawer (approve / reject + version history)
// ---------------------------------------------------------------------------

function ReviewDrawer({
  doc,
  history,
  currentUserId,
  isOwner,
  onClose,
  onView,
  onApprove,
  onReject,
}: {
  doc: EmployeeDocument
  history: EmployeeDocument[]
  currentUserId: string | null
  isOwner: boolean
  onClose: () => void
  onView: (doc: EmployeeDocument) => void
  onApprove: (doc: EmployeeDocument) => void
  onReject: (doc: EmployeeDocument, reason: string) => void
}) {
  const [reason, setReason] = useState('')
  const [showRejectForm, setShowRejectForm] = useState(false)
  const sortedHistory = [...history].sort((a, b) => b.version_number - a.version_number)
  // The owner may approve their own uploads; everyone else needs a second reviewer.
  const isSelfUpload = !isOwner && currentUserId != null && doc.uploaded_by === currentUserId

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-lg rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-1 flex items-start justify-between">
          <h2 className="text-base font-semibold text-ink">
            Review {docTypeLabel(doc.doc_type)} — {doc.employees?.full_name}
          </h2>
          <StatusBadge status={doc.review_status} />
        </div>
        <p className="mb-4 text-xs text-muted">
          Version {doc.version_number} · submitted {doc.submitted_at.slice(0, 10)}
        </p>

        <button
          onClick={() => onView(doc)}
          className="mb-4 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
        >
          View file
        </button>

        <div className="mb-4">
          <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Version history</p>
          <ul className="space-y-1.5">
            {sortedHistory.map((h) => (
              <li key={h.id} className="flex items-center justify-between rounded-lg bg-surface-alt px-3 py-2 text-xs">
                <span className="text-ink">v{h.version_number}</span>
                <StatusBadge status={h.review_status} />
              </li>
            ))}
          </ul>
        </div>

        {doc.review_status === 'pending_review' && (
          <div className="space-y-3 border-t border-border pt-4">
            {isSelfUpload ? (
              <p className="rounded-lg bg-brand-action-soft px-3 py-2 text-xs text-brand-action-text">
                You uploaded this document, so someone else must review it.
              </p>
            ) : !showRejectForm ? (
              <div className="flex justify-end gap-2">
                <button
                  onClick={() => setShowRejectForm(true)}
                  className="rounded-lg border border-border px-4 py-2 text-sm font-medium text-brand-risk-text hover:border-brand-risk/30"
                >
                  Reject
                </button>
                <button
                  onClick={() => onApprove(doc)}
                  className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark"
                >
                  Approve
                </button>
              </div>
            ) : (
              <div className="space-y-2">
                <label htmlFor="documents-rejection-reason-require-1" className="block text-sm font-medium text-ink">Rejection reason (required)</label>
                <textarea id="documents-rejection-reason-require-1"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  rows={2}
                  className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                />
                <div className="flex justify-end gap-2">
                  <button
                    onClick={() => setShowRejectForm(false)}
                    className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
                  >
                    Cancel
                  </button>
                  <button
                    onClick={() => reason.trim() && onReject(doc, reason.trim())}
                    disabled={!reason.trim()}
                    className="rounded-lg bg-brand-risk px-4 py-2 text-sm font-medium text-white hover:bg-brand-risk/90 disabled:opacity-50"
                  >
                    Confirm rejection
                  </button>
                </div>
              </div>
            )}
          </div>
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

// ---------------------------------------------------------------------------
// Manager first-time upload
// ---------------------------------------------------------------------------

function UploadDocumentModal({
  employees,
  docTypes,
  preEmployeeId,
  preDocType,
  uploadMethod = 'self',
  onClose,
  onUploaded,
  onError,
}: {
  employees: Pick<Employee, 'id' | 'full_name'>[]
  docTypes: typeof DOC_TYPES extends readonly (infer T)[] ? T[] : never
  preEmployeeId?: string | null
  preDocType?: string | null
  uploadMethod?: 'self' | 'assisted'
  onClose: () => void
  onUploaded: (message: string) => void
  onError: (msg: string) => void
}) {
  const [employeeId, setEmployeeId] = useState(preEmployeeId ?? employees[0]?.id ?? '')
  const [docType, setDocType] = useState<string>(preDocType ?? docTypes[0]?.value ?? 'other')
  const [expiryDate, setExpiryDate] = useState('')
  const [notes, setNotes] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!file || !employeeId) {
      setError('Choose an employee and a file to upload.')
      return
    }
    const ext = file.name.split('.').pop()?.toLowerCase() ?? ''
    if (!['pdf', 'jpg', 'jpeg', 'png'].includes(ext)) {
      setError('Only PDF, JPG and PNG files are accepted.')
      return
    }
    setSubmitting(true)
    setError(null)

    // Phase 2.10 staged upload: a pending row is created first
    // (stage_document_upload), with the storage path entirely server-derived
    // — the original file name never appears in the storage key. Only after
    // the bytes are actually in place does confirm_document_upload flip the
    // row to real (and, for an owner/self-approving entity_admin upload,
    // immediately approve it) — it independently checks storage.objects
    // rather than trusting that the upload call here succeeded.
    const { data: stageData, error: stageError } = await supabase.rpc('stage_document_upload', {
      p_employee_id: employeeId,
      p_doc_type: docType,
      p_file_extension: ext,
      p_expiry_date: expiryDate || null,
      p_notes: notes || null,
      p_upload_method: uploadMethod,
    })
    if (stageError) {
      setSubmitting(false)
      if (stageError.message.includes('one_current_per_type')) {
        onError(
          'This employee already has a current document of that type. Open its row and use the renewal workflow to replace it instead of uploading a duplicate.'
        )
      } else {
        setError(stageError.message)
      }
      return
    }
    const { id: documentId, storage_path: path } = stageData as { id: string; storage_path: string }

    const { error: uploadError } = await supabase.storage.from(BUCKET).upload(path, file, { upsert: false })
    if (uploadError) {
      setSubmitting(false)
      setError(`Upload failed: ${uploadError.message}. The staged record will be cleaned up automatically.`)
      return
    }

    const { data: confirmData, error: confirmError } = await supabase.rpc('confirm_document_upload', {
      p_document_id: documentId,
    })
    setSubmitting(false)
    if (confirmError) {
      setError(confirmError.message)
      return
    }
    const result = confirmData as { ok: boolean; code?: string; review_status?: string }
    if (!result.ok) {
      setError(result.code === 'UPLOAD_NOT_FOUND' ? 'The upload did not complete — please try again.' : 'Could not confirm the upload.')
      return
    }
    onUploaded(
      result.review_status === 'approved'
        ? 'Uploaded and approved.'
        : uploadMethod === 'assisted'
          ? 'Uploaded and submitted for line manager review.'
          : 'Uploaded — pending review.'
    )
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-base font-semibold text-ink">Upload document</h2>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="documents-employee-2" className="mb-1 block text-sm font-medium text-ink">
              Employee{uploadMethod === 'assisted' && <span className="ml-1 text-xs text-muted">(uploading on behalf)</span>}
            </label>
            {preEmployeeId ? (
              <p className="rounded-lg border border-border bg-surface-alt px-3 py-2 text-sm text-ink">
                {uploadMethod === 'self' ? 'You' : (employees.find((e) => e.id === preEmployeeId)?.full_name ?? preEmployeeId)}
              </p>
            ) : (
              <select id="documents-employee-2"
                value={employeeId}
                onChange={(e) => setEmployeeId(e.target.value)}
                required
                className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              >
                {employees.map((emp) => (
                  <option key={emp.id} value={emp.id}>
                    {emp.full_name}
                  </option>
                ))}
              </select>
            )}
          </div>
          <div>
            <label htmlFor="documents-document-type-3" className="mb-1 block text-sm font-medium text-ink">Document type</label>
            {preDocType ? (
              <p className="rounded-lg border border-border bg-surface-alt px-3 py-2 text-sm text-ink capitalize">
                {docTypes.find((t) => t.value === preDocType)?.label ?? preDocType.replace(/_/g, ' ')}
              </p>
            ) : (
              <select id="documents-document-type-3"
                value={docType}
                onChange={(e) => setDocType(e.target.value)}
                className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              >
                {docTypes.map((t) => (
                  <option key={t.value} value={t.value}>
                    {t.label}
                  </option>
                ))}
              </select>
            )}
          </div>
          <div>
            <label htmlFor="documents-expiry-date-optional-4" className="mb-1 block text-sm font-medium text-ink">Expiry date (optional)</label>
            <input id="documents-expiry-date-optional-4"
              type="date"
              value={expiryDate}
              onChange={(e) => setExpiryDate(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <div>
            <label htmlFor="documents-file-5" className="mb-1 block text-sm font-medium text-ink">File</label>
            <input id="documents-file-5"
              type="file"
              required
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink file:mr-3 file:rounded-md file:border-0 file:bg-brand-blue-soft file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-brand-blue-text"
            />
          </div>
          <div>
            <label htmlFor="documents-notes-optional-6" className="mb-1 block text-sm font-medium text-ink">Notes (optional)</label>
            <textarea id="documents-notes-optional-6"
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
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
              {submitting ? 'Uploading…' : 'Upload'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Manager checklist tab — per-employee requirement status + upload on behalf
// ---------------------------------------------------------------------------

function ChecklistTab({
  employees,
  loading,
  onUploadOnBehalf,
}: {
  employees: Pick<Employee, 'id' | 'full_name'>[]
  docTypes: typeof DOC_TYPES extends readonly (infer T)[] ? T[] : never
  loading: boolean
  onUploadOnBehalf: (employeeId: string, docType: string) => void
}) {
  const [selectedEmployee, setSelectedEmployee] = useState(employees[0]?.id ?? '')
  const [requirements, setRequirements] = useState<DocumentRequirement[]>([])
  const [reqLoading, setReqLoading] = useState(false)
  const [reqError, setReqError] = useState<string | null>(null)
  const [waivedId, setWaivedId] = useState<string | null>(null)
  const [waiveReason, setWaiveReason] = useState('')

  const loadReqs = useCallback(async (empId: string) => {
    if (!empId) return
    setReqLoading(true)
    setReqError(null)
    const { data, error } = await supabase.rpc('get_document_requirements_for_employee', { p_employee_id: empId })
    setReqLoading(false)
    if (error) {
      setReqError(error.message)
      return
    }
    setRequirements((data ?? []) as DocumentRequirement[])
  }, [])

  useEffect(() => {
    if (selectedEmployee) loadReqs(selectedEmployee)
  }, [selectedEmployee, loadReqs])

  const statusColor: Record<DocumentRequirementStatus, string> = {
    missing: 'bg-brand-risk-soft text-brand-risk-text',
    pending_review: 'bg-brand-warning-soft text-brand-warning-solid',
    approved: 'bg-brand-action-soft text-brand-action-text',
    rejected: 'bg-brand-risk-soft text-brand-risk-text',
    expiring: 'bg-brand-warning-soft text-brand-warning-solid',
    archived: 'bg-surface-alt text-muted',
    waived: 'bg-surface-alt text-muted',
  }

  async function handleWaive(req: DocumentRequirement) {
    if (!waiveReason.trim()) return
    const { error } = await supabase.rpc('waive_document_requirement', {
      p_requirement_id: req.id,
      p_reason: waiveReason.trim(),
    })
    if (error) {
      setReqError(error.message)
      return
    }
    setWaivedId(null)
    setWaiveReason('')
    await loadReqs(selectedEmployee)
  }

  if (loading && employees.length === 0) {
    return (
      <div className="space-y-2">
        {[0, 1, 2].map((i) => (
          <div key={i} className="h-14 animate-pulse rounded-[14px] bg-surface" />
        ))}
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <label className="flex flex-col gap-1 text-xs font-medium text-muted">
        Employee
        <select
          value={selectedEmployee}
          onChange={(e) => setSelectedEmployee(e.target.value)}
          className="w-full max-w-xs rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          {employees.map((e) => (
            <option key={e.id} value={e.id}>
              {e.full_name}
            </option>
          ))}
        </select>
      </label>

      {reqError && (
        <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{reqError}</p>
      )}

      {reqLoading ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-14 animate-pulse rounded-[14px] bg-surface" />
          ))}
        </div>
      ) : requirements.length === 0 ? (
        <EmptyState
          title="No document requirements set up"
          description="Requirements are seeded for each employee on onboarding. None found for this employee."
        />
      ) : (
        <ul className="divide-y divide-border rounded-[14px] border border-border bg-surface shadow-card">
          {requirements.map((req) => (
            <li key={req.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
              <div className="min-w-0">
                <p className="text-sm font-medium text-ink">{docTypeLabel(req.doc_type)}</p>
                {req.waived_reason && (
                  <p className="text-xs text-muted">Waived: {req.waived_reason}</p>
                )}
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${statusColor[req.status]}`}>
                  {REQ_STATUS_LABEL[req.status]}
                </span>
                {(req.status === 'missing' || req.status === 'rejected') && (
                  <button
                    onClick={() => onUploadOnBehalf(selectedEmployee, req.doc_type)}
                    className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                  >
                    Upload on behalf
                  </button>
                )}
                {req.status !== 'waived' && req.status !== 'approved' && (
                  waivedId === req.id ? (
                    <div className="flex items-center gap-1">
                      <input
                        autoFocus
                        value={waiveReason}
                        onChange={(e) => setWaiveReason(e.target.value)}
                        placeholder="Reason"
                        className="rounded-lg border border-border px-2 py-1 text-xs text-ink focus:border-brand-blue focus:outline-none"
                      />
                      <button
                        onClick={() => handleWaive(req)}
                        disabled={!waiveReason.trim()}
                        className="rounded-lg bg-brand-blue px-2 py-1 text-xs font-medium text-white disabled:opacity-50"
                      >
                        Save
                      </button>
                      <button
                        onClick={() => { setWaivedId(null); setWaiveReason('') }}
                        className="rounded-lg border border-border px-2 py-1 text-xs text-muted hover:bg-surface-alt"
                      >
                        Cancel
                      </button>
                    </div>
                  ) : (
                    <button
                      onClick={() => setWaivedId(req.id)}
                      className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-muted hover:border-ink/20"
                    >
                      Waive
                    </button>
                  )
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Employee renewal upload
// ---------------------------------------------------------------------------

function RenewalModal({
  currentDoc,
  assisted,
  onClose,
  onSubmitted,
}: {
  currentDoc: EmployeeDocument
  assisted: boolean
  onClose: () => void
  onSubmitted: (message: string) => void
}) {
  const [expiryDate, setExpiryDate] = useState(currentDoc.expiry_date ?? '')
  const [notes, setNotes] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!file) {
      setError('Choose a file to upload.')
      return
    }
    const ext = file.name.split('.').pop()?.toLowerCase() ?? ''
    if (!['pdf', 'jpg', 'jpeg', 'png'].includes(ext)) {
      setError('Only PDF, JPG and PNG files are accepted.')
      return
    }
    setSubmitting(true)
    setError(null)

    // Same staged (pending row first, server-derived path, confirm-after-
    // upload) pattern as the manager upload flow — see stage_document_upload.
    const { data: stageData, error: stageError } = await supabase.rpc('stage_document_renewal', {
      p_current_document_id: currentDoc.id,
      p_file_extension: ext,
      p_expiry_date: expiryDate || null,
      p_notes: notes || null,
    })
    if (stageError) {
      setSubmitting(false)
      setError(stageError.message)
      return
    }
    const { id: documentId, storage_path: path } = stageData as { id: string; storage_path: string }

    const { error: uploadError } = await supabase.storage.from(BUCKET).upload(path, file, { upsert: false })
    if (uploadError) {
      setSubmitting(false)
      setError(`Upload failed: ${uploadError.message}. The staged record will be cleaned up automatically.`)
      return
    }

    const { data: confirmData, error: confirmError } = await supabase.rpc('confirm_document_upload', {
      p_document_id: documentId,
    })
    setSubmitting(false)
    if (confirmError) {
      setError(confirmError.message)
      return
    }
    const result = confirmData as { ok: boolean; code?: string; review_status?: string }
    if (!result.ok) {
      setError(result.code === 'UPLOAD_NOT_FOUND' ? 'The upload did not complete — please try again.' : 'Could not confirm the upload.')
      return
    }
    onSubmitted(
      result.review_status === 'approved'
        ? 'Renewal uploaded and approved — it is now the current version.'
        : assisted
          ? 'Renewal uploaded — someone else must review it. The current version stays active until then.'
          : 'Renewal uploaded — pending review.'
    )
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-1 text-base font-semibold text-ink">
          {assisted
            ? `Renew ${docTypeLabel(currentDoc.doc_type)} for ${currentDoc.employees?.full_name ?? 'this employee'}`
            : `Upload renewal — ${docTypeLabel(currentDoc.doc_type)}`}
        </h2>
        <p className="mb-4 text-xs text-muted">
          {assisted
            ? 'The current version stays active until someone else approves this renewal. It is recorded as uploaded on their behalf.'
            : 'Your current version stays active until an admin or manager approves this renewal.'}
        </p>
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label htmlFor="documents-new-expiry-date-optional-7" className="mb-1 block text-sm font-medium text-ink">New expiry date (optional)</label>
            <input id="documents-new-expiry-date-optional-7"
              type="date"
              value={expiryDate}
              onChange={(e) => setExpiryDate(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
            />
          </div>
          <div>
            <label htmlFor="documents-file-8" className="mb-1 block text-sm font-medium text-ink">File</label>
            <input id="documents-file-8"
              type="file"
              required
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink file:mr-3 file:rounded-md file:border-0 file:bg-brand-blue-soft file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-brand-blue-text"
            />
          </div>
          <div>
            <label htmlFor="documents-notes-optional-9" className="mb-1 block text-sm font-medium text-ink">Notes (optional)</label>
            <textarea id="documents-notes-optional-9"
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
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
              {submitting ? 'Uploading…' : 'Submit for review'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
