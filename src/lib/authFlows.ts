// Pure helpers for the invite / set-password / forgot-password flows.
// Kept free of React and supabase-js so they are unit-tested directly.

export const MIN_PASSWORD_LENGTH = 8

/** Field-level validation for the set-password form. null = OK. */
export function validateNewPassword(password: string, confirm: string): { password?: string; confirm?: string } | null {
  const errors: { password?: string; confirm?: string } = {}
  if (password.length < MIN_PASSWORD_LENGTH) errors.password = `Use at least ${MIN_PASSWORD_LENGTH} characters.`
  else if (!password.trim()) errors.password = 'The password cannot be only spaces.'
  if (!errors.password && confirm !== password) errors.confirm = 'The passwords do not match.'
  return Object.keys(errors).length ? errors : null
}

/** Friendly copy for a supabase.auth.updateUser({password}) failure. */
export function passwordUpdateErrorMessage(message: string | null | undefined, code?: string | null): string {
  const text = `${code ?? ''} ${message ?? ''}`
  if (/same_password|should be different/i.test(text)) return 'Choose a password you have not used for this account before.'
  if (/weak_password|weak|pwned|leaked|characters/i.test(text))
    return message && message.length < 200 ? message : 'That password is too weak. Try a longer one.'
  if (/session|jwt|expired|not authenticated|auth session missing/i.test(text))
    return 'This link has expired. Ask your manager to resend the invite, or use "Forgot password?" on the sign-in page.'
  if (/fetch|network|failed to/i.test(text)) return "We couldn't reach the server. Check your connection and try again."
  return 'The password could not be saved. Please try again.'
}

export type InviteStatus = 'invited' | 'already_registered'

export interface InviteOutcome {
  tone: 'success' | 'info' | 'error'
  message: string
}

/**
 * Map the invite-user Edge Function result to the admin-facing notice.
 * `status` is set on success; otherwise `errorCode`/`errorMessage` come from
 * the function's JSON error body (or the transport error).
 */
export function inviteOutcomeMessage(
  email: string,
  result: { status?: InviteStatus | null; errorCode?: string | null; errorMessage?: string | null; httpStatus?: number | null }
): InviteOutcome {
  if (result.status === 'invited') return { tone: 'success', message: `Invitation email sent to ${email}.` }
  if (result.status === 'already_registered')
    return { tone: 'info', message: `${email} already has a login — access applied. They can sign in now.` }
  const code = result.errorCode ?? ''
  if (code === 'rate_limited' || result.httpStatus === 429)
    return { tone: 'error', message: 'Too many emails have been sent recently. Wait a few minutes, then use "Resend invite".' }
  if (code === 'no_pending_grant' || result.httpStatus === 409)
    return { tone: 'error', message: `Grant access to ${email} first, then send the invite.` }
  if (code === 'forbidden' || result.httpStatus === 403)
    return { tone: 'error', message: 'You do not have permission to invite this person.' }
  if (code === 'unauthenticated' || result.httpStatus === 401)
    return { tone: 'error', message: 'Your session has expired. Sign in again, then use "Resend invite".' }
  const detail = result.errorMessage && result.errorMessage.length < 200 ? ` ${result.errorMessage}` : ''
  return { tone: 'error', message: `The invitation email could not be sent.${detail} Use "Resend invite" to try again.` }
}

/** What an auth link (invite / recovery) carried in the URL. */
export interface AuthLinkParams {
  /** error from the link itself, e.g. otp_expired */
  error: string | null
  errorDescription: string | null
  /** PKCE code (?code=) */
  code: string | null
  /** token hash flow (?token_hash=&type=) */
  tokenHash: string | null
  type: string | null
}

/** Parse both the query string and the hash fragment of an auth redirect. */
export function parseAuthLinkParams(search: string, hash: string): AuthLinkParams {
  const q = new URLSearchParams(search.replace(/^\?/, ''))
  const h = new URLSearchParams(hash.replace(/^#/, ''))
  const get = (k: string) => q.get(k) ?? h.get(k)
  return {
    error: get('error_code') ?? get('error'),
    errorDescription: get('error_description'),
    code: q.get('code'),
    tokenHash: get('token_hash'),
    type: get('type'),
  }
}

/** Neutral forgot-password acknowledgement — never reveals whether the email exists. */
export const RESET_REQUESTED_MESSAGE = 'If an account exists for that email, a reset link is on its way. Check your inbox (and spam folder).'
