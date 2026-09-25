import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, Field, Modal } from '../../components/ui'
import { bulkImportEmployees, listLocations, listPositions, type BulkImportResultRow } from '../../lib/api/admin'
import { CSV_TEMPLATE, buildImportPreview, canCommitPreview, type LookupItem } from '../../lib/csvImport'

export function ImportTab({ activeEntityId, entityName }: { activeEntityId: string | null; entityName: string }) {
  const [text, setText] = useState('')
  const [branches, setBranches] = useState<LookupItem[]>([])
  const [positions, setPositions] = useState<LookupItem[]>([])
  const [confirming, setConfirming] = useState(false)
  const [committing, setCommitting] = useState(false)
  const [serverRows, setServerRows] = useState<BulkImportResultRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<number | null>(null)

  useEffect(() => {
    if (!activeEntityId) return
    listLocations(activeEntityId).then((r) => setBranches((r.data ?? []).map((l) => ({ id: l.id, name: l.name, code: l.code }))))
    listPositions(activeEntityId).then((r) => setPositions((r.data ?? []).map((p) => ({ id: p.id, name: p.title }))))
  }, [activeEntityId])

  const preview = useMemo(() => (text.trim() ? buildImportPreview(text, branches, positions) : null), [text, branches, positions])
  const serverErrors = useMemo(() => {
    const m = new Map<number, string[]>()
    for (const r of serverRows ?? []) if (r.errors?.length) m.set(r.row_index, r.errors)
    return m
  }, [serverRows])

  async function onFile(file: File | undefined) {
    if (!file) return
    if (file.size > 2 * 1024 * 1024) return setError('File is larger than 2 MB. Split it into smaller files.')
    setText(await file.text())
    setServerRows(null)
    setDone(null)
  }

  function downloadTemplate() {
    const blob = new Blob([CSV_TEMPLATE], { type: 'text/csv' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = 'employee-import-template.csv'
    a.click()
    URL.revokeObjectURL(url)
  }

  async function commit() {
    if (!preview || !activeEntityId) return
    setCommitting(true)
    setError(null)
    const res = await bulkImportEmployees(
      activeEntityId,
      preview.rows.map((r) => r.payload)
    )
    setCommitting(false)
    setConfirming(false)
    if (res.error) return setError(res.error)
    const rows = res.data ?? []
    setServerRows(rows)
    const failed = rows.filter((r) => !r.success)
    if (failed.length) {
      setError(`Nothing was imported — the server found problems in ${failed.length} row(s). Fix them and try again.`)
    } else {
      setDone(rows.length)
      setText('')
    }
  }

  if (!activeEntityId) return <Alert tone="info">Choose an entity first.</Alert>

  return (
    <div className="space-y-4">
      <div className="card space-y-3">
        <p className="text-sm text-muted">
          Import new employees into <strong className="text-ink">{entityName}</strong>. They're created as <strong>Pre-boarding</strong>. The import is
          all-or-nothing: if any row has a problem, nothing is saved.
        </p>
        <div className="flex flex-wrap gap-2">
          <button className="btn-secondary" onClick={downloadTemplate}>
            Download template
          </button>
          <label className="btn-secondary cursor-pointer">
            Upload CSV
            <input type="file" accept=".csv,text/csv" className="sr-only" onChange={(e) => onFile(e.target.files?.[0])} />
          </label>
        </div>
        <Field label="Or paste CSV" hint="Columns: full_name (required), email, gender, employment_type, join_date, branch, position.">
          {(p) => (
            <textarea
              {...p}
              rows={6}
              className="input font-mono text-xs"
              value={text}
              onChange={(e) => {
                setText(e.target.value)
                setServerRows(null)
                setDone(null)
              }}
            />
          )}
        </Field>
      </div>

      {error && (
        <Alert tone="error" onDismiss={() => setError(null)}>
          {error}
        </Alert>
      )}
      {done !== null && (
        <Alert tone="success">
          {done} employee(s) imported as Pre-boarding. <Link to="/employees" className="font-semibold underline">Open People</Link>
        </Alert>
      )}

      {preview && (
        <section aria-labelledby="preview-h" className="space-y-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 id="preview-h" className="text-base font-semibold text-ink">
              Preview — {preview.rows.length} row(s): {preview.validCount} ready, {preview.invalidCount} with errors
            </h3>
            <button className="btn-primary" disabled={!canCommitPreview(preview) || committing} onClick={() => setConfirming(true)}>
              Import {preview.rows.length} employee(s)
            </button>
          </div>
          {preview.headerErrors.map((e) => (
            <Alert key={e} tone={e.startsWith('Ignored') ? 'warning' : 'error'}>
              {e}
            </Alert>
          ))}
          <ul className="space-y-2">
            {preview.rows.map((r) => {
              const errs = [...r.errors, ...(serverErrors.get(r.rowNumber) ?? [])]
              return (
                <li key={r.rowNumber} className={`card py-3 ${errs.length ? 'border-brand-risk/40' : ''}`}>
                  <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
                    <span className="font-medium text-ink">
                      Row {r.rowNumber}: {r.values.full_name || <em className="text-muted">no name</em>}
                    </span>
                    <span className="text-muted">
                      {[r.values.email, r.values.employment_type, r.values.join_date, r.values.branch, r.values.position].filter(Boolean).join(' · ')}
                    </span>
                  </div>
                  {errs.length > 0 ? (
                    <ul className="mt-1 list-disc pl-5 text-sm text-brand-risk-text">
                      {errs.map((e) => (
                        <li key={e}>{e}</li>
                      ))}
                    </ul>
                  ) : (
                    <p className="mt-1 text-xs text-brand-action-text">Ready</p>
                  )}
                </li>
              )
            })}
          </ul>
        </section>
      )}

      <Modal
        open={confirming}
        title="Import employees?"
        onClose={() => setConfirming(false)}
        footer={
          <>
            <button className="btn-secondary" onClick={() => setConfirming(false)}>
              Cancel
            </button>
            <button className="btn-primary" onClick={commit} disabled={committing}>
              {committing ? 'Importing…' : 'Import'}
            </button>
          </>
        }
      >
        <p>
          {preview?.rows.length} new employee record(s) will be created in {entityName} as Pre-boarding. This is recorded in the audit log.
        </p>
      </Modal>
    </div>
  )
}
