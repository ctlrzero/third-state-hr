import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import type { EmailOtpType } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'
import { Alert } from '../components/ui'
import { MIN_PASSWORD_LENGTH, parseAuthLinkParams, passwordUpdateErrorMessage, validateNewPassword } from '../lib/authFlows'

type Phase = 'checking' | 'invalid' | 'form' | 'saving' | 'done'

const OTP_TYPES: readonly string[] = ['invite', 'recovery', 'signup', 'magiclink', 'email', 'email_change']

// Public route for both invitation links and password-recovery links.
// supabase-js (implicit flow, detectSessionInUrl) turns the #access_token
// fragment into a session on load and emits PASSWORD_RECOVERY for resets;
// ?code= (PKCE) and ?token_hash=&type= (custom email templates) are handled
// here too. Rendered outside ProtectedRoute, so the auth gate never bounces
// the user to /sign-in or /no-assignment before the password is saved.
export default function SetPassword() {
  const navigate = useNavigate()
  // Capture the link params on first render: supabase-js clears the hash once
  // it has read the tokens.
  const [link] = useState(() => parseAuthLinkParams(window.location.search, window.location.hash))
  const [phase, setPhase] = useState<Phase>('checking')
  const [email, setEmail] = useState<string | null>(null)
  const [linkError, setLinkError] = useState<string | null>(null)
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [show, setShow] = useState(false)
  const [fieldErrors, setFieldErrors] = useState<{ password?: string; confirm?: string }>({})
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const ready = (userEmail: string | null | undefined) => {
      // An expired/used link must not fall through to an unrelated session.
      if (cancelled || link.error) return
      setEmail(userEmail ?? null)
      setPhase((p) => (p === 'checking' || p === 'invalid' ? 'form' : p))
    }

    const { data: listener } = supabase.auth.onAuthStateChange((event, session) => {
      if (session && (event === 'PASSWORD_RECOVERY' || event === 'SIGNED_IN' || event === 'INITIAL_SESSION')) {
        ready(session.user.email)
      }
    })

    async function resolve() {
      if (link.error) {
        setLinkError(link.errorDescription)
        setPhase('invalid')
        return
      }
      // Waits for supabase-js to finish reading any #access_token fragment.
      const { data } = await supabase.auth.getSession()
      if (data.session) return ready(data.session.user.email)

      if (link.code) {
        const { data: ex, error: exErr } = await supabase.auth.exchangeCodeForSession(link.code)
        if (!exErr && ex.session) return ready(ex.session.user.email)
      } else if (link.tokenHash && link.type && OTP_TYPES.includes(link.type)) {
        const { data: v, error: vErr } = await supabase.auth.verifyOtp({
          token_hash: link.tokenHash,
          type: link.type as EmailOtpType,
        })
        if (!vErr && v.session) return ready(v.session.user.email)
      }
      if (!cancelled) setPhase((p) => (p === 'checking' ? 'invalid' : p))
    }
    resolve()

    return () => {
      cancelled = true
      listener.subscription.unsubscribe()
    }
  }, [link])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const fe = validateNewPassword(password, confirm)
    setFieldErrors(fe ?? {})
    if (fe) return
    setError(null)
    setPhase('saving')
    const { error: updateError } = await supabase.auth.updateUser({ password })
    if (updateError) {
      setError(passwordUpdateErrorMessage(updateError.message, (updateError as { code?: string }).code))
      setPhase('form')
      return
    }
    // Drop tokens / codes from the address bar before moving on.
    window.history.replaceState(null, '', window.location.pathname)
    setPhase('done')
    setTimeout(() => navigate('/', { replace: true }), 1200)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-alt px-4 py-8">
      <main className="w-full max-w-sm rounded-[14px] border border-border bg-surface p-6 shadow-card sm:p-8">
        <div className="mb-6 text-center">
          <div className="mx-auto mb-3 flex h-11 w-11 items-center justify-center rounded-[11px] bg-brand-primary text-[11px] font-extrabold text-white">
            TS
          </div>
          <h1 className="text-xl font-semibold text-ink">Set your password</h1>
          {email && (phase === 'form' || phase === 'saving') && (
            <p className="mt-1 text-sm text-muted">
              For <span className="font-medium text-ink">{email}</span>
            </p>
          )}
        </div>

        {phase === 'checking' && (
          <div className="flex items-center justify-center gap-3 py-6 text-muted" role="status">
            <span className="h-4 w-4 animate-spin rounded-full border-2 border-border border-t-brand-blue" aria-hidden="true" />
            Checking your link…
          </div>
        )}

        {phase === 'invalid' && (
          <div className="space-y-4">
            <Alert tone="error">
              This link is invalid or has expired{linkError ? ` (${linkError})` : ''}. Links can only be used once. Ask your manager to
              resend the invite, or request a new reset link from the sign-in page.
            </Alert>
            <Link to="/sign-in" className="btn-secondary w-full">
              Back to sign in
            </Link>
          </div>
        )}

        {phase === 'done' && (
          <div className="space-y-4">
            <Alert tone="success">Password saved. Taking you to your workspace…</Alert>
            <Link to="/" replace className="btn-primary w-full">
              Continue
            </Link>
          </div>
        )}

        {(phase === 'form' || phase === 'saving') && (
          <form onSubmit={handleSubmit} className="space-y-4" noValidate>
            <div>
              <label htmlFor="new-password" className="label">
                New password
              </label>
              <div className="relative">
                <input
                  id="new-password"
                  type={show ? 'text' : 'password'}
                  autoComplete="new-password"
                  required
                  minLength={MIN_PASSWORD_LENGTH}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  aria-invalid={Boolean(fieldErrors.password)}
                  aria-describedby="new-password-hint"
                  className="input pr-20"
                />
                <button
                  type="button"
                  onClick={() => setShow((v) => !v)}
                  aria-pressed={show}
                  aria-label={show ? 'Hide passwords' : 'Show passwords'}
                  className="absolute inset-y-0 right-0 min-w-11 px-3 text-sm font-semibold text-brand-blue"
                >
                  {show ? 'Hide' : 'Show'}
                </button>
              </div>
              <p
                id="new-password-hint"
                className={`mt-1 text-xs ${fieldErrors.password ? 'font-medium text-brand-risk-text' : 'text-muted'}`}
              >
                {fieldErrors.password ?? `At least ${MIN_PASSWORD_LENGTH} characters.`}
              </p>
            </div>

            <div>
              <label htmlFor="confirm-password" className="label">
                Confirm password
              </label>
              <input
                id="confirm-password"
                type={show ? 'text' : 'password'}
                autoComplete="new-password"
                required
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                aria-invalid={Boolean(fieldErrors.confirm)}
                aria-describedby={fieldErrors.confirm ? 'confirm-password-err' : undefined}
                className="input"
              />
              {fieldErrors.confirm && (
                <p id="confirm-password-err" className="mt-1 text-xs font-medium text-brand-risk-text">
                  {fieldErrors.confirm}
                </p>
              )}
            </div>

            {error && <Alert tone="error">{error}</Alert>}

            <button type="submit" disabled={phase === 'saving'} className="btn-primary w-full">
              {phase === 'saving' && (
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/40 border-t-white" aria-hidden="true" />
              )}
              {phase === 'saving' ? 'Saving…' : 'Save password'}
            </button>
          </form>
        )}
      </main>
    </div>
  )
}
