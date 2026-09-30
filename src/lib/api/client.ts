import { supabase } from '../supabase'

/**
 * Uniform result for every RPC wrapper in src/lib/api/*: either data or a
 * user-safe error message. A missing function (PGRST202 / 42883, e.g. a
 * deploy mismatch) becomes an ordinary error rather than a crash.
 */
export interface ApiResult<T> {
  data: T | null
  error: string | null
}

interface PgError {
  code?: string
  message?: string
  details?: string | null
  hint?: string | null
}

export function isMissingFunction(err: PgError | null | undefined): boolean {
  if (!err) return false
  if (err.code === 'PGRST202' || err.code === '42883') return true
  const msg = `${err.message ?? ''} ${err.details ?? ''}`.toLowerCase()
  return msg.includes('could not find the function') || (msg.includes('function') && msg.includes('does not exist'))
}

const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

/**
 * Turn any error (Postgres/PostgREST, fetch, Error, string) into plain English
 * that is safe to show staff. Messages our own RPCs raise are already written
 * for people and pass through; raw database / network wording is replaced.
 */
export function friendlyError(err: PgError | Error | string | null | undefined): string {
  if (!err) return 'Something went wrong. Please try again.'
  const code = typeof err === 'object' && 'code' in err ? (err as PgError).code : undefined
  const raw = (typeof err === 'string' ? err : (err.message ?? '')).replace(/^ERROR:\s*/i, '').replace(/^[A-Z0-9]{5}:\s*/, '').trim()
  const m = raw.toLowerCase()
  if (/failed to fetch|networkerror|load failed|network request failed/.test(m)) return 'No internet connection. Check your signal and try again.'
  if (/jwt|token (is )?expired|invalid claim|refresh token/.test(m)) return 'Your session has expired. Please sign in again.'
  if (/row-level security|^permission denied/.test(m) || (code === '42501' && !raw)) return 'You can’t do this. Please ask your manager.'
  if (/no home location or shift location/.test(m)) return 'We can’t tell which branch you work at. Please tell your manager.'
  if (/duplicate key|already exists/.test(m) && /constraint|duplicate key/.test(m)) return 'This already exists.'
  if (/violates (check|foreign key|not-null) constraint|invalid input syntax|out of range|value too long/.test(m))
    return 'That couldn’t be saved — something doesn’t look right. Please check and try again.'
  if (UUID_RE.test(raw)) return /not found|no longer/.test(m) ? 'This item no longer exists. Refresh and try again.' : 'Something went wrong. Please try again.'
  if (code === 'P0002' && !raw) return 'This item no longer exists. Refresh and try again.'
  if (raw && raw.length < 240) return raw
  return 'Something went wrong. Please try again.'
}

export async function callRpc<T>(fn: string, args?: Record<string, unknown>): Promise<ApiResult<T>> {
  try {
    const { data, error } = await supabase.rpc(fn, args ?? {})
    if (error) {
      if (isMissingFunction(error))
        return { data: null, error: 'This action is not available on the server right now. Please contact support.' }
      return { data: null, error: friendlyError(error) }
    }
    return { data: data as T, error: null }
  } catch (e) {
    return {
      data: null,
      error: friendlyError(e instanceof Error ? e : 'Failed to fetch'),
    }
  }
}

/**
 * Several RPCs return {ok:false, code, message} instead of raising. Normalise
 * that shape into ApiResult.error so callers only check one place.
 */
export function unwrapOk<T>(res: ApiResult<T>): ApiResult<T> {
  const d = res.data as { ok?: boolean; message?: string } | null
  if (d && typeof d === 'object' && d.ok === false) {
    return { data: res.data, error: d.message ?? 'The request was not accepted.' }
  }
  return res
}
