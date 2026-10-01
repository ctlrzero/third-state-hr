import type { UserRole } from '../types/db'

// Pure helpers for the Help Centre: role filtering, search ranking/snippets and a
// small Markdown parser. The parser produces plain data (never HTML), so the
// renderer can only ever create React elements - raw HTML in an article is shown as text.

export type HelpCategory = 'getting-started' | 'employee' | 'manager' | 'admin'

export const HELP_CATEGORIES: { key: HelpCategory; label: string; blurb: string }[] = [
  { key: 'getting-started', label: 'Getting started', blurb: 'Sign in, find your way around and learn the basics.' },
  { key: 'employee', label: 'For employees', blurb: 'Clock in, see your schedule, request leave and read payslips.' },
  { key: 'manager', label: 'For managers', blurb: 'Run your branch: schedules, attendance, leave and people.' },
  { key: 'admin', label: 'For company admins', blurb: 'Payroll, onboarding, documents and company settings.' },
]

export const HELP_ROLE_LABEL: Record<UserRole, string> = {
  owner: 'Owner',
  entity_admin: 'Company Admin',
  location_manager: 'Branch Manager',
  shift_supervisor: 'Shift Supervisor',
  staff: 'Employee',
}

export const HELP_ALL_ROLES: UserRole[] = ['staff', 'shift_supervisor', 'location_manager', 'entity_admin', 'owner']

/** Slug of the quick-start article pinned at the top of the help home. */
export const QUICK_START_SLUG = 'quick-start-for-new-staff'

export interface HelpArticleSummary {
  slug: string
  title: string
  category: HelpCategory
  audience: string[]
  summary: string
  related: string[]
  route: string | null
  last_reviewed: string | null
  updated_at?: string
}

export function categoryLabel(key: string): string {
  return HELP_CATEGORIES.find((c) => c.key === key)?.label ?? key
}

/** Same rule as the server: Owner and Company Admin see everything, others only their audience. The server is the real filter. */
export function articleVisibleToRole(audience: string[], role: UserRole | null | undefined): boolean {
  if (!role) return false
  if (role === 'owner' || role === 'entity_admin') return true
  return audience.includes(role)
}

export function filterByRole<T extends { audience: string[] }>(articles: T[], role: UserRole | null | undefined): T[] {
  return articles.filter((a) => articleVisibleToRole(a.audience, role))
}

/** Categories worth showing as tiles for a role, in a sensible order, with their article counts. */
export function categoryTiles(articles: HelpArticleSummary[]) {
  return HELP_CATEGORIES.map((c) => ({ ...c, count: articles.filter((a) => a.category === c.key).length })).filter((c) => c.count > 0)
}

/** Most recently reviewed first. */
export function recentlyReviewed(articles: HelpArticleSummary[], limit = 4): HelpArticleSummary[] {
  return [...articles]
    .filter((a) => a.last_reviewed)
    .sort((a, b) => (b.last_reviewed as string).localeCompare(a.last_reviewed as string) || a.title.localeCompare(b.title))
    .slice(0, limit)
}

export const REVIEW_DUE_DAYS = 180

/** Days between a YYYY-MM-DD date and `today` (a Date); null when there is no date. */
export function daysSince(date: string | null | undefined, today: Date = new Date()): number | null {
  if (!date) return null
  const [y, m, d] = date.split('-').map(Number)
  if (!y || !m || !d) return null
  const then = Date.UTC(y, m - 1, d)
  const now = Date.UTC(today.getFullYear(), today.getMonth(), today.getDate())
  return Math.floor((now - then) / 86400000)
}

export function isReviewDue(lastReviewed: string | null | undefined, today: Date = new Date()): boolean {
  const days = daysSince(lastReviewed, today)
  return days === null || days > REVIEW_DUE_DAYS
}

// ---------- search ----------

export interface SearchHit {
  slug: string
  title: string
  summary: string
  snippet: string
  rank: number
}

/** Order hits best-first; ties broken by title. Used on top of the server rank. */
export function rankHits<T extends { rank: number; title: string }>(hits: T[]): T[] {
  return [...hits].sort((a, b) => b.rank - a.rank || a.title.localeCompare(b.title))
}

/** Split a server snippet containing [[match]] markers into plain / highlighted parts. */
export function highlightParts(snippet: string): { text: string; match: boolean }[] {
  const parts: { text: string; match: boolean }[] = []
  const re = /\[\[(.*?)\]\]/gs
  let last = 0
  let m: RegExpExecArray | null
  while ((m = re.exec(snippet))) {
    if (m.index > last) parts.push({ text: snippet.slice(last, m.index), match: false })
    parts.push({ text: m[1], match: true })
    last = m.index + m[0].length
  }
  if (last < snippet.length) parts.push({ text: snippet.slice(last), match: false })
  return parts
}

/** Strip Markdown syntax so a snippet reads as plain text. */
export function plainText(md: string): string {
  return md
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/^\s*(?:[-*]|\d+\.)\s+/gm, '')
    .replace(/[*_`]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Client-side snippet around the first match of the query (used in the editor and as a fallback). */
export function makeSnippet(body: string, query: string, radius = 70): string {
  const text = plainText(body)
  const q = query.trim().toLowerCase()
  if (!q) return text.slice(0, radius * 2)
  const at = text.toLowerCase().indexOf(q)
  if (at < 0) return text.slice(0, radius * 2)
  const start = Math.max(0, at - radius)
  const end = Math.min(text.length, at + q.length + radius)
  return `${start > 0 ? '…' : ''}${text.slice(start, at)}[[${text.slice(at, at + q.length)}]]${text.slice(at + q.length, end)}${end < text.length ? '…' : ''}`
}

// ---------- markdown ----------

export interface LegendItem {
  n: number
  label: string
}

export type Inline =
  | { t: 'text'; v: string }
  | { t: 'strong'; c: Inline[] }
  | { t: 'em'; c: Inline[] }
  | { t: 'code'; v: string }
  | { t: 'link'; href: string; c: Inline[] }
  | { t: 'image'; alt: string; src: string; legend: LegendItem[] }

export type Block =
  | { t: 'heading'; level: 2 | 3 | 4; id: string; c: Inline[] }
  | { t: 'p'; c: Inline[] }
  | { t: 'ol'; items: Inline[][] }
  | { t: 'ul'; items: Inline[][] }
  | { t: 'figure'; alt: string; src: string; legend: LegendItem[] }
  | { t: 'quote'; c: Inline[] }

export function slugifyHeading(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
}

/** Only app-internal paths and http(s)/mailto links are allowed; anything else (javascript:, data:) becomes plain text. */
export function safeHref(href: string): string | null {
  const h = href.trim()
  if (/^\/(?!\/)/.test(h) || h.startsWith('#')) return h
  if (/^(https?:|mailto:)/i.test(h)) return h
  return null
}

/** Legend text from an image title: "1. Click Clock in | 2. Wait for the tick". */
export function parseLegend(title: string | undefined): LegendItem[] {
  if (!title) return []
  const items: LegendItem[] = []
  for (const part of title.split(' | ')) {
    const m = /^\s*(\d+)\.\s*(.+?)\s*$/.exec(part)
    if (m) items.push({ n: Number(m[1]), label: m[2] })
  }
  return items
}

const INLINE_RE = /!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)|\[([^\]]+)\]\(([^)\s]+)\)|\*\*(.+?)\*\*|`([^`]+)`|(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])/s

export function parseInline(src: string): Inline[] {
  const out: Inline[] = []
  let rest = src
  while (rest.length) {
    const m = INLINE_RE.exec(rest)
    if (!m) {
      out.push({ t: 'text', v: rest })
      break
    }
    if (m.index > 0) out.push({ t: 'text', v: rest.slice(0, m.index) })
    if (m[2] !== undefined) out.push({ t: 'image', alt: m[1], src: m[2], legend: parseLegend(m[3]) })
    else if (m[5] !== undefined) {
      const href = safeHref(m[5])
      out.push(href ? { t: 'link', href, c: parseInline(m[4]) } : { t: 'text', v: m[4] })
    } else if (m[6] !== undefined) out.push({ t: 'strong', c: parseInline(m[6]) })
    else if (m[7] !== undefined) out.push({ t: 'code', v: m[7] })
    else out.push({ t: 'em', c: parseInline(m[8]) })
    rest = rest.slice(m.index + m[0].length)
  }
  return out
}

/** Parse the limited Markdown used by help articles: headings, paragraphs, lists, images, quotes. */
export function parseMarkdown(md: string): Block[] {
  const lines = md.replace(/\r\n?/g, '\n').split('\n')
  const blocks: Block[] = []
  let para: string[] = []
  const flush = () => {
    if (!para.length) return
    const text = para.join(' ').trim()
    para = []
    if (!text) return
    const img = /^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)$/.exec(text)
    if (img) blocks.push({ t: 'figure', alt: img[1], src: img[2], legend: parseLegend(img[3]) })
    else blocks.push({ t: 'p', c: parseInline(text) })
  }
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (!line.trim()) {
      flush()
      continue
    }
    const h = /^(#{1,4})\s+(.+?)\s*#*$/.exec(line)
    if (h) {
      flush()
      // The page title is the article title, so "#" renders as a section heading too.
      const level = Math.min(Math.max(h[1].length, 2), 4) as 2 | 3 | 4
      blocks.push({ t: 'heading', level, id: slugifyHeading(h[2]), c: parseInline(h[2]) })
      continue
    }
    const li = /^\s*(\d+\.|[-*])\s+(.*)$/.exec(line)
    if (li) {
      flush()
      const ordered = /\d/.test(li[1])
      const items: Inline[][] = []
      let j = i
      let cur: string | null = null
      for (; j < lines.length; j++) {
        const m = /^\s*(\d+\.|[-*])\s+(.*)$/.exec(lines[j])
        if (m && /\d/.test(m[1]) === ordered) {
          if (cur !== null) items.push(parseInline(cur))
          cur = m[2]
        } else if (m || !lines[j].trim()) break
        else if (/^\s+\S/.test(lines[j]) && cur !== null) cur += ' ' + lines[j].trim()
        else break
      }
      if (cur !== null) items.push(parseInline(cur))
      blocks.push(ordered ? { t: 'ol', items } : { t: 'ul', items })
      i = j - 1
      continue
    }
    if (line.startsWith('> ')) {
      flush()
      blocks.push({ t: 'quote', c: parseInline(line.slice(2)) })
      continue
    }
    para.push(line.trim())
  }
  flush()
  return blocks
}

/** `shot:<key>` image sources used in a Markdown body. */
export function extractShotKeys(md: string): string[] {
  const keys = new Set<string>()
  for (const m of md.matchAll(/!\[[^\]]*\]\(shot:([a-z0-9][a-z0-9_-]*)/gi)) keys.add(m[1])
  return [...keys]
}

export function shotKey(src: string): string | null {
  const m = /^shot:([a-z0-9][a-z0-9_-]*)$/i.exec(src)
  return m ? m[1] : null
}

/** Resolve a `shot:` source to a signed URL from the map; any other source is not an allowed image and resolves to null. */
export function resolveShot(src: string, urls: Record<string, string>): string | null {
  const key = shotKey(src)
  return key ? (urls[key] ?? null) : null
}
