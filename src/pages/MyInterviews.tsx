import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import type { CandidateFileRef, InterviewRecommendation, MyInterviewDetail, MyInterviewRow } from '../types/db'
import { EntityEyebrow } from '../components/EntityEyebrow'
import { fmtDateTime } from '../lib/format'

const COMPETENCIES: { key: string; label: string }[] = [
  { key: 'communication', label: 'Communication' },
  { key: 'technical_skill', label: 'Technical skill' },
  { key: 'culture_fit', label: 'Culture fit' },
  { key: 'reliability', label: 'Reliability' },
]

const RECOMMENDATIONS: { value: InterviewRecommendation; label: string }[] = [
  { value: 'strong_yes', label: 'Strong yes' },
  { value: 'yes', label: 'Yes' },
  { value: 'neutral', label: 'Neutral' },
  { value: 'no', label: 'No' },
  { value: 'strong_no', label: 'Strong no' },
]

const STATE_TONE: Record<string, 'neutral' | 'info' | 'warning' | 'risk' | 'success'> = {
  upcoming: 'info',
  completed: 'warning',
  feedback_submitted: 'success',
  cancelled: 'neutral',
  reopened: 'warning',
}

// Employee-facing "My Interviews" — deliberately not the Recruiting module.
// Every row and every field here comes from get_my_interviews() /
// get_interview_detail(), curated RPCs that resolve identity from
// auth.uid() and never accept a client-supplied employee_id. This page has
// no way to reach the candidate register, requisition pipeline, or
// compensation/offer data even if someone tries to guess a URL — those
// tables simply have no RLS policy granting this role any access at all.
export default function MyInterviews() {
  const [rows, setRows] = useState<MyInterviewRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  async function load() {
    setLoading(true)
    setError(null)
    const { data, error: rpcError } = await supabase.rpc('get_my_interviews')
    if (rpcError) setError(rpcError.message)
    else setRows((data ?? []) as MyInterviewRow[])
    setLoading(false)
  }

  useEffect(() => {
    load()
  }, [])

  return (
    <div className="space-y-5">
      <div>
        <EntityEyebrow />
        <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">My interviews</h1>
        <p className="text-xs text-muted">Interviews you've been assigned to conduct.</p>
      </div>

      {error && <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

      {loading ? (
        <div className="space-y-2">
          {[0, 1].map((i) => (
            <div key={i} className="h-20 animate-pulse rounded-[14px] bg-surface" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <EmptyState title="No interviews assigned" description="Interviews you're asked to conduct will show up here." />
      ) : (
        <ul className="space-y-3">
          {rows.map((row) => (
            <li key={row.interview_id} className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <p className="font-medium text-ink">{row.candidate_name}</p>
                  <p className="text-xs text-muted">
                    {row.position_title} · {row.stage_name}
                  </p>
                </div>
                <StatusBadge status={row.state} tone={STATE_TONE[row.state]} />
              </div>
              <p className="mt-2 text-xs text-muted">
                {fmtDateTime(row.scheduled_at)} · {row.format.replace('_', ' ')}
                {row.meeting_location ? ` · ${row.meeting_location}` : ''}
              </p>
              <button
                onClick={() => setSelectedId(row.interview_id)}
                className="mt-3 rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
              >
                Open
              </button>
            </li>
          ))}
        </ul>
      )}

      {selectedId && (
        <InterviewDetailDrawer
          interviewId={selectedId}
          onClose={() => setSelectedId(null)}
          onChange={load}
        />
      )}
    </div>
  )
}

function InterviewDetailDrawer({
  interviewId,
  onClose,
  onChange,
}: {
  interviewId: string
  onClose: () => void
  onChange: () => void
}) {
  const [detail, setDetail] = useState<MyInterviewDetail | null>(null)
  const [files, setFiles] = useState<CandidateFileRef[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [recommendation, setRecommendation] = useState<InterviewRecommendation | ''>('')
  const [ratings, setRatings] = useState<Record<string, number>>({})
  const [strengths, setStrengths] = useState('')
  const [concerns, setConcerns] = useState('')
  const [notes, setNotes] = useState('')
  const [saving, setSaving] = useState(false)
  const [confirmingSubmit, setConfirmingSubmit] = useState(false)

  async function load() {
    setLoading(true)
    setError(null)
    // get_interview_detail() re-validates assignment/entity/window/active
    // employee itself and logs an 'interview_viewed' audit event on every
    // call — this component never assumes access just because it has an id.
    const [detailRes, filesRes] = await Promise.all([
      supabase.rpc('get_interview_detail', { p_interview_id: interviewId }),
      supabase.rpc('list_candidate_files_for_interview', { p_interview_id: interviewId }),
    ])
    if (detailRes.error) {
      setError(detailRes.error.message)
      setLoading(false)
      return
    }
    const d = detailRes.data as MyInterviewDetail
    setDetail(d)
    setFiles((filesRes.data ?? []) as CandidateFileRef[])
    if (d.feedback) {
      setRecommendation(d.feedback.recommendation ?? '')
      setRatings(d.feedback.competency_ratings ?? {})
      setStrengths(d.feedback.strengths ?? '')
      setConcerns(d.feedback.concerns ?? '')
      setNotes(d.feedback.notes ?? '')
    }
    setLoading(false)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [interviewId])

  async function handleViewFile(file: CandidateFileRef) {
    // Logged before the signed URL is minted, and the signed URL itself is
    // short-lived and scoped by storage RLS to this exact object — there is
    // no folder-level access, only this specific approved file.
    const { error: logError } = await supabase.rpc('log_candidate_file_access', {
      p_interview_id: interviewId,
      p_file_id: file.id,
    })
    if (logError) {
      setError(logError.message)
      return
    }
    const { data, error: signError } = await supabase.storage.from('candidate-files').createSignedUrl(file.storage_path, 60)
    if (signError || !data) {
      setError(signError?.message ?? "Couldn't open that file.")
      return
    }
    window.open(data.signedUrl, '_blank', 'noopener,noreferrer')
  }

  async function handleSaveDraft() {
    setSaving(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('save_interview_feedback_draft', {
      p_interview_id: interviewId,
      p_recommendation: recommendation || null,
      p_competency_ratings: Object.keys(ratings).length ? ratings : null,
      p_strengths: strengths || null,
      p_concerns: concerns || null,
      p_notes: notes || null,
    })
    setSaving(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }
    load()
  }

  async function handleSubmit() {
    if (!recommendation) {
      setError('Choose a recommendation before submitting.')
      return
    }
    setSaving(true)
    setError(null)
    // Save whatever's currently in the form first so submission reflects
    // the latest edits, then lock it.
    const { error: saveError } = await supabase.rpc('save_interview_feedback_draft', {
      p_interview_id: interviewId,
      p_recommendation: recommendation,
      p_competency_ratings: Object.keys(ratings).length ? ratings : null,
      p_strengths: strengths || null,
      p_concerns: concerns || null,
      p_notes: notes || null,
    })
    if (saveError) {
      setSaving(false)
      setError(saveError.message)
      return
    }
    const { error: submitError } = await supabase.rpc('submit_interview_feedback', { p_interview_id: interviewId })
    setSaving(false)
    setConfirmingSubmit(false)
    if (submitError) {
      setError(submitError.message)
      return
    }
    onChange()
    load()
  }

  const readOnly = detail?.feedback?.status === 'submitted'
  const cancelled = Boolean(detail?.cancelled_at)

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-ink/40 px-4" onClick={onClose}>
      <div
        className="max-h-[85vh] w-full max-w-xl overflow-y-auto rounded-[14px] border border-border bg-surface p-6 shadow-card"
        onClick={(e) => e.stopPropagation()}
      >
        {loading || !detail ? (
          <div className="h-40 animate-pulse rounded-lg bg-surface-alt" />
        ) : (
          <>
            <div className="mb-1 flex items-start justify-between">
              <h2 className="text-base font-semibold text-ink">{detail.candidate_name}</h2>
              <StatusBadge status={detail.state} tone={STATE_TONE[detail.state]} />
            </div>
            <p className="mb-4 text-xs text-muted">
              {detail.position_title} · {detail.stage_name}
            </p>

            {error && <p className="mb-3 rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>}

            {cancelled ? (
              <div className="rounded-lg bg-surface-alt px-3 py-3 text-sm text-muted">
                <p className="font-medium text-ink">This interview was cancelled.</p>
                {detail.cancellation_reason && <p className="mt-1 text-xs">{detail.cancellation_reason}</p>}
              </div>
            ) : (
              <>
                <div className="mb-4 grid grid-cols-2 gap-3 text-sm">
                  <div>
                    <p className="text-xs text-muted">When</p>
                    <p className="text-ink">{fmtDateTime(detail.scheduled_at)}</p>
                  </div>
                  <div>
                    <p className="text-xs text-muted">Format</p>
                    <p className="capitalize text-ink">{detail.format.replace('_', ' ')}</p>
                  </div>
                  {detail.meeting_location && (
                    <div className="col-span-2">
                      <p className="text-xs text-muted">Location / link</p>
                      <p className="text-ink">{detail.meeting_location}</p>
                    </div>
                  )}
                </div>

                {detail.interview_guide && (
                  <div className="mb-4 rounded-lg bg-surface-alt p-3">
                    <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Interview guide</p>
                    <p className="whitespace-pre-wrap text-sm text-ink">{detail.interview_guide}</p>
                  </div>
                )}

                {files.length > 0 && (
                  <div className="mb-4">
                    <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Approved files</p>
                    <div className="flex flex-wrap gap-2">
                      {files.map((f) => (
                        <button
                          key={f.id}
                          onClick={() => handleViewFile(f)}
                          className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-brand-blue hover:border-brand-blue/30"
                        >
                          {f.file_type === 'resume' ? 'Résumé' : f.file_type === 'interview_pack' ? 'Interview pack' : 'File'}
                        </button>
                      ))}
                    </div>
                  </div>
                )}

                <div className="border-t border-border pt-4">
                  <p className="mb-3 text-xs font-semibold uppercase tracking-wide text-muted">
                    {readOnly ? 'Your feedback (submitted)' : 'Your feedback'}
                  </p>

                  {detail.feedback?.reopen_reason && (
                    <p className="mb-3 rounded-lg bg-brand-warning-soft px-3 py-2 text-xs text-brand-warning-solid">
                      Reopened by a recruiting admin: {detail.feedback.reopen_reason}
                    </p>
                  )}

                  <div className="space-y-3">
                    <div>
                      <label htmlFor="myinterviews-recommendation-1" className="mb-1 block text-sm font-medium text-ink">Recommendation</label>
                      <select id="myinterviews-recommendation-1"
                        value={recommendation}
                        disabled={readOnly}
                        onChange={(e) => setRecommendation(e.target.value as InterviewRecommendation)}
                        className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20 disabled:bg-surface-alt disabled:text-muted"
                      >
                        <option value="">Select…</option>
                        {RECOMMENDATIONS.map((r) => (
                          <option key={r.value} value={r.value}>
                            {r.label}
                          </option>
                        ))}
                      </select>
                    </div>

                    <div className="grid grid-cols-2 gap-3">
                      {COMPETENCIES.map((c) => (
                        <div key={c.key}>
                          <label className="mb-1 block text-xs font-medium text-ink">{c.label}</label>
                          <select
                            aria-label={c.label}
                            value={ratings[c.key] ?? ''}
                            disabled={readOnly}
                            onChange={(e) => setRatings((r) => ({ ...r, [c.key]: Number(e.target.value) }))}
                            className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20 disabled:bg-surface-alt disabled:text-muted"
                          >
                            <option value="">—</option>
                            {[1, 2, 3, 4, 5].map((n) => (
                              <option key={n} value={n}>
                                {n}
                              </option>
                            ))}
                          </select>
                        </div>
                      ))}
                    </div>

                    <div>
                      <label htmlFor="myinterviews-strengths-2" className="mb-1 block text-sm font-medium text-ink">Strengths</label>
                      <textarea id="myinterviews-strengths-2"
                        value={strengths}
                        disabled={readOnly}
                        onChange={(e) => setStrengths(e.target.value)}
                        rows={2}
                        className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20 disabled:bg-surface-alt disabled:text-muted"
                      />
                    </div>
                    <div>
                      <label htmlFor="myinterviews-concerns-3" className="mb-1 block text-sm font-medium text-ink">Concerns</label>
                      <textarea id="myinterviews-concerns-3"
                        value={concerns}
                        disabled={readOnly}
                        onChange={(e) => setConcerns(e.target.value)}
                        rows={2}
                        className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20 disabled:bg-surface-alt disabled:text-muted"
                      />
                    </div>
                    <div>
                      <label htmlFor="myinterviews-notes-4" className="mb-1 block text-sm font-medium text-ink">Notes</label>
                      <textarea id="myinterviews-notes-4"
                        value={notes}
                        disabled={readOnly}
                        onChange={(e) => setNotes(e.target.value)}
                        rows={2}
                        className="w-full rounded-lg border border-border px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20 disabled:bg-surface-alt disabled:text-muted"
                      />
                    </div>

                    {!readOnly && (
                      <>
                        {!confirmingSubmit ? (
                          <div className="flex flex-wrap justify-end gap-2 pt-1">
                            <button
                              onClick={handleSaveDraft}
                              disabled={saving}
                              className="rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt disabled:opacity-60"
                            >
                              {saving ? 'Saving…' : 'Save draft'}
                            </button>
                            <button
                              onClick={() => setConfirmingSubmit(true)}
                              disabled={saving}
                              className="rounded-lg bg-brand-blue px-4 py-2 text-sm font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
                            >
                              Submit feedback
                            </button>
                          </div>
                        ) : (
                          <div className="rounded-lg bg-brand-warning-soft px-3 py-3 text-sm text-brand-warning-solid">
                            <p className="mb-2">Submitting locks this feedback — you won't be able to edit it afterward.</p>
                            <div className="flex justify-end gap-2">
                              <button
                                onClick={() => setConfirmingSubmit(false)}
                                className="rounded-lg border border-border px-3 py-1.5 text-xs text-ink hover:bg-surface"
                              >
                                Cancel
                              </button>
                              <button
                                onClick={handleSubmit}
                                disabled={saving}
                                className="rounded-lg bg-brand-blue px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-blue-dark disabled:opacity-60"
                              >
                                {saving ? 'Submitting…' : 'Confirm submit'}
                              </button>
                            </div>
                          </div>
                        )}
                      </>
                    )}

                    {readOnly && detail.feedback?.submitted_at && (
                      <p className="text-xs text-muted">Submitted {fmtDateTime(detail.feedback.submitted_at)}</p>
                    )}
                  </div>
                </div>
              </>
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
