import { useEffect, useState } from 'react'
import { useAuth } from '../auth/AuthContext'
import { Skeleton } from '../components/ui'
import { canPayroll } from '../lib/api/payroll'
import OnboardingDashboard from './onboarding/Dashboard'
import MyOnboarding from './onboarding/MyOnboarding'
import { isSelfServiceRole } from '../types/db'

// Onboarding entry point:
//   owner / entity admin / branch manager      → dashboard (scope enforced server-side)
//   staff with payroll-approver permission     → dashboard, pay & bank reviews only
//   everyone else (the new starter)            → their own onboarding portal
export default function Onboarding() {
  const { profile, activeEntityId } = useAuth()
  const [mode, setMode] = useState<'loading' | 'manage' | 'payroll' | 'self'>('loading')

  useEffect(() => {
    let alive = true
    if (profile?.role && !isSelfServiceRole(profile.role)) {
      setMode('manage')
      return
    }
    if (!activeEntityId) {
      setMode('self')
      return
    }
    canPayroll(activeEntityId, 'approve').then((r) => alive && setMode(r.data ? 'payroll' : 'self'))
    return () => {
      alive = false
    }
  }, [profile?.role, activeEntityId])

  if (mode === 'loading') return <Skeleton rows={4} className="h-16" />
  if (mode === 'self') return <MyOnboarding />
  return <OnboardingDashboard payrollOnly={mode === 'payroll'} />
}
