import { describe, expect, it } from 'vitest'
import {
  RESET_REQUESTED_MESSAGE,
  inviteOutcomeMessage,
  parseAuthLinkParams,
  passwordUpdateErrorMessage,
  validateNewPassword,
} from './authFlows'

describe('validateNewPassword', () => {
  it('requires at least 8 characters', () => {
    expect(validateNewPassword('short', 'short')?.password).toMatch(/at least 8/)
    expect(validateNewPassword('1234567', '1234567')?.password).toBeDefined()
  })
  it('rejects a whitespace-only password', () => {
    expect(validateNewPassword('        ', '        ')?.password).toMatch(/spaces/)
  })
  it('requires the confirmation to match', () => {
    expect(validateNewPassword('longenough', 'longenougH')).toEqual({ confirm: 'The passwords do not match.' })
  })
  it('accepts a valid, matching password', () => {
    expect(validateNewPassword('correct horse', 'correct horse')).toBeNull()
  })
})

describe('passwordUpdateErrorMessage', () => {
  it('maps same-password and expired-session errors', () => {
    expect(passwordUpdateErrorMessage('New password should be different from the old password.', 'same_password')).toMatch(/not used/)
    expect(passwordUpdateErrorMessage('Auth session missing!')).toMatch(/expired/)
  })
  it('falls back to a generic message', () => {
    expect(passwordUpdateErrorMessage('boom')).toBe('The password could not be saved. Please try again.')
  })
})

describe('inviteOutcomeMessage', () => {
  const email = 'new.hire@thirdstate.ae'
  it('reports a sent invitation', () => {
    expect(inviteOutcomeMessage(email, { status: 'invited' })).toEqual({ tone: 'success', message: `Invitation email sent to ${email}.` })
  })
  it('reports an existing login as access applied', () => {
    const o = inviteOutcomeMessage(email, { status: 'already_registered' })
    expect(o.tone).toBe('info')
    expect(o.message).toMatch(/already has a login — access applied/)
  })
  it('maps rate limits, missing grants and permission errors', () => {
    expect(inviteOutcomeMessage(email, { errorCode: 'rate_limited', httpStatus: 429 }).message).toMatch(/Too many emails/)
    expect(inviteOutcomeMessage(email, { httpStatus: 429 }).message).toMatch(/Too many emails/)
    expect(inviteOutcomeMessage(email, { errorCode: 'no_pending_grant', httpStatus: 409 }).message).toMatch(/Grant access/)
    expect(inviteOutcomeMessage(email, { errorCode: 'forbidden', httpStatus: 403 }).message).toMatch(/permission/)
    expect(inviteOutcomeMessage(email, { httpStatus: 401 }).message).toMatch(/session has expired/)
  })
  it('falls back to a resend hint for anything else', () => {
    const o = inviteOutcomeMessage(email, { errorMessage: 'Failed to send a request to the Edge Function' })
    expect(o.tone).toBe('error')
    expect(o.message).toMatch(/Resend invite/)
  })
})

describe('parseAuthLinkParams', () => {
  it('reads an expired-link error from the hash', () => {
    const p = parseAuthLinkParams('', '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired')
    expect(p.error).toBe('otp_expired')
    expect(p.errorDescription).toBe('Email link is invalid or has expired')
  })
  it('reads PKCE codes and token hashes from the query string', () => {
    expect(parseAuthLinkParams('?code=abc', '').code).toBe('abc')
    const t = parseAuthLinkParams('?token_hash=xyz&type=recovery', '')
    expect(t).toMatchObject({ tokenHash: 'xyz', type: 'recovery', error: null })
  })
  it('reads the implicit-flow type from the hash', () => {
    expect(parseAuthLinkParams('', '#access_token=t&type=invite').type).toBe('invite')
  })
})

it('forgot-password copy never reveals whether the account exists', () => {
  expect(RESET_REQUESTED_MESSAGE).toMatch(/^If an account exists for that email/)
})
