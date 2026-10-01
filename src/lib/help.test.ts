import { describe, expect, it } from 'vitest'
import {
  articleVisibleToRole,
  extractShotKeys,
  filterByRole,
  highlightParts,
  isReviewDue,
  makeSnippet,
  parseLegend,
  parseMarkdown,
  rankHits,
  recentlyReviewed,
  resolveShot,
  safeHref,
  type HelpArticleSummary,
} from './help'

const art = (slug: string, audience: string[], last_reviewed: string | null = null): HelpArticleSummary => ({
  slug, title: slug, category: 'employee', audience, summary: '', related: [], route: null, last_reviewed,
})

describe('role filtering', () => {
  const list = [art('a', ['staff']), art('b', ['location_manager']), art('c', ['entity_admin', 'owner'])]
  it('staff only get their audience', () => {
    expect(filterByRole(list, 'staff').map((a) => a.slug)).toEqual(['a'])
  })
  it('owner and company admin see all', () => {
    expect(filterByRole(list, 'owner')).toHaveLength(3)
    expect(articleVisibleToRole(['staff'], 'entity_admin')).toBe(true)
  })
  it('no role sees nothing', () => {
    expect(filterByRole(list, null)).toHaveLength(0)
  })
})

describe('search helpers', () => {
  it('ranks by score then title', () => {
    expect(rankHits([{ rank: 1, title: 'b' }, { rank: 2, title: 'z' }, { rank: 1, title: 'a' }]).map((h) => h.title)).toEqual(['z', 'a', 'b'])
  })
  it('splits highlight markers', () => {
    expect(highlightParts('see [[leave]] now')).toEqual([
      { text: 'see ', match: false }, { text: 'leave', match: true }, { text: ' now', match: false }])
  })
  it('builds a snippet around the match without markdown', () => {
    const s = makeSnippet('## Steps\n1. Open **Leave** and tap Request leave to ask for time off.', 'request leave', 10)
    expect(s).toContain('[[Request leave]]')
    expect(s).not.toContain('**')
  })
  it('review due after 180 days', () => {
    const today = new Date(2026, 9, 1)
    expect(isReviewDue('2026-09-01', today)).toBe(false)
    expect(isReviewDue('2026-03-01', today)).toBe(true)
    expect(isReviewDue(null, today)).toBe(true)
  })
  it('recently reviewed is newest first', () => {
    expect(recentlyReviewed([art('a', [], '2026-01-01'), art('b', [], '2026-05-01'), art('c', [])]).map((a) => a.slug)).toEqual(['b', 'a'])
  })
})

describe('markdown', () => {
  it('turns shot: images into figures with a numbered legend', () => {
    const blocks = parseMarkdown('![Clock screen](shot:clock-home "1. Tap Clock in | 2. Wait for the tick")')
    expect(blocks).toEqual([{ t: 'figure', alt: 'Clock screen', src: 'shot:clock-home', legend: [{ n: 1, label: 'Tap Clock in' }, { n: 2, label: 'Wait for the tick' }] }])
    expect(parseLegend(undefined)).toEqual([])
  })
  it('resolves only shot: sources', () => {
    expect(resolveShot('shot:clock-home', { 'clock-home': 'https://x/y.png' })).toBe('https://x/y.png')
    expect(resolveShot('https://evil/x.png', { 'clock-home': 'u' })).toBeNull()
    expect(resolveShot('shot:missing', {})).toBeNull()
    expect(extractShotKeys('![a](shot:one) text ![b](shot:two "1. x")')).toEqual(['one', 'two'])
  })
  it('parses numbered steps and bold problems', () => {
    const b = parseMarkdown('## Steps\n\n1. Open **Leave**.\n2. Tap Request.\n\n## Common problems\n\n**No balance.** Ask your manager.')
    expect(b[0]).toMatchObject({ t: 'heading', level: 2, id: 'steps' })
    expect(b[1]).toMatchObject({ t: 'ol' })
    expect((b[1] as { items: unknown[] }).items).toHaveLength(2)
    expect(b[3]).toMatchObject({ t: 'p' })
  })
  it('never produces html or unsafe links', () => {
    const b = parseMarkdown('<script>alert(1)</script> [x](javascript:alert(1)) [ok](/leave)')
    const p = b[0] as { t: 'p'; c: { t: string; v?: string; href?: string }[] }
    expect(p.c.some((i) => i.t === 'link' && i.href === '/leave')).toBe(true)
    expect(p.c.some((i) => i.t === 'link' && i.href?.startsWith('javascript'))).toBe(false)
    expect(safeHref('data:text/html,x')).toBeNull()
    expect(safeHref('//evil.com')).toBeNull()
  })
})
