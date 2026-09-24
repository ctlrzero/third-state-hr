import { supabase } from '../supabase'

/**
 * Uniform result for every RPC wrapper in src/lib/api/*. `notAvailable` is
 * true when PostgREST reports the function doesn't exist yet (PGRST202 /
 * 42883) — screens render a "not available yet" state instead of an error,
 * because several RPCs are being rolled out by the backend in parallel.
 */
export interface ApiResult<T> {
  data: T | null
  error: string | null
  notAvailable: boolean
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

/** Turn a raw Postgres/PostgREST error into something safe to show a user. */
export function friendlyError(err: PgError | null | undefined): string {
  if (!err) return 'Something went wrong. Please try again.'
  const msg = err.message ?? ''
  // Raw Postgres privilege errors are not user-friendly; RPC-raised 42501s carry a readable message.
  if (err.code === '42501' && (!msg || /^permission denied/i.test(msg))) return 'You do not have permission to do that.'
  if (err.code === 'P0002' && !msg) return 'Not found.'
  if (msg && msg.length < 300) return msg
  return 'Something went wrong. Please try again.'
}

export async function callRpc<T>(fn: string, args?: Record<string, unknown>): Promise<ApiResult<T>> {
  try {
    const { data, error } = await supabase.rpc(fn, args ?? {})
    if (error) {
      if (isMissingFunction(error)) return { data: null, error: null, notAvailable: true }
      return { data: null, error: friendlyError(error), notAvailable: false }
    }
    return { data: data as T, error: null, notAvailable: false }
  } catch (e) {
    return {
      data: null,
      error: e instanceof Error ? e.message : 'Network error. Check your connection.',
      notAvailable: false,
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
    return { data: res.data, error: d.message ?? 'The request was not accepted.', notAvailable: false }
  }
  return res
}
