import { Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'

// UX-01 "no assignment" state: the account authenticated but is inactive
// (access revoked / employee inactivated) or isn't linked to an entity yet.
// Never a technical error, never a hint about other accounts.
export default function NoAssignment() {
  const { status, noAssignmentReason, signOut } = useAuth()

  if (status === 'signed-out') return <Navigate to="/sign-in" replace />
  if (status === 'ready') return <Navigate to="/" replace />

  const inactive = noAssignmentReason === 'inactive'

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-alt px-4">
      <main className="max-w-sm rounded-[14px] border border-border bg-surface p-8 text-center shadow-card">
        <h1 className="text-lg font-semibold text-ink">{inactive ? 'Your access is inactive' : 'No workspace assigned yet'}</h1>
        <p className="mt-2 text-sm text-muted">
          {inactive
            ? 'Your account has been deactivated, so you can no longer open Third State HR. If you think this is a mistake, contact your manager or Entity Admin.'
            : "Your account signed in successfully, but it isn't linked to an entity or branch yet. Ask your owner or admin to complete your access setup, then try again."}
        </p>
        <button onClick={() => signOut()} className="btn-secondary mt-6">
          Sign out
        </button>
      </main>
    </div>
  )
}
