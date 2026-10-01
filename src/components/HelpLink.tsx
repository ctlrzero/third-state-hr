import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { helpListCached } from '../lib/api/help'

/**
 * One small "Need help? How to ..." link for a screen. Shows nothing until the
 * article is known, and nothing at all if the signed-in role can't read it.
 */
export function HelpLink({ slug, className = '' }: { slug: string; className?: string }) {
  const [title, setTitle] = useState<string | null>(null)
  useEffect(() => {
    let live = true
    helpListCached().then((list) => {
      const hit = list.find((a) => a.slug === slug)
      if (live && hit) setTitle(hit.title)
    })
    return () => {
      live = false
    }
  }, [slug])
  if (!title) return null
  return (
    <p className={`text-xs text-muted ${className}`}>
      Need help?{' '}
      <Link to={`/help/${slug}`} className="relative inline-block py-1 font-medium text-brand-blue-text underline underline-offset-2 hover:text-brand-primary after:absolute after:-inset-y-2 after:inset-x-0 after:content-['']">
        {title}
      </Link>
    </p>
  )
}
