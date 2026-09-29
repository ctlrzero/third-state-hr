import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

// Apple's scroll-deceleration projection: where a flick would come to rest.
function project(velocity: number, decelerationRate = 0.998) {
  return ((velocity / 1000) * decelerationRate) / (1 - decelerationRate)
}
function rubberband(overshoot: number, dimension: number, constant = 0.55) {
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot))
}
const INTERACTIVE = 'input, select, textarea, button, a, label, [contenteditable="true"], [data-no-drag]'

export function Sheet({
  title,
  subtitle,
  onClose,
  footer,
  children,
}: {
  title: string
  subtitle?: string
  onClose: () => void
  footer?: ReactNode
  children: ReactNode
}) {
  const [open, setOpen] = useState(false)
  const panel = useRef<HTMLDivElement>(null)
  const scrim = useRef<HTMLDivElement>(null)
  const closing = useRef(false)
  const closed = useRef(false)
  const onCloseRef = useRef(onClose)
  useEffect(() => {
    onCloseRef.current = onClose
  }, [onClose])
  const titleId = useId()
  const fireClose = useCallback(() => {
    if (closed.current) return
    closed.current = true
    onCloseRef.current()
  }, [])

  useEffect(() => {
    const prevFocus = document.activeElement as HTMLElement | null
    const prevOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    // Flush the closed style so the open transition always has a start point.
    panel.current?.getBoundingClientRect()
    setOpen(true)
    panel.current?.focus({ preventScroll: true })
    return () => {
      document.body.style.overflow = prevOverflow
      prevFocus?.focus?.({ preventScroll: true })
    }
  }, [])

  const finishClose = useCallback(() => {
    if (closing.current) fireClose()
  }, [fireClose])

  const requestClose = useCallback(() => {
    const el = panel.current
    closing.current = true
    if (el) {
      el.style.transform = ''
      el.style.transition = ''
    }
    if (scrim.current) scrim.current.style.opacity = ''
    setOpen(false)
    window.setTimeout(finishClose, 650)
  }, [finishClose])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') requestClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [requestClose])

  // ---- drag to dismiss (horizontal only; vertical stays native scroll) ----
  const drag = useRef<{
    id: number
    startX: number
    startY: number
    origin: number
    active: boolean
    history: { x: number; t: number }[]
  } | null>(null)

  function liveTranslateX(el: HTMLElement) {
    const m = new DOMMatrixReadOnly(getComputedStyle(el).transform)
    return m.m41
  }

  function onPointerDown(e: React.PointerEvent) {
    const el = panel.current
    if (!el || e.button !== 0 || (e.target as HTMLElement).closest(INTERACTIVE)) return
    drag.current = { id: e.pointerId, startX: e.clientX, startY: e.clientY, origin: 0, active: false, history: [] }
  }

  function onPointerMove(e: React.PointerEvent) {
    const d = drag.current
    const el = panel.current
    if (!d || !el || d.id !== e.pointerId) return
    const dx = e.clientX - d.startX
    const dy = e.clientY - d.startY
    if (!d.active) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
        drag.current = null
        return
      }
      if (Math.abs(dx) < 10) return
      // Grab from wherever the sheet is right now — even mid-animation.
      d.origin = liveTranslateX(el)
      d.active = true
      closing.current = false
      setOpen(true)
      el.dataset.dragging = 'true'
      try {
        el.setPointerCapture(e.pointerId)
      } catch {
        // pointer already gone; tracking still works via bubbling
      }
    }
    const width = el.offsetWidth
    let x = d.origin + dx
    if (x < 0) x = -rubberband(-x, width)
    el.style.transform = `translateX(${x}px)`
    if (scrim.current) scrim.current.style.opacity = String(Math.max(0, 1 - Math.max(0, x) / width))
    d.history.push({ x: e.clientX, t: e.timeStamp })
    if (d.history.length > 6) d.history.shift()
  }

  function onPointerUp() {
    const d = drag.current
    const el = panel.current
    drag.current = null
    if (!d || !el || !d.active) return
    delete el.dataset.dragging
    const h = d.history
    const first = h[0]
    const last = h[h.length - 1]
    const dt = last && first ? Math.max(1, last.t - first.t) : 1
    const velocity = last && first ? ((last.x - first.x) / dt) * 1000 : 0
    const x = liveTranslateX(el)
    const width = el.offsetWidth

    if (x + project(velocity) > width * 0.45) {
      // Continue at the finger's speed into the edge.
      const remaining = width - x
      const ms = Math.round(Math.min(420, Math.max(160, velocity > 0 ? (remaining / velocity) * 1000 * 1.6 : 360)))
      el.style.transition = `transform ${ms}ms cubic-bezier(0.2, 0.7, 0.3, 1)`
      el.style.transform = `translateX(${width * 1.05}px)`
      if (scrim.current) {
        scrim.current.style.transition = `opacity ${ms}ms ease`
        scrim.current.style.opacity = '0'
      }
      closing.current = true
      window.setTimeout(fireClose, ms)
      return
    }
    // Spring home — bounce only because the gesture carried momentum.
    const flicked = Math.abs(velocity) > 300
    el.style.transition = flicked
      ? 'transform var(--spring-bounce-ms) var(--spring-bounce)'
      : 'transform var(--spring-smooth-ms) var(--spring-smooth)'
    el.style.transform = ''
    if (scrim.current) scrim.current.style.opacity = ''
    const clear = () => {
      el.style.transition = ''
      el.removeEventListener('transitionend', clear)
    }
    el.addEventListener('transitionend', clear)
  }

  return createPortal(
    <>
      <div ref={scrim} className="sheet-scrim" data-open={open} onClick={requestClose} aria-hidden="true" />
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className="sheet outline-none"
        data-open={open}
        onTransitionEnd={(e) => {
          if (e.target === panel.current && !open) finishClose()
        }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        <span className="sheet__grab" aria-hidden="true" />
        <header className="material material-edge-bottom sticky top-0 z-10 flex items-start justify-between gap-4 px-6 pb-4 pt-5">
          <div className="min-w-0">
            <h2 id={titleId} className="text-lg font-semibold leading-tight tracking-[-0.01em] text-ink">
              {title}
            </h2>
            {subtitle && <p className="mt-1 text-[13px] leading-snug text-muted">{subtitle}</p>}
          </div>
          <button onClick={requestClose} className="press shrink-0 rounded-full bg-surface-alt px-3.5 py-1.5 text-sm font-medium text-ink hover:bg-border">
            Done
          </button>
        </header>
        <div className="flex-1 overflow-y-auto px-6 py-5">{children}</div>
        {footer && <footer className="material material-edge-top sticky bottom-0 px-6 py-4">{footer}</footer>}
      </div>
    </>,
    document.body
  )
}
