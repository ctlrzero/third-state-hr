import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { EmptyState } from '../components/EmptyState'
import { HelpMarkdown } from '../components/HelpMarkdown'
import { Skeleton } from '../components/ui'
import { helpGetArticle, helpListCached, type HelpArticle as Article } from '../lib/api/help'
import { categoryLabel, type HelpArticleSummary } from '../lib/help'
import { fmtDate } from '../lib/format'

/** The article body exactly as readers see it. Also used by the admin Preview. */
export function ArticleView({ article, related }: { article: Pick<Article, 'title' | 'summary' | 'body_md' | 'last_reviewed' | 'route' | 'related'> & { category: string }; related: HelpArticleSummary[] }) {
  const [vote, setVote] = useState<'yes' | 'no' | null>(null)
  return (
    <article className="mx-auto max-w-[44rem]">
      <p className="text-xs font-medium uppercase tracking-wide text-muted">{categoryLabel(article.category)}</p>
      <h1 className="mt-1 text-2xl font-semibold text-ink">{article.title}</h1>
      {article.summary && <p className="mt-2 text-base text-muted">{article.summary}</p>}
      <p className="mt-2 text-xs text-muted">
        {article.last_reviewed ? `Last reviewed ${fmtDate(article.last_reviewed)}` : 'Not reviewed yet'}
        {article.route && (
          <>
            {' · '}
            <Link to={article.route} className="font-medium text-brand-blue-text underline underline-offset-2">
              Open this screen
            </Link>
          </>
        )}
      </p>
      <div className="mt-4 border-t border-border pt-1">
        <HelpMarkdown source={article.body_md} />
      </div>

      {related.length > 0 && (
        <nav aria-label="Related guides" className="mt-8 rounded-[14px] border border-border bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">Related guides</h2>
          <ul className="mt-2">
            {related.map((r) => (
              <li key={r.slug}>
                <Link to={`/help/${r.slug}`} className="flex min-h-11 items-center text-sm font-medium text-brand-blue-text underline-offset-2 hover:underline">
                  {r.title}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      )}

      <div className="mt-6 flex flex-wrap items-center gap-2 text-sm text-muted" role="group" aria-label="Was this helpful?">
        {vote ? (
          <span role="status">Thanks for letting us know.</span>
        ) : (
          <>
            <span>Was this helpful?</span>
            <button type="button" className="btn-secondary" onClick={() => setVote('yes')}>
              Yes
            </button>
            <button type="button" className="btn-secondary" onClick={() => setVote('no')}>
              No
            </button>
          </>
        )}
      </div>
    </article>
  )
}

export default function HelpArticle() {
  const { slug = '' } = useParams()
  const [article, setArticle] = useState<Article | null | undefined>(undefined)
  const [all, setAll] = useState<HelpArticleSummary[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let live = true
    setArticle(undefined)
    setError(null)
    helpGetArticle(slug).then((r) => {
      if (!live) return
      if (r.error) setError(r.error)
      setArticle(r.data)
    })
    helpListCached().then((l) => live && setAll(l))
    window.scrollTo(0, 0)
    return () => {
      live = false
    }
  }, [slug])

  return (
    <div className="space-y-4">
      <Link to="/help" className="inline-flex min-h-11 items-center text-sm font-medium text-brand-blue-text underline-offset-2 hover:underline">
        ← All guides
      </Link>
      {article === undefined ? (
        <Skeleton rows={5} className="h-16" />
      ) : article === null ? (
        <EmptyState title="We couldn't find that guide" description={error ?? 'It may have been moved, or it is not for your role.'} />
      ) : (
        <ArticleView article={article} related={article.related.map((s) => all.find((a) => a.slug === s)).filter((a): a is HelpArticleSummary => Boolean(a))} />
      )}
    </div>
  )
}
