import { useEffect, useId, useRef, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from 'react'

// Shared, accessible building blocks for the newer screens (WCAG 2.2 AA):
// dialogs trap focus, close on Escape and return focus to the opener;
// fields keep persistent labels with inline errors wired via aria-describedby;
// tables collapse into labelled cards below 768px.

const FOCUSABLE =
  'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'

// Stack of open dialogs so only the top-most one reacts to Escape/Tab when a
// confirmation modal is opened on top of a drawer.
const dialogStack: symbol[] = []

function useDialogFocus(open: boolean, onClose: () => void) {
  const panelRef = useRef<HTMLDivElement>(null)
  const onCloseRef = useRef(onClose)
  useEffect(() => {
    onCloseRef.current = onClose
  }, [onClose])

  useEffect(() => {
    if (!open) return
    const token = Symbol('dialog')
    dialogStack.push(token)
    const opener = document.activeElement as HTMLElement | null
    const panel = panelRef.current
    const first = panel?.querySelector<HTMLElement>('[data-autofocus]') ?? panel?.querySelector<HTMLElement>(FOCUSABLE)
    ;(first ?? panel)?.focus()
    const prevOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    function onKey(e: KeyboardEvent) {
      if (dialogStack[dialogStack.length - 1] !== token) return
      if (e.key === 'Escape') {
        e.stopPropagation()
        onCloseRef.current()
        return
      }
      if (e.key !== 'Tab' || !panelRef.current) return
      const nodes = Array.from(panelRef.current.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (n) => n.offsetParent !== null || n === document.activeElement
      )
      if (nodes.length === 0) return
      const firstNode = nodes[0]
      const lastNode = nodes[nodes.length - 1]
      if (e.shiftKey && document.activeElement === firstNode) {
        e.preventDefault()
        lastNode.focus()
      } else if (!e.shiftKey && document.activeElement === lastNode) {
        e.preventDefault()
        firstNode.focus()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      const idx = dialogStack.indexOf(token)
      if (idx >= 0) dialogStack.splice(idx, 1)
      document.body.style.overflow = prevOverflow
      opener?.focus?.()
    }
  }, [open])

  return panelRef
}

export function CloseIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden="true">
      <path d="M6 6l12 12M18 6 6 18" strokeLinecap="round" />
    </svg>
  )
}

/** Right-hand drawer on desktop, bottom sheet on mobile. */
export function Drawer({
  open,
  title,
  description,
  onClose,
  children,
  footer,
  wide,
}: {
  open: boolean
  title: string
  description?: string
  onClose: () => void
  children: ReactNode
  footer?: ReactNode
  wide?: boolean
}) {
  const panelRef = useDialogFocus(open, onClose)
  const titleId = useId()
  const descId = useId()
  if (!open) return null
  return (
    <div className="fixed inset-0 z-40 flex items-end justify-end bg-ink/40 md:items-stretch" onMouseDown={onClose}>
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={description ? descId : undefined}
        tabIndex={-1}
        onMouseDown={(e) => e.stopPropagation()}
        className={`flex max-h-[92vh] w-full flex-col rounded-t-2xl bg-surface shadow-card focus:outline-none md:max-h-none md:rounded-none ${
          wide ? 'md:max-w-2xl' : 'md:max-w-md'
        }`}
      >
        <div className="flex items-start justify-between gap-3 border-b border-border px-5 py-4">
          <div>
            <h2 id={titleId} className="text-base font-semibold text-ink">
              {title}
            </h2>
            {description && (
              <p id={descId} className="mt-0.5 text-sm text-muted">
                {description}
              </p>
            )}
          </div>
          <button type="button" onClick={onClose} aria-label="Close" className="-m-2 flex h-11 w-11 items-center justify-center rounded-lg text-muted hover:bg-surface-alt">
            <CloseIcon />
          </button>
        </div>
        <div className="flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <div className="flex flex-wrap justify-end gap-2 border-t border-border px-5 py-3">{footer}</div>}
      </div>
    </div>
  )
}

/** Centered modal, used for confirmations. */
export function Modal({
  open,
  title,
  onClose,
  children,
  footer,
}: {
  open: boolean
  title: string
  onClose: () => void
  children: ReactNode
  footer?: ReactNode
}) {
  const panelRef = useDialogFocus(open, onClose)
  const titleId = useId()
  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink/40 px-4" onMouseDown={onClose}>
      <div
        ref={panelRef}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        onMouseDown={(e) => e.stopPropagation()}
        className="w-full max-w-md rounded-[14px] border border-border bg-surface p-5 shadow-card focus:outline-none"
      >
        <h2 id={titleId} className="mb-3 text-base font-semibold text-ink">
          {title}
        </h2>
        <div className="space-y-3 text-sm text-ink">{children}</div>
        {footer && <div className="mt-5 flex flex-wrap justify-end gap-2">{footer}</div>}
      </div>
    </div>
  )
}

/** Labelled form control wrapper with inline error + hint. */
export function Field({
  label,
  error,
  hint,
  required,
  children,
}: {
  label: string
  error?: string | null
  hint?: string
  required?: boolean
  children: (props: { id: string; 'aria-invalid': boolean; 'aria-describedby': string | undefined }) => ReactNode
}) {
  const id = useId()
  const hintId = `${id}-hint`
  const errId = `${id}-err`
  const describedBy = [hint ? hintId : null, error ? errId : null].filter(Boolean).join(' ') || undefined
  return (
    <div>
      <label htmlFor={id} className="label">
        {label}
        {required && (
          <span className="text-brand-risk" aria-hidden="true">
            {' '}
            *
          </span>
        )}
      </label>
      {children({ id, 'aria-invalid': Boolean(error), 'aria-describedby': describedBy })}
      {hint && !error && (
        <p id={hintId} className="mt-1 text-xs text-muted">
          {hint}
        </p>
      )}
      {error && (
        <p id={errId} className="mt-1 text-xs font-medium text-brand-risk-text">
          {error}
        </p>
      )}
    </div>
  )
}

export function Alert({
  tone,
  children,
  onDismiss,
}: {
  tone: 'error' | 'success' | 'info' | 'warning'
  children: ReactNode
  onDismiss?: () => void
}) {
  const cls = {
    error: 'bg-brand-risk-soft text-brand-risk-text',
    success: 'bg-brand-action-soft text-brand-action-text',
    info: 'bg-brand-info-soft text-brand-info-text',
    warning: 'bg-brand-warning-soft text-brand-warning-solid',
  }[tone]
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} className={`flex items-start justify-between gap-3 rounded-lg px-3 py-2.5 text-sm ${cls}`}>
      <div className="min-w-0">{children}</div>
      {onDismiss && (
        <button type="button" onClick={onDismiss} className="relative shrink-0 text-xs font-semibold underline after:absolute after:-inset-x-3 after:-inset-y-3.5 after:content-['']" aria-label="Dismiss message">
          Dismiss
        </button>
      )}
    </div>
  )
}

export function Skeleton({ rows = 3, className = 'h-14' }: { rows?: number; className?: string }) {
  return (
    <div className="space-y-2" aria-busy="true" aria-label="Loading">
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className={`animate-pulse rounded-lg bg-surface-alt ${className}`} />
      ))}
    </div>
  )
}

export function AccessDenied() {
  return (
    <div className="mx-auto max-w-md rounded-[14px] border border-border bg-surface px-6 py-10 text-center shadow-card">
      <p className="text-base font-semibold text-ink">You don't have access to this page</p>
      <p className="mt-1 text-sm text-muted">
        If you think you should, ask your Owner or Entity Admin to review your access.
      </p>
      <a href="/" className="btn-primary mt-4">
        Go to Home
      </a>
    </div>
  )
}

export function PageHeader({ title, description, actions }: { title: string; description?: string; actions?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-xl font-semibold text-ink">{title}</h1>
        {description && <p className="mt-0.5 text-sm text-muted">{description}</p>}
      </div>
      {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
    </div>
  )
}

export interface TabDef<K extends string> {
  key: K
  label: string
  badge?: number
}

/** WAI-ARIA tabs with arrow-key navigation. */
export function Tabs<K extends string>({
  tabs,
  active,
  onChange,
  label,
}: {
  tabs: TabDef<K>[]
  active: K
  onChange: (k: K) => void
  label: string
}) {
  const refs = useRef<Record<string, HTMLButtonElement | null>>({})
  function onKey(e: ReactKeyboardEvent, idx: number) {
    let next = -1
    if (e.key === 'ArrowRight') next = (idx + 1) % tabs.length
    else if (e.key === 'ArrowLeft') next = (idx - 1 + tabs.length) % tabs.length
    else if (e.key === 'Home') next = 0
    else if (e.key === 'End') next = tabs.length - 1
    if (next >= 0) {
      e.preventDefault()
      onChange(tabs[next].key)
      refs.current[tabs[next].key]?.focus()
    }
  }
  return (
    <div role="tablist" aria-label={label} className="-mx-4 flex gap-1 overflow-x-auto border-b border-border px-4 md:mx-0 md:px-0">
      {tabs.map((t, i) => {
        const selected = t.key === active
        return (
          <button
            key={t.key}
            ref={(el) => {
              refs.current[t.key] = el
            }}
            role="tab"
            type="button"
            id={`tab-${t.key}`}
            aria-selected={selected}
            aria-controls={`panel-${t.key}`}
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(t.key)}
            onKeyDown={(e) => onKey(e, i)}
            className={`min-h-11 shrink-0 border-b-2 px-3 text-sm font-semibold transition ${
              selected ? 'border-brand-blue text-brand-blue' : 'border-transparent text-muted hover:text-ink'
            }`}
          >
            {t.label}
            {t.badge ? (
              <span className="ml-1.5 rounded-full bg-brand-warning-soft px-1.5 py-0.5 text-[11px] text-brand-warning-solid">
                {t.badge}
              </span>
            ) : null}
          </button>
        )
      })}
    </div>
  )
}

export function TabPanel({ id, children }: { id: string; children: ReactNode }) {
  return (
    <div role="tabpanel" id={`panel-${id}`} aria-labelledby={`tab-${id}`} tabIndex={0} className="focus:outline-none">
      {children}
    </div>
  )
}

export interface Column<T> {
  key: string
  header: string
  render: (row: T) => ReactNode
  className?: string
}

/** Table on desktop; stacked, labelled cards below 768px. */
export function ResponsiveTable<T>({
  columns,
  rows,
  rowKey,
  caption,
  actions,
}: {
  columns: Column<T>[]
  rows: T[]
  rowKey: (row: T) => string
  caption: string
  actions?: (row: T) => ReactNode
}) {
  return (
    <>
      <div className="hidden overflow-x-auto rounded-[14px] border border-border bg-surface shadow-card md:block">
        <table className="w-full text-left text-sm">
          <caption className="sr-only">{caption}</caption>
          <thead className="border-b border-border bg-surface-alt text-xs uppercase tracking-wide text-muted">
            <tr>
              {columns.map((c) => (
                <th key={c.key} scope="col" className={`px-4 py-2.5 font-semibold ${c.className ?? ''}`}>
                  {c.header}
                </th>
              ))}
              {actions && (
                <th scope="col" className="px-4 py-2.5 text-right font-semibold">
                  <span className="sr-only">Actions</span>
                </th>
              )}
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((r) => (
              <tr key={rowKey(r)} className="align-middle">
                {columns.map((c) => (
                  <td key={c.key} className={`px-4 py-2.5 text-ink ${c.className ?? ''}`}>
                    {c.render(r)}
                  </td>
                ))}
                {actions && <td className="px-4 py-2 text-right">{actions(r)}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="space-y-2 md:hidden" aria-label={caption}>
        {rows.map((r) => (
          <li key={rowKey(r)} className="card">
            <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-sm">
              {columns.map((c) => (
                <div key={c.key} className="contents">
                  <dt className="text-muted">{c.header}</dt>
                  <dd className="min-w-0 text-ink">{c.render(r)}</dd>
                </div>
              ))}
            </dl>
            {actions && <div className="mt-3 flex flex-wrap gap-2">{actions(r)}</div>}
          </li>
        ))}
      </ul>
    </>
  )
}
