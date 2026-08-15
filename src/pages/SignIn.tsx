import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'

// UX-01 Sign-in, identity and entity selection.
// No sensitive data renders before a successful authentication result; the
// entity switcher itself lives in the app shell context bar once signed in,
// not on this screen, so a failed/partial login can never leak scope.
export default function SignIn() {
  const { status, signInWithPassword } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (status === 'ready') {
    return <Navigate to="/" replace />
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setSubmitting(true)
    const { error } = await signInWithPassword(email.trim(), password)
    setSubmitting(false)

    if (error) {
      // Supabase returns "Invalid login credentials" for both unknown email and
      // wrong password — do not disclose which, and never mention employee lookup.
      setError('Invalid email or password. Please try again.')
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-alt px-4">
      <div className="w-full max-w-sm rounded-[14px] border border-border bg-surface p-8 shadow-card">
        <div className="mb-8 text-center">
          <div
            className="mx-auto mb-3 flex h-11 w-11 items-center justify-center rounded-[11px] text-[11px] font-extrabold text-white shadow-[0_8px_18px_rgba(37,99,235,0.22)]"
            style={{ backgroundImage: 'linear-gradient(145deg, #1f62eb, #164dc2)' }}
          >
            TS
          </div>
          <h1 className="text-xl font-semibold text-ink">Third State Café HR</h1>
          <p className="mt-1 text-sm text-muted">Sign in to your workspace</p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4" noValidate>
          <div>
            <label htmlFor="email" className="mb-1 block text-sm font-medium text-ink">
              Work email
            </label>
            <input
              id="email"
              type="email"
              autoComplete="username"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2.5 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              placeholder="you@thirdstate.ae"
            />
          </div>

          <div>
            <div className="mb-1 flex items-center justify-between">
              <label htmlFor="password" className="block text-sm font-medium text-ink">
                Password
              </label>
            </div>
            <input
              id="password"
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-lg border border-border px-3 py-2.5 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
              placeholder="••••••••"
            />
          </div>

          {error && (
            <p role="alert" className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">
              {error}
            </p>
          )}

          <button
            type="submit"
            disabled={submitting}
            className="flex w-full items-center justify-center gap-2 rounded-lg bg-brand-blue px-4 py-2.5 text-sm font-medium text-white transition hover:bg-brand-blue-dark disabled:cursor-not-allowed disabled:opacity-60"
          >
            {submitting && (
              <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/40 border-t-white" />
            )}
            {submitting ? 'Signing in…' : 'Sign in'}
          </button>
        </form>

        <p className="mt-6 text-center text-xs text-muted">
          Lost access to your account? Contact your entity owner or admin to recover access — self
          sign-up is not available.
        </p>
      </div>
    </div>
  )
}
