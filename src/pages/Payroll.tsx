import { useEffect, useState } from 'react'
import { useAuth } from '../auth/AuthContext'
import MyPayslips from './MyPayslips'
import { Skeleton } from '../components/ui'
import { canPayroll } from '../lib/api/payroll'
import PayrollWorkspace from './payroll/Workspace'
import HoursSheet from './payroll/HoursSheet'

// Payroll entry point. What a user sees is decided by the server's payroll
// permission (payroll_can), not the role alone:
//   owner / entity admin / payroll admin / accountant  → monthly workspace
//   branch manager                                     → hours & tips inputs
//   everyone else                                       → own payslips
export default function Payroll() {
  const { profile, activeEntityId } = useAuth()
  const [mode, setMode] = useState<'loading' | 'workspace' | 'inputs' | 'self'>('loading')

  useEffect(() => {
    let alive = true
    async function decide() {
      if (!activeEntityId) {
        setMode('self')
        return
      }
      const pay = await canPayroll(activeEntityId, 'view_pay')
      if (!alive) return
      if (pay.data) return setMode('workspace')
      const inputs = await canPayroll(activeEntityId, 'inputs')
      if (!alive) return
      setMode(inputs.data ? 'inputs' : 'self')
    }
    setMode('loading')
    decide()
    return () => {
      alive = false
    }
  }, [activeEntityId, profile?.role])

  if (mode === 'loading') return <Skeleton rows={4} className="h-16" />
  if (mode === 'workspace' && activeEntityId) return <PayrollWorkspace entityId={activeEntityId} />
  if (mode === 'inputs' && activeEntityId) return <HoursSheet entityId={activeEntityId} />
  return <MyPayslips />
}
