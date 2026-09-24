import { lazy, Suspense, type ReactNode } from 'react'
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider, useAuth } from './auth/AuthContext'
import { ProtectedRoute } from './auth/ProtectedRoute'
import { AppShell } from './components/AppShell'
import { AccessDenied, Skeleton } from './components/ui'
import { EnvironmentBanner } from './components/EnvironmentBanner'
import { canAccessRoute } from './lib/nav'
import SignIn from './pages/SignIn'
import NoAssignment from './pages/NoAssignment'

// Every authenticated page is its own chunk so the entry bundle only carries
// the shell, auth and router.
const Dashboard = lazy(() => import('./pages/Dashboard'))
const StaffHome = lazy(() => import('./pages/StaffHome'))
const EmployeeDirectory = lazy(() => import('./pages/EmployeeDirectory'))
const EmployeeProfile = lazy(() => import('./pages/EmployeeProfile'))
const Documents = lazy(() => import('./pages/Documents'))
const Payroll = lazy(() => import('./pages/Payroll'))
const Recruiting = lazy(() => import('./pages/Recruiting'))
const MyInterviews = lazy(() => import('./pages/MyInterviews'))
const MyProfile = lazy(() => import('./pages/MyProfile'))
const Schedules = lazy(() => import('./pages/Schedules'))
const Leave = lazy(() => import('./pages/Leave'))
const Reports = lazy(() => import('./pages/Reports'))
const Clock = lazy(() => import('./pages/Clock'))
const Attendance = lazy(() => import('./pages/Attendance'))
const Workflows = lazy(() => import('./pages/Workflows'))
const Admin = lazy(() => import('./pages/Admin'))
const Notifications = lazy(() => import('./pages/Notifications'))

/**
 * Role gate for deep links. The page component (and therefore its data
 * queries) never mounts for an unauthorised role — the user just sees a
 * generic access message. RLS/RPC checks remain the real security boundary.
 */
function RoleGate({ route, children }: { route: string; children: ReactNode }) {
  const { profile } = useAuth()
  if (!canAccessRoute(profile?.role, route)) return <AccessDenied />
  return <>{children}</>
}

/** Staff get a personal home; everyone else the entity dashboard. */
function Home() {
  const { profile } = useAuth()
  return profile?.role === 'staff' ? <StaffHome /> : <Dashboard />
}

function Shell({ route, children }: { route: string; children: ReactNode }) {
  return (
    <ProtectedRoute>
      <AppShell>
        <RoleGate route={route}>
          <Suspense fallback={<Skeleton rows={4} className="h-20" />}>{children}</Suspense>
        </RoleGate>
      </AppShell>
    </ProtectedRoute>
  )
}

const ROUTES: { path: string; element: ReactNode }[] = [
  { path: '/', element: <Home /> },
  { path: '/employees', element: <EmployeeDirectory /> },
  { path: '/employees/:id', element: <EmployeeProfile /> },
  { path: '/me', element: <MyProfile /> },
  // get_my_interviews()/get_interview_detail() resolve identity from
  // auth.uid() and RLS scopes every table, so direct navigation is safe.
  { path: '/my-interviews', element: <MyInterviews /> },
  { path: '/documents', element: <Documents /> },
  { path: '/recruiting', element: <Recruiting /> },
  { path: '/schedules', element: <Schedules /> },
  { path: '/clock', element: <Clock /> },
  { path: '/attendance', element: <Attendance /> },
  { path: '/leave', element: <Leave /> },
  { path: '/payroll', element: <Payroll /> },
  { path: '/reports', element: <Reports /> },
  { path: '/workflows', element: <Workflows /> },
  { path: '/admin', element: <Admin /> },
  { path: '/notifications', element: <Notifications /> },
]

function App() {
  return (
    <BrowserRouter>
      {/* Renders nothing unless VITE_APP_ENV === 'uat'. */}
      <EnvironmentBanner />
      <AuthProvider>
        <Routes>
          <Route path="/sign-in" element={<SignIn />} />
          <Route path="/no-assignment" element={<NoAssignment />} />
          {ROUTES.map((r) => (
            <Route key={r.path} path={r.path} element={<Shell route={r.path}>{r.element}</Shell>} />
          ))}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  )
}

export default App
