import { useEffect } from 'react'

// Visible non-production environment indicator + defense-in-depth noindex tag
// (Phase C4 + part of C2's "protect UAT from public indexing").
//
// Gated strictly on VITE_APP_ENV === 'uat'. Any other value — including the
// var being unset entirely, which is the case for every existing production
// env var template in this repo — renders nothing and adds no meta tag.
// Never gate this on hostname, NODE_ENV, or anything inferred at runtime; it
// must come from the build-time env var set explicitly per deployment.
//
// Note: Vercel Preview deployments already send an `X-Robots-Tag: noindex`
// response header automatically (Production deployments do not). This meta
// tag is a second, independent layer in case a UAT build is ever viewed
// through a URL Vercel doesn't treat as Preview.
export function EnvironmentBanner() {
  const isUat = import.meta.env.VITE_APP_ENV === 'uat'

  useEffect(() => {
    if (!isUat) return
    const meta = document.createElement('meta')
    meta.name = 'robots'
    meta.content = 'noindex, nofollow'
    document.head.appendChild(meta)
    return () => {
      document.head.removeChild(meta)
    }
  }, [isUat])

  if (!isUat) return null

  return (
    <div
      role="status"
      className="sticky top-0 z-50 flex items-center justify-center gap-2 bg-amber-400 px-3 py-1.5 text-center text-[12px] font-semibold tracking-wide text-amber-950"
    >
      UAT — TEST ENVIRONMENT — SYNTHETIC DATA ONLY
    </div>
  )
}
