import { useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { EmptyState } from '../components/EmptyState'
import { Alert, PageHeader, Skeleton } from '../components/ui'
import { helpListArticles, helpSearch, type HelpSearchRow } from '../lib/api/help'
import {
  QUICK_START_SLUG,
  categoryLabel,
  categoryTiles,
  highlightParts,
  rankHits,
  recentlyReviewed,
  type HelpArticleSummary,
} from '../lib/help'
import { fmtDate } from '../lib/format'

function Snippet({ text }: { text: string }) {
  return (
    <p className="mt-1 text-sm text-muted">
      {highlightParts(text).map((p, i) =>
        p.match ? <mark key={i} className="rounded bg-brand-warning-soft px-0.5 text-ink">{p.text}</mark> : <span key={i}>{p.text}</span>
      )}
    </p>
  )
}

function ArticleRow({ a }: { a: Pick<HelpArticleSummary, 'slug' | 'title' | 'summary'> & { last_reviewed?: string | null } }) {
  return (
    <Link
      to={`/help/${a.slug}`}
      className="block min-h-11 rounded-xl border border-border bg-surface px-4 py-3 hover:border-brand-blue focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-blue"
    >
      <span className="text-sm font-semibold text-ink">{a.title}</span>
      {a.summary && <span className="mt-0.5 block text-sm text-muted">{a.summary}</span>}
    </Link>
  )
}

export default function Help() {
  const { profile } = useAuth()
  const [params, setParams] = useSearchParams()
  const q = params.get('q') ?? ''
  const [draft, setDraft] = useState(q)
  const [articles, setArticles] = useState<HelpArticleSummary[] | null>(null)
  const [hits, setHits] = useState<HelpSearchRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const isAdmin = profile?.role === 'owner' || profile?.role === 'entity_admin'

  useEffect(() => {
    helpListArticles().then((r) => {
      if (r.error) setError(r.error)
      setArticles(r.data ?? [])
    })
  }, [])

  useEffect(() => setDraft(q), [q])

  // Search as the person types, once there are two characters.
  useEffect(() => {
    const t = setTimeout(() => {
      const next = draft.trim()
      if (next !== q) setParams(next ? { q: next } : {}, { replace: true })
    }, 300)
    return () => clearTimeout(t)
  }, [draft, q, setParams])

  useEffect(() => {
    let live = true
    if (q.trim().length < 2) {
      setHits(null)
      return
    }
    setHits(null)
    helpSearch(q.trim()).then((r) => {
      if (!live) return
      if (r.error) setError(r.error)
      setHits(rankHits(r.data ?? []))
    })
    return () => {
      live = false
    }
  }, [q])

  const quick = articles?.find((a) => a.slug === QUICK_START_SLUG)
  const tiles = useMemo(() => categoryTiles((articles ?? []).filter((a) => a.slug !== QUICK_START_SLUG)), [articles])
  const recent = useMemo(() => recentlyReviewed((articles ?? []).filter((a) => a.slug !== QUICK_START_SLUG)), [articles])
  const searching = q.trim().length >= 2

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <PageHeader
        title="Help & Guides"
        description="Step-by-step guides for the things you do in Third State HR."
        actions={
          isAdmin ? (
            <Link to="/help/admin" className="btn-secondary">
              Manage articles
            </Link>
          ) : undefined
        }
      />
      {error && <Alert tone="error" onDismiss={() => setError(null)}>{error}</Alert>}

      <form role="search" onSubmit={(e) => e.preventDefault()}>
        <label htmlFor="help-search" className="label">
          Search the guides
        </label>
        <input
          id="help-search"
          type="search"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="For example: request leave, clock in, payslip"
          className="input min-h-11 w-full"
          autoComplete="off"
        />
      </form>

      {!articles ? (
        <Skeleton rows={4} className="h-20" />
      ) : searching ? (
        <section aria-live="polite" aria-label="Search results">
          {!hits ? (
            <Skeleton rows={3} className="h-20" />
          ) : hits.length === 0 ? (
            <EmptyState title="No guides found" description="Try a different word, or browse the topics below." />
          ) : (
            <ul className="space-y-2">
              <li className="text-sm text-muted" role="status">
                {hits.length} {hits.length === 1 ? 'guide' : 'guides'} found
              </li>
              {hits.map((h) => (
                <li key={h.slug}>
                  <Link
                    to={`/help/${h.slug}`}
                    className="block min-h-11 rounded-xl border border-border bg-surface px-4 py-3 hover:border-brand-blue focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-blue"
                  >
                    <span className="text-xs font-medium uppercase tracking-wide text-muted">{categoryLabel(h.category)}</span>
                    <span className="block text-sm font-semibold text-ink">{h.title}</span>
                    <Snippet text={h.snippet || h.summary} />
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </section>
      ) : articles.length === 0 ? (
        <EmptyState title="No guides yet" description="Guides will appear here as soon as they are published." />
      ) : (
        <>
          {quick && (
            <Link
              to={`/help/${quick.slug}`}
              className="block rounded-[14px] bg-brand-primary p-5 text-white shadow-card focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-blue focus-visible:ring-offset-2"
            >
              <span className="text-xs font-semibold uppercase tracking-wide text-white/70">Start here</span>
              <span className="mt-1 block text-lg font-semibold">{quick.title}</span>
              {quick.summary && <span className="mt-1 block text-sm text-white/85">{quick.summary}</span>}
            </Link>
          )}

          <section aria-labelledby="help-topics">
            <h2 id="help-topics" className="mb-3 text-base font-semibold text-ink">
              Browse by topic
            </h2>
            <div className="grid gap-3 sm:grid-cols-2">
              {tiles.map((t) => (
                <div key={t.key} className="rounded-[14px] border border-border bg-surface p-4 shadow-card">
                  <h3 className="text-sm font-semibold text-ink">{t.label}</h3>
                  <p className="mt-0.5 text-xs text-muted">{t.blurb}</p>
                  <ul className="mt-3 space-y-1">
                    {articles
                      .filter((a) => a.category === t.key && a.slug !== QUICK_START_SLUG)
                      .map((a) => (
                        <li key={a.slug}>
                          <Link to={`/help/${a.slug}`} className="flex min-h-11 items-center text-sm font-medium text-brand-blue-text underline-offset-2 hover:underline focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-blue">
                            {a.title}
                          </Link>
                        </li>
                      ))}
                  </ul>
                </div>
              ))}
            </div>
          </section>

          {recent.length > 0 && (
            <section aria-labelledby="help-recent">
              <h2 id="help-recent" className="mb-3 text-base font-semibold text-ink">
                Recently reviewed
              </h2>
              <ul className="grid gap-2 sm:grid-cols-2">
                {recent.map((a) => (
                  <li key={a.slug}>
                    <ArticleRow a={a} />
                    <p className="mt-1 px-1 text-xs text-muted">Reviewed {fmtDate(a.last_reviewed)}</p>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </div>
  )
}
