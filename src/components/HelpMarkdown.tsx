import { Fragment, useEffect, useMemo, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { helpShotUrls } from '../lib/api/help'
import { extractShotKeys, parseMarkdown, resolveShot, shotKey, type Block, type Inline, type LegendItem } from '../lib/help'
import { Modal } from './ui'

// Renders help Markdown as React elements (no innerHTML, so article text can never inject markup).
// The same component is used by readers and by the admin Preview, so Preview looks exactly like the live page.

function Legend({ items }: { items: LegendItem[] }) {
  if (!items.length) return null
  return (
    <ol className="mt-2 space-y-1.5 text-sm text-ink" aria-label="Numbered parts of the picture">
      {items.map((it) => (
        <li key={it.n} className="flex items-start gap-2">
          <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-brand-primary text-[11px] font-bold text-white" aria-hidden="true">
            {it.n}
          </span>
          <span>
            <span className="sr-only">Number {it.n}: </span>
            {it.label}
          </span>
        </li>
      ))}
    </ol>
  )
}

function Figure({ alt, src, legend, urls }: { alt: string; src: string; legend: LegendItem[]; urls: Record<string, string> }) {
  const [zoom, setZoom] = useState(false)
  const url = resolveShot(src, urls)
  const key = shotKey(src)
  return (
    <figure className="my-5">
      {url ? (
        <button
          type="button"
          onClick={() => setZoom(true)}
          className="block min-h-11 w-full overflow-hidden rounded-xl border border-border bg-surface-alt focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-blue"
          aria-label={`Enlarge picture: ${alt}`}
        >
          <img src={url} alt={alt} loading="lazy" className="mx-auto max-h-[28rem] w-auto max-w-full" />
        </button>
      ) : (
        <div className="flex min-h-24 items-center justify-center rounded-xl border border-dashed border-border bg-surface-alt px-4 py-6 text-center text-sm text-muted">
          {key ? `Picture “${alt}” is not available yet.` : 'Picture not available.'}
        </div>
      )}
      <figcaption className="mt-2 text-xs text-muted">{alt}</figcaption>
      <Legend items={legend} />
      <Modal
        open={zoom}
        title={alt}
        onClose={() => setZoom(false)}
        footer={
          <button type="button" className="btn-secondary" onClick={() => setZoom(false)}>
            Close
          </button>
        }
      >
        {url && <img src={url} alt={alt} className="max-h-[70vh] w-full object-contain" />}
        <Legend items={legend} />
      </Modal>
    </figure>
  )
}

function renderInline(nodes: Inline[]): ReactNode {
  return nodes.map((n, i) => {
    switch (n.t) {
      case 'text':
        return <Fragment key={i}>{n.v}</Fragment>
      case 'strong':
        return <strong key={i} className="font-semibold">{renderInline(n.c)}</strong>
      case 'em':
        return <em key={i}>{renderInline(n.c)}</em>
      case 'code':
        return <code key={i} className="rounded bg-surface-alt px-1 py-0.5 text-[0.9em]">{n.v}</code>
      case 'link': {
        const cls = 'font-medium text-brand-blue-text underline underline-offset-2 hover:text-brand-primary'
        if (n.href.startsWith('/')) return <Link key={i} to={n.href} className={cls}>{renderInline(n.c)}</Link>
        const external = /^https?:/i.test(n.href)
        return (
          <a key={i} href={n.href} className={cls} {...(external ? { target: '_blank', rel: 'noopener noreferrer' } : {})}>
            {renderInline(n.c)}
          </a>
        )
      }
      case 'image':
        return <span key={i} className="text-muted">[{n.alt}]</span>
    }
  })
}

function renderBlock(b: Block, i: number, urls: Record<string, string>): ReactNode {
  switch (b.t) {
    case 'heading': {
      const cls = b.level === 2 ? 'mt-8 text-lg font-semibold text-ink' : 'mt-6 text-base font-semibold text-ink'
      return b.level === 2 ? (
        <h2 key={i} id={b.id} className={cls}>{renderInline(b.c)}</h2>
      ) : (
        <h3 key={i} id={b.id} className={cls}>{renderInline(b.c)}</h3>
      )
    }
    case 'p':
      return <p key={i} className="mt-3 text-[15px] leading-7 text-ink">{renderInline(b.c)}</p>
    case 'ol':
      return (
        <ol key={i} className="mt-3 space-y-3">
          {b.items.map((it, j) => (
            <li key={j} className="flex items-start gap-3 text-[15px] leading-7 text-ink">
              <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-primary text-sm font-semibold text-white" aria-hidden="true">
                {j + 1}
              </span>
              <span className="min-w-0 flex-1">{renderInline(it)}</span>
            </li>
          ))}
        </ol>
      )
    case 'ul':
      return (
        <ul key={i} className="mt-3 list-disc space-y-1.5 pl-6 text-[15px] leading-7 text-ink marker:text-muted">
          {b.items.map((it, j) => <li key={j}>{renderInline(it)}</li>)}
        </ul>
      )
    case 'quote':
      return <blockquote key={i} className="mt-3 border-l-4 border-brand-blue/40 bg-brand-blue-soft px-4 py-2 text-[15px] text-ink">{renderInline(b.c)}</blockquote>
    case 'figure':
      return <Figure key={i} alt={b.alt} src={b.src} legend={b.legend} urls={urls} />
  }
}

export function HelpMarkdown({ source }: { source: string }) {
  const blocks = useMemo(() => parseMarkdown(source), [source])
  const keys = useMemo(() => extractShotKeys(source).sort().join(','), [source])
  const [urls, setUrls] = useState<Record<string, string>>({})
  useEffect(() => {
    let live = true
    if (keys) helpShotUrls(keys.split(',')).then((u) => live && setUrls(u))
    return () => {
      live = false
    }
  }, [keys])
  return <div className="help-prose">{blocks.map((b, i) => renderBlock(b, i, urls))}</div>
}
