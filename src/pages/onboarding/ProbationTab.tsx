import { useCallback, useEffect, useState } from 'react'
import { Alert, Modal, ResponsiveTable, Skeleton } from '../../components/ui'
import { EmptyState } from '../../components/EmptyState'
import { StatusBadge } from '../../components/StatusBadge'
import { supabase } from '../../lib/supabase'
import { decideProbation, listProbationDue, recordProbationReview, type ProbationDueRow } from '../../lib/api/onboarding'
import { maxProbationEnd } from '../../lib/onboarding'
import { fmtDate, todayDubai } from '../../lib/format'

/**
 * Probation reviews and decisions. Branch managers record reviews; the
 * owner / entity admin decides (confirm, extend within six months in total,
 * or not confirm — which hands over to HR, never ends employment by itself).
 */
export default function ProbationTab({ entityId, canDecide }: { entityId: string; canDecide: boolean }) {
  const [rows, setRows] = useState<ProbationDueRow[] | null>(null)
  const [within, setWithin] = useState(30)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [review, setReview] = useState<ProbationDueRow | null>(null)
  const [decide, setDecide] = useState<ProbationDueRow | null>(null)

  const load = useCallback(async () => {
    const r = await listProbationDue(entityId, within)
    if (r.error) setError(r.error)
    setRows(r.data ?? [])
  }, [entityId, within])
  useEffect(() => {
    setRows(null)
    load()
  }, [load])

  return (
    <div className="space-y-3 pt-2">
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
      <label className="block max-w-xs">
        <span className="label">Review due within</span>
        <select className="input" value={within} onChange={(e) => setWithin(Number(e.target.value))}>
          <option value={14}>14 days</option>
          <option value={30}>30 days</option>
          <option value={90}>90 days</option>
          <option value={200}>All active</option>
        </select>
      </label>
      {rows === null ? (
        <Skeleton rows={3} />
      ) : rows.length === 0 ? (
        <EmptyState title="No probation reviews due" description="Probation starts automatically when a new starter is activated." />
      ) : (
        <ResponsiveTable
          caption="Probation reviews"
          rows={rows}
          rowKey={(r) => r.period_id}
          columns={[
            { key: 'n', header: 'Employee', render: (r) => <span className="font-medium">{r.full_name}<span className="block text-xs text-muted">{r.location ?? ''}</span></span> },
            { key: 'p', header: 'Probation', render: (r) => `${fmtDate(r.start_date)} – ${fmtDate(r.end_date)}${r.is_extension ? ' (extended)' : ''}` },
            {
              key: 'd',
              header: 'Review by',
              render: (r) => (
                <span className="flex items-center gap-2">
                  {fmtDate(r.review_due_date)}
                  {r.overdue && <StatusBadge status="Overdue" tone="risk" />}
                </span>
              ),
            },
            { key: 'r', header: 'Reviews', render: (r) => r.reviews },
          ]}
          actions={(r) => (
            <span className="flex flex-wrap justify-end gap-2">
              <button className="btn-secondary min-h-9" onClick={() => setReview(r)}>
                Add review
              </button>
              {canDecide && (
                <button className="btn-primary min-h-9" onClick={() => setDecide(r)} disabled={r.reviews === 0} title={r.reviews === 0 ? 'Add a review first' : undefined}>
                  Decide
                </button>
              )}
            </span>
          )}
        />
      )}
      {review && (
        <ReviewDialog
          row={review}
          onClose={() => setReview(null)}
          onDone={() => {
            setReview(null)
            setNotice('Review recorded.')
            load()
          }}
        />
      )}
      {decide && (
        <DecideDialog
          row={decide}
          onClose={() => setDecide(null)}
          onDone={(m) => {
            setDecide(null)
            setNotice(m)
            load()
          }}
        />
      )}
    </div>
  )
}

function ReviewDialog({ row, onClose, onDone }: { row: ProbationDueRow; onClose: () => void; onDone: () => void }) {
  const [rec, setRec] = useState<'confirm' | 'extend' | 'not_confirm'>('confirm')
  const [comments, setComments] = useState('')
  const [err, setErr] = useState<string | null>(null)
  async function save() {
    if (!comments.trim()) return setErr('Add your comments.')
    const r = await recordProbationReview(row.period_id, rec, comments.trim())
    if (r.error) setErr(r.error)
    else onDone()
  }
  return (
    <Modal
      open
      title={`Probation review — ${row.full_name}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save}>
            Save review
          </button>
        </>
      }
    >
      <label className="block">
        <span className="label">Recommendation</span>
        <select className="input" value={rec} onChange={(e) => setRec(e.target.value as typeof rec)}>
          <option value="confirm">Confirm in the role</option>
          <option value="extend">Extend probation</option>
          <option value="not_confirm">Do not confirm</option>
        </select>
      </label>
      <label className="block">
        <span className="label">Comments *</span>
        <textarea className="input min-h-24" value={comments} onChange={(e) => setComments(e.target.value)} placeholder="Reliability, skills, attitude, examples." />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}

function DecideDialog({ row, onClose, onDone }: { row: ProbationDueRow; onClose: () => void; onDone: (m: string) => void }) {
  const [outcome, setOutcome] = useState<'confirmed' | 'extended' | 'not_confirmed'>('confirmed')
  const [effective, setEffective] = useState(todayDubai())
  const [newEnd, setNewEnd] = useState('')
  const [reason, setReason] = useState('')
  const [firstStart, setFirstStart] = useState(row.start_date)
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => {
    // The six-month cap counts from the first probation start.
    supabase
      .from('employee_probation_periods')
      .select('start_date')
      .eq('employee_id', row.employee_id)
      .order('start_date')
      .limit(1)
      .then(({ data }) => data?.[0] && setFirstStart(data[0].start_date as string))
  }, [row.employee_id])
  const cap = maxProbationEnd(firstStart)
  async function save() {
    if (outcome !== 'confirmed' && !reason.trim()) return setErr('A reason is required.')
    if (outcome === 'extended' && (!newEnd || newEnd > cap)) return setErr(`Choose a new end date on or before ${fmtDate(cap)}.`)
    const r = await decideProbation(row.period_id, outcome, effective || null, outcome === 'extended' ? newEnd : null, reason.trim() || null)
    if (r.error) return setErr(r.error)
    onDone(
      outcome === 'confirmed'
        ? `${row.full_name} is confirmed.`
        : outcome === 'extended'
          ? `Probation extended to ${fmtDate(newEnd)}.`
          : 'Recorded. HR has a follow-up to start offboarding with the required notice.'
    )
  }
  return (
    <Modal
      open
      title={`Probation decision — ${row.full_name}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className={outcome === 'not_confirmed' ? 'btn-danger' : 'btn-primary'} onClick={save}>
            Save decision
          </button>
        </>
      }
    >
      <fieldset className="space-y-2">
        {(
          [
            ['confirmed', 'Confirm in the role'],
            ['extended', 'Extend probation'],
            ['not_confirmed', 'Do not confirm'],
          ] as const
        ).map(([k, l]) => (
          <label key={k} className="flex items-center gap-2 text-sm">
            <input type="radio" name="prob" checked={outcome === k} onChange={() => setOutcome(k)} /> {l}
          </label>
        ))}
      </fieldset>
      <label className="block">
        <span className="label">Effective date</span>
        <input type="date" className="input" value={effective} onChange={(e) => setEffective(e.target.value)} />
      </label>
      {outcome === 'extended' && (
        <label className="block">
          <span className="label">New end date *</span>
          <input type="date" className="input" value={newEnd} min={row.end_date} max={cap} onChange={(e) => setNewEnd(e.target.value)} />
          <span className="mt-1 block text-xs text-muted">UAE law allows at most six months of probation in total — latest {fmtDate(cap)}.</span>
        </label>
      )}
      <label className="block">
        <span className="label">Reason{outcome !== 'confirmed' ? ' *' : ''}</span>
        <textarea className="input min-h-16" value={reason} onChange={(e) => setReason(e.target.value)} />
      </label>
      {err && <p className="text-xs font-medium text-brand-risk-text">{err}</p>}
    </Modal>
  )
}
