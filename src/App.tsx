import type { ReactNode } from 'react'
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider } from './auth/AuthContext'
import { ProtectedRoute } from './auth/ProtectedRoute'
import { AppShell } from './components/AppShell'
import SignIn from './pages/SignIn'
import NoAssignment from './pages/NoAssignment'
import Dashboard from './pages/Dashboard'
import EmployeeDirectory from './pages/EmployeeDirectory'
import EmployeeProfile from './pages/EmployeeProfile'
import Documents from './pages/Documents'
import Payroll from './pages/Payroll'
import Recruiting from './pages/Recruiting'
import MyInterviews from './pages/MyInterviews'
import MyProfile from './pages/MyProfile'
import Schedules from './pages/Schedules'
import Leave from './pages/Leave'
import Reports from './pages/Reports'

function Shell({ children }: { children: ReactNode }) {
  return (
    <ProtectedRoute>
      <AppShell>{children}</AppShell>
    </ProtectedRoute>
  )
}

function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/sign-in" element={<SignIn />} />
          <Route path="/no-assignment" element={<NoAssignment />} />

          <Route path="/" element={<Shell><Dashboard /></Shell>} />
          <Route path="/employees" element={<Shell><EmployeeDirectory /></Shell>} />
          <Route path="/employees/:id" element={<Shell><EmployeeProfile /></Shell>} />
          <Route path="/me" element={<Shell><MyProfile /></Shell>} />
          {/* Direct navigation here (even without the nav link visible) is
              still safe: get_my_interviews()/get_interview_detail() resolve
              identity from auth.uid() and RLS scopes every underlying table,
              so an unassigned employee just sees an empty list, not an error
              that leaks the existence of other interviews. */}
          <Route path="/my-interviews" element={<Shell><MyInterviews /></Shell>} />
          <Route path="/documents" element={<Shell><Documents /></Shell>} />
          <Route path="/recruiting" element={<Shell><Recruiting /></Shell>} />
          <Route path="/schedules" element={<Shell><Schedules /></Shell>} />
          <Route path="/leave" element={<Shell><Leave /></Shell>} />
          <Route path="/payroll" element={<Shell><Payroll /></Shell>} />
          <Route path="/reports" element={<Shell><Reports /></Shell>} />

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  )
}

export default App
