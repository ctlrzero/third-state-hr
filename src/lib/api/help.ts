import { supabase } from '../supabase'
import { callRpc, friendlyError, type ApiResult } from './client'
import type { HelpArticleSummary } from '../help'

export interface HelpArticle extends HelpArticleSummary {
  body_md: string
}

export interface HelpSearchRow {
  slug: string
  title: string
  category: string
  summary: string
  snippet: string
  rank: number
}

export interface HelpAdminRow {
  slug: string
  title: string
  category: string
  status: 'draft' | 'published' | 'archived'
  audience: string[]
  last_reviewed: string | null
  current_version: number
  has_draft: boolean
  updated_at: string
}

export interface HelpFields {
  title: string
  category: string
  audience: string[]
  summary: string
  body_md: string
  related: string[]
  route: string | null
}

export interface HelpAdminArticle {
  slug: string
  status: 'draft' | 'published' | 'archived'
  last_reviewed: string | null
  current_version: number
  updated_at: string
  live: HelpFields
  draft: HelpFields | null
}

export interface HelpVersion {
  version: number
  change_note: string | null
  created_at: string
  created_by_name: string | null
  snapshot: HelpFields
}

export const helpListArticles = () => callRpc<HelpArticleSummary[]>('help_list_articles')

export async function helpGetArticle(slug: string): Promise<ApiResult<HelpArticle | null>> {
  const res = await callRpc<HelpArticle[]>('help_get_article', { p_slug: slug })
  return { data: res.data?.[0] ?? null, error: res.error }
}

export const helpSearch = (query: string) => callRpc<HelpSearchRow[]>('help_search', { p_query: query })

export const helpAdminList = () => callRpc<HelpAdminRow[]>('help_admin_list')
export const helpAdminGet = (slug: string) => callRpc<HelpAdminArticle>('help_admin_get', { p_slug: slug })
export const helpAdminVersions = (slug: string) => callRpc<HelpVersion[]>('help_admin_versions', { p_slug: slug })

export const helpAdminSaveDraft = (slug: string, f: HelpFields) =>
  callRpc<{ ok: boolean }>('help_admin_save_draft', {
    p_slug: slug,
    p_title: f.title,
    p_category: f.category,
    p_audience: f.audience,
    p_summary: f.summary,
    p_body_md: f.body_md,
    p_related: f.related,
    p_route: f.route,
  })

export const helpAdminPublish = (slug: string, changeNote: string) =>
  callRpc<{ ok: boolean; version: number }>('help_admin_publish', { p_slug: slug, p_change_note: changeNote })

export const helpAdminMarkReviewed = (slug: string) => callRpc<{ ok: boolean }>('help_admin_mark_reviewed', { p_slug: slug })

export const helpAdminRestore = (slug: string, version: number) =>
  callRpc<{ ok: boolean }>('help_admin_restore_version', { p_slug: slug, p_version: version })

// ---- screenshots (private bucket; signed URLs only) ----

const BUCKET = 'help-media'
const urlCache = new Map<string, { url: string; at: number }>()

/** Signed URLs for screenshot keys (files are <key>.png). Cached for 30 minutes. */
export async function helpShotUrls(keys: string[]): Promise<Record<string, string>> {
  const out: Record<string, string> = {}
  const missing: string[] = []
  const now = Date.now()
  for (const k of keys) {
    const hit = urlCache.get(k)
    if (hit && now - hit.at < 30 * 60_000) out[k] = hit.url
    else missing.push(k)
  }
  if (missing.length) {
    try {
      const { data } = await supabase.storage.from(BUCKET).createSignedUrls(missing.map((k) => `${k}.png`), 3600)
      data?.forEach((row, i) => {
        if (row.signedUrl) {
          out[missing[i]] = row.signedUrl
          urlCache.set(missing[i], { url: row.signedUrl, at: now })
        }
      })
    } catch {
      // Pictures are optional; the article still reads fine without them.
    }
  }
  return out
}

/** Admin upload; returns the key to use as ![alt](shot:key). */
export async function helpUploadShot(file: File, key: string): Promise<ApiResult<string>> {
  if (!/^[a-z0-9][a-z0-9_-]*$/.test(key)) return { data: null, error: 'Use lowercase letters, numbers, dashes or underscores for the picture name.' }
  if (file.type !== 'image/png' && file.type !== 'image/jpeg') return { data: null, error: 'Please choose a PNG or JPG picture.' }
  if (file.size > 5 * 1024 * 1024) return { data: null, error: 'That picture is too large (limit 5 MB).' }
  // Files are always stored as <key>.png so article text stays the same regardless of source format.
  const { error } = await supabase.storage.from(BUCKET).upload(`${key}.png`, file, { upsert: true, contentType: file.type })
  if (error) return { data: null, error: friendlyError(error.message) }
  urlCache.delete(key)
  return { data: key, error: null }
}

// ---- shared list for HelpLink (one fetch per page load) ----
let listPromise: Promise<HelpArticleSummary[]> | null = null
export function helpListCached(): Promise<HelpArticleSummary[]> {
  if (!listPromise) {
    listPromise = helpListArticles().then((r) => {
      if (r.error) listPromise = null
      return r.data ?? []
    })
  }
  return listPromise
}
