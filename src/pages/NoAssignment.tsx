import { useAuth } from '../auth/AuthContext'

// UX-01 "no assignment" state: the account authenticated successfully but has
// no profile row, or no entity/location assignment yet — never a technical
// error, never a hint at what other accounts might exist.
export default function NoAssignment() {
  const { signOut } = useAuth()

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-alt px-4">
      <div className="max-w-sm rounded-2xl border border-border bg-surface p-8 text-center shadow-sm">
        <h1 className="text-lg font-semibold text-ink">No workspace assigned yet</h1>
        <p className="mt-2 text-sm text-muted">
          Your account signed in successfully, but it isn't linked to an entity or branch yet. Ask
          your owner or admin to complete your access setup, then try again.
        </p>
        <button
          onClick={() => signOut()}
          className="mt-6 rounded-lg border border-border px-4 py-2 text-sm text-ink hover:bg-surface-alt"
        >
          Sign out
        </button>
      </div>
    </div>
  )
}
