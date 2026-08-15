import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from './AuthContext'

export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { status } = useAuth()

  if (status === 'loading') {
    return (
      <div className="flex min-h-screen items-center justify-center bg-surface-alt">
        <div className="flex items-center gap-3 text-muted">
          <span className="h-4 w-4 animate-spin rounded-full border-2 border-border border-t-brand-blue" />
          Checking your session…
        </div>
      </div>
    )
  }

  if (status === 'signed-out') {
    return <Navigate to="/sign-in" replace />
  }

  if (status === 'no-assignment') {
    return <Navigate to="/no-assignment" replace />
  }

  return <>{children}</>
}
