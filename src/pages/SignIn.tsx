import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { SESSION_EXPIRED_KEY, useAuth } from '../auth/AuthContext'
import { Alert } from '../components/ui'
import { supabase } from '../lib/supabase'
import { RESET_REQUESTED_MESSAGE } from '../lib/authFlows'

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

function readExpiredFlag(): boolean {
  try {
    return sessionStorage.getItem(SESSION_EXPIRED_KEY) === '1'
  } catch {
    return false
  }
}

// UX-01 Sign-in. No sensitive data renders before a successful
// authentication result; the entity switcher lives in the app shell, so a
// failed/partial login can never leak scope.
export default function SignIn() {
  const { status, signInWithPassword } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [fieldErrors, setFieldErrors] = useState<{ email?: string; password?: string }>({})
  const [sessionExpired] = useState(readExpiredFlag)
  const [forgotOpen, setForgotOpen] = useState(false)

  if (status === 'ready') return <Navigate to="/" replace />
  // Authenticated but inactive / not linked to a workspace.
  if (status === 'no-assignment') return <Navigate to="/no-assignment" replace />

  if (forgotOpen) return <ForgotPassword initialEmail={email} onBack={() => setForgotOpen(false)} />

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const fe: typeof fieldErrors = {}
    if (!EMAIL_RE.test(email.trim())) fe.email = 'Enter your work email address.'
    if (!password) fe.password = 'Enter your password.'
    setFieldErrors(fe)
    if (Object.keys(fe).length) return
    setError(null)
    setSubmitting(true)
    const { error: authError } = await signInWithPassword(email.trim(), password)
    setSubmitting(false)
    if (authError) {
      // Supabase returns "Invalid login credentials" for both unknown email and
      // wrong password — never disclose which.
      if (/invalid login credentials|invalid credentials/i.test(authError)) {
        setError('Invalid email or password. Please try again.')
      } else if (/email not confirmed/i.test(authError)) {
        setError('Your account has not been activated yet. Check your email for the invitation link.')
      } else if (/fetch|network|failed to/i.test(authError)) {
        setError("We couldn't reach the server. Check your connection and try again.")
      } else if (/too many|rate limit/i.test(authError)) {
        setError('Too many attempts. Please wait a minute and try again.')
      } else {
        setError('Sign-in failed. Please try again.')
      }
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-alt px-4 py-8">
      <main className="w-full max-w-sm rounded-[14px] border border-border bg-surface p-6 shadow-card sm:p-8">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-11 w-11 items-center justify-center rounded-[11px] bg-brand-primary text-[11px] font-extrabold text-white">
            TS
          </div>
          <h1 className="text-xl font-semibold text-ink">Third State Café HR</h1>
          <p className="mt-1 text-sm text-muted">Sign in to your workspace</p>
        </div>

        {sessionExpired && !error && (
          <div className="mb-4">
            <Alert tone="info">Your session has expired. Please sign in again.</Alert>
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4" noValidate>
          <div>
            <label htmlFor="email" className="label">
              Work email
            </label>
            <input
              id="email"
              type="email"
              inputMode="email"
              autoComplete="username"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              aria-invalid={Boolean(fieldErrors.email)}
              aria-describedby={fieldErrors.email ? 'email-err' : undefined}
              className="input"
            />
            {fieldErrors.email && (
              <p id="email-err" className="mt-1 text-xs font-medium text-brand-risk-text">
                {fieldErrors.email}
              </p>
            )}
          </div>

          <div>
            <label htmlFor="password" className="label">
              Password
            </label>
            <div className="relative">
              <input
                id="password"
                type={showPassword ? 'text' : 'password'}
                autoComplete="current-password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                aria-invalid={Boolean(fieldErrors.password)}
                aria-describedby={fieldErrors.password ? 'password-err' : undefined}
                className="input pr-20"
              />
              <button
                type="button"
                onClick={() => setShowPassword((v) => !v)}
                aria-pressed={showPassword}
                aria-label={showPassword ? 'Hide password' : 'Show password'}
                className="absolute inset-y-0 right-0 min-w-11 px-3 text-sm font-semibold text-brand-blue"
              >
                {showPassword ? 'Hide' : 'Show'}
              </button>
            </div>
            {fieldErrors.password && (
              <p id="password-err" className="mt-1 text-xs font-medium text-brand-risk-text">
                {fieldErrors.password}
              </p>
            )}
          </div>

          {error && <Alert tone="error">{error}</Alert>}

          <div className="-mt-1 text-right">
            <button type="button" onClick={() => setForgotOpen(true)} className="min-h-11 text-sm font-semibold text-brand-blue">
              Forgot password?
            </button>
          </div>

          <button type="submit" disabled={submitting} className="btn-primary w-full">
            {submitting && <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/40 border-t-white" aria-hidden="true" />}
            {submitting ? 'Signing in…' : 'Sign in'}
          </button>
        </form>

        <p className="mt-6 text-center text-xs text-muted">
          Lost access to your account? Contact your entity owner or admin to recover access — self sign-up is not available.
        </p>
      </main>
    </div>
  )
}

// Forgot password: always shows the same neutral acknowledgement, whether or
// not the email has an account (and even when Supabase refuses the request),
// so the form can't be used to discover who has a login.
function ForgotPassword({ initialEmail, onBack }: { initialEmail: string; onBack: () => void }) {
  const [email, setEmail] = useState(initialEmail)
  const [fieldError, setFieldError] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const [sent, setSent] = useState(false)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!EMAIL_RE.test(email.trim())) return setFieldError('Enter your work email address.')
    setFieldError(null)
    setSending(true)
    try {
      await supabase.auth.resetPasswordForEmail(email.trim().toLowerCase(), {
        redirectTo: `${window.location.origin}/set-password`,
      })
    } catch {
      /* deliberately ignored — the response is the same either way */
    }
    setSending(false)
    setSent(true)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-alt px-4 py-8">
      <main className="w-full max-w-sm rounded-[14px] border border-border bg-surface p-6 shadow-card sm:p-8">
        <div className="mb-6 text-center">
          <h1 className="text-xl font-semibold text-ink">Reset your password</h1>
          <p className="mt-1 text-sm text-muted">We'll email you a link to choose a new password.</p>
        </div>
        {sent ? (
          <div className="space-y-4">
            <Alert tone="info">{RESET_REQUESTED_MESSAGE}</Alert>
            <button type="button" onClick={onBack} className="btn-secondary w-full">
              Back to sign in
            </button>
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-4" noValidate>
            <div>
              <label htmlFor="reset-email" className="label">
                Work email
              </label>
              <input
                id="reset-email"
                type="email"
                inputMode="email"
                autoComplete="username"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                aria-invalid={Boolean(fieldError)}
                aria-describedby={fieldError ? 'reset-email-err' : undefined}
                className="input"
              />
              {fieldError && (
                <p id="reset-email-err" className="mt-1 text-xs font-medium text-brand-risk-text">
                  {fieldError}
                </p>
              )}
            </div>
            <button type="submit" disabled={sending} className="btn-primary w-full">
              {sending ? 'Sending…' : 'Send reset link'}
            </button>
            <button type="button" onClick={onBack} className="btn-secondary w-full">
              Back to sign in
            </button>
          </form>
        )}
      </main>
    </div>
  )
}
