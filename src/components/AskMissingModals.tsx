import { useEffect, useMemo, useState } from 'react'
import { Alert, Modal } from './ui'
import { todayDubai } from '../lib/format'
import {
  BULK_MISSING_ITEMS,
  getMissingItems,
  requestSelectedMissing,
  requestSelectedMissingForMany,
  type MissingItem,
} from '../lib/api/employeeRequests'

// "Ask for missing details" — the admin ticks exactly which missing items to ask for.
// One employee: the list shows what that person is actually missing.
// Many: pick the items; each person is asked only for what they are missing.

const GROUPS = ['Documents', 'Bank details', 'Personal details'] as const

function NoteAndDate({ note, setNote, due, setDue }: { note: string; setNote: (v: string) => void; due: string; setDue: (v: string) => void }) {
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <label className="block sm:col-span-2">
        <span className="label">Note for them (optional)</span>
        <input className="input" value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Needed for your visa renewal" />
      </label>
      <label className="block">
        <span className="label">Due date (optional)</span>
        <input type="date" className="input" min={todayDubai()} value={due} onChange={(e) => setDue(e.target.value)} />
      </label>
    </div>
  )
}

function Row({
  label,
  checked,
  disabled,
  hint,
  onChange,
}: {
  label: string
  checked: boolean
  disabled?: boolean
  hint?: string
  onChange: () => void
}) {
  return (
    <label className={`flex min-h-11 items-center gap-3 rounded-lg border px-3 py-2 ${disabled ? 'border-border bg-surface-alt text-muted' : checked ? 'border-brand-blue bg-brand-blue-soft/40' : 'border-border'}`}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={onChange} />
      <span className="min-w-0 flex-1 text-sm font-medium text-ink">{label}</span>
      {hint && <span className="text-xs text-muted">{hint}</span>}
    </label>
  )
}

/** One employee: tick which of the things they're missing to ask for. */
export function AskMissingModal({
  employeeId,
  employeeName,
  onClose,
  onDone,
}: {
  employeeId: string
  employeeName: string
  onClose: () => void
  onDone: (message: string) => void
}) {
  const [items, setItems] = useState<MissingItem[] | null>(null)
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [note, setNote] = useState('')
  const [due, setDue] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    getMissingItems(employeeId).then((res) => {
      if (res.error || !res.data) return setError(res.error ?? 'Couldn’t load what’s missing.')
      setItems(res.data.items)
    })
  }, [employeeId])

  const askable = useMemo(() => (items ?? []).filter((i) => i.can_request && !i.already_asked), [items])
  const toggle = (k: string) =>
    setPicked((cur) => {
      const n = new Set(cur)
      if (n.has(k)) n.delete(k)
      else n.add(k)
      return n
    })

  async function send() {
    setBusy(true)
    setError(null)
    const res = await requestSelectedMissing(employeeId, [...picked], note, due)
    setBusy(false)
    if (res.error || !res.data) return setError(res.error ?? 'Couldn’t send the request.')
    const d = res.data
    const problems = d.skipped.map((x) => `${x.item} (${x.reason})`)
    if (!d.created.length) return setError(problems.length ? `Nothing was sent: ${problems.join('; ')}.` : 'Nothing new to send.')
    onDone(
      `Asked ${employeeName} for: ${d.created.join(', ')}. They’ll see it on their Home screen.` + (problems.length ? ` Not sent: ${problems.join('; ')}.` : '')
    )
  }

  return (
    <Modal
      open
      title={`Ask ${employeeName} for…`}
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn-secondary min-h-11" onClick={onClose}>
            Cancel
          </button>
          <button type="button" className="btn-primary min-h-11" disabled={busy || picked.size === 0} onClick={send}>
            {busy ? 'Sending…' : picked.size ? `Ask for ${picked.size} ${picked.size === 1 ? 'item' : 'items'}` : 'Ask'}
          </button>
        </>
      }
    >
      {error && <Alert tone="error">{error}</Alert>}
      {!items && !error && <div className="h-24 animate-pulse rounded-lg bg-surface-alt" />}
      {items && items.length === 0 && <p className="text-muted">{employeeName} isn’t missing anything — documents, bank details and personal details are all in.</p>}
      {items && items.length > 0 && (
        <>
          <div className="flex items-center justify-between">
            <p className="text-muted">Tick what to ask for. They’re asked only for the ticked items.</p>
            {askable.length > 1 && (
              <button
                type="button"
                className="min-h-11 text-sm font-medium text-brand-blue hover:underline"
                onClick={() => setPicked(picked.size === askable.length ? new Set() : new Set(askable.map((i) => i.key)))}
              >
                {picked.size === askable.length ? 'Clear' : 'Select all'}
              </button>
            )}
          </div>
          {GROUPS.map((g) => {
            const rows = items.filter((i) => i.group === g)
            if (!rows.length) return null
            return (
              <fieldset key={g} className="space-y-1.5">
                <legend className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">{g}</legend>
                {rows.map((i) => (
                  <Row
                    key={i.key}
                    label={i.label}
                    checked={picked.has(i.key)}
                    disabled={!i.can_request || i.already_asked}
                    hint={i.already_asked ? 'Already asked' : !i.can_request ? 'Owner or Company Admin only' : undefined}
                    onChange={() => toggle(i.key)}
                  />
                ))}
              </fieldset>
            )
          })}
          <NoteAndDate note={note} setNote={setNote} due={due} setDue={setDue} />
        </>
      )}
    </Modal>
  )
}

/** Everyone (or one branch): tick the items; each person is asked only for what they're missing. */
export function AskManyModal({
  entityId,
  locationId,
  scopeLabel,
  canAskRestricted,
  onClose,
  onDone,
}: {
  entityId: string
  locationId: string | null
  scopeLabel: string
  canAskRestricted: boolean
  onClose: () => void
  onDone: (message: string) => void
}) {
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [note, setNote] = useState('')
  const [due, setDue] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const toggle = (k: string) =>
    setPicked((cur) => {
      const n = new Set(cur)
      if (n.has(k)) n.delete(k)
      else n.add(k)
      return n
    })

  async function send() {
    setBusy(true)
    setError(null)
    const res = await requestSelectedMissingForMany(entityId, locationId, [...picked], note, due)
    setBusy(false)
    if (res.error || !res.data) return setError(res.error ?? 'Couldn’t send the requests.')
    const d = res.data
    onDone(
      d.requests
        ? `Sent ${d.requests} request${d.requests === 1 ? '' : 's'} to ${d.people} ${d.people === 1 ? 'person' : 'people'}: ${d.names.join(', ')}.` +
            (d.skipped ? ` ${d.skipped} couldn’t be sent (for example already asked).` : '')
        : 'Nothing new to send — nobody is missing the ticked items, or they’ve already been asked.'
    )
  }

  return (
    <Modal
      open
      title={`Ask ${scopeLabel} for…`}
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn-secondary min-h-11" onClick={onClose}>
            Cancel
          </button>
          <button type="button" className="btn-primary min-h-11" disabled={busy || picked.size === 0} onClick={send}>
            {busy ? 'Sending…' : picked.size ? `Ask for ${picked.size} ${picked.size === 1 ? 'item' : 'items'}` : 'Ask'}
          </button>
        </>
      }
    >
      {error && <Alert tone="error">{error}</Alert>}
      <p className="text-muted">Tick what to ask for. Each person is asked only for the ticked items they’re actually missing.</p>
      {GROUPS.map((g) => (
        <fieldset key={g} className="space-y-1.5">
          <legend className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">{g}</legend>
          {BULK_MISSING_ITEMS.filter((i) => i.group === g).map((i) => (
            <Row
              key={i.key}
              label={i.label}
              checked={picked.has(i.key)}
              disabled={!!i.restricted && !canAskRestricted}
              hint={i.restricted && !canAskRestricted ? 'Owner or Company Admin only' : undefined}
              onChange={() => toggle(i.key)}
            />
          ))}
        </fieldset>
      ))}
      <NoteAndDate note={note} setNote={setNote} due={due} setDue={setDue} />
    </Modal>
  )
}
