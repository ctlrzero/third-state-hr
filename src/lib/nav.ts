import { isSelfServiceRole, type UserRole } from '../types/db'

// Single source of truth for which roles may see which destination. Hidden
// nav is a UX convenience only — RLS/RPC checks are the real boundary — but
// App.tsx also uses ROUTE_ROLES to render a generic access message on deep
// links so an unauthorised page never even mounts (and so never fires its
// data queries).

export type NavIcon =
  | 'home'
  | 'people'
  | 'onboarding'
  | 'offboarding'
  | 'profile'
  | 'interviews'
  | 'documents'
  | 'recruiting'
  | 'schedule'
  | 'clock'
  | 'attendance'
  | 'leave'
  | 'payroll'
  | 'reports'
  | 'workflows'
  | 'admin'
  | 'notifications'
  | 'today'
  | 'help'

export interface NavItem {
  label: string
  to: string
  icon: NavIcon
  roles: UserRole[]
  requires?: 'interviewAssignment' | 'onboarding' | 'payrollAccess'
}

const ALL: UserRole[] = ['owner', 'entity_admin', 'location_manager', 'shift_supervisor', 'staff']
// Employee self-service logins. A shift supervisor is staff plus the Today board and attendance for their branch.
const SELF: UserRole[] = ['shift_supervisor', 'staff']
const ADMINS: UserRole[] = ['owner', 'entity_admin']
const MANAGERS: UserRole[] = ['owner', 'entity_admin', 'location_manager']

export const ROUTE_ROLES: Record<string, UserRole[]> = {
  '/': ALL,
  '/today': [...MANAGERS, 'shift_supervisor'],
  '/employees': MANAGERS,
  '/employees/:id': MANAGERS,
  // Managers see the dashboard; staff see their own onboarding (or pay/bank
  // reviews with payroll permission). Every RPC re-checks scope.
  '/onboarding': ALL,
  // Managers see the branch/company checklist; staff with payroll access
  // (e.g. a payroll-admin preset) see the settlement side. The page itself
  // checks payroll_can for a staff caller.
  '/offboarding': ['owner', 'entity_admin', 'location_manager', 'shift_supervisor', 'staff'],
  '/me': ALL,
  '/my-interviews': ALL,
  '/documents': ALL,
  // Recruiting redirects staff to /my-interviews itself (see Recruiting.tsx).
  '/recruiting': ALL,
  '/schedules': ALL,
  '/clock': ALL,
  // Supervisors see exceptions and clock corrections only (no payable time).
  '/attendance': [...MANAGERS, 'shift_supervisor'],
  '/leave': ALL,
  // Staff see their own payslips (or the workspace if granted payroll
  // access); location managers get the hours/tips inputs sheet — the
  // server never returns pay amounts to them.
  '/payroll': ['owner', 'entity_admin', 'location_manager', 'shift_supervisor', 'staff'],
  '/reports': MANAGERS,
  '/workflows': ADMINS,
  '/admin': ADMINS,
  '/notifications': ALL,
  // Help & Guides: every signed-in role. The server filters articles by audience; the editor is admin-only.
  '/help': ALL,
  '/help/:slug': ALL,
  '/help/admin': ADMINS,
}

export function canAccessRoute(role: UserRole | null | undefined, route: string): boolean {
  if (!role) return false
  const allowed = ROUTE_ROLES[route]
  return allowed ? allowed.includes(role) : false
}

const STAFF_NAV: NavItem[] = [
  { label: 'Home', to: '/', icon: 'home', roles: SELF },
  { label: 'Onboarding', to: '/onboarding', icon: 'onboarding', roles: SELF, requires: 'onboarding' },
  { label: 'Today', to: '/today', icon: 'today', roles: ['shift_supervisor'] },
  { label: 'Schedule', to: '/schedules', icon: 'schedule', roles: SELF },
  { label: 'Clock', to: '/clock', icon: 'clock', roles: SELF },
  { label: 'Leave', to: '/leave', icon: 'leave', roles: SELF },
  { label: 'Documents', to: '/documents', icon: 'documents', roles: SELF },
  { label: 'Attendance', to: '/attendance', icon: 'attendance', roles: ['shift_supervisor'] },
  { label: 'Payslips', to: '/payroll', icon: 'payroll', roles: SELF },
  // Only for a payroll-admin preset staff login (payroll_can approve); the page
  // itself re-checks payroll_can.
  { label: 'Offboarding', to: '/offboarding', icon: 'offboarding', roles: SELF, requires: 'payrollAccess' },
  { label: 'Profile', to: '/me', icon: 'profile', roles: SELF },
  { label: 'My Interviews', to: '/my-interviews', icon: 'interviews', roles: SELF, requires: 'interviewAssignment' },
  { label: 'Notifications', to: '/notifications', icon: 'notifications', roles: SELF },
  { label: 'Help & Guides', to: '/help', icon: 'help', roles: SELF },
]

const MANAGEMENT_NAV: NavItem[] = [
  { label: 'Home', to: '/', icon: 'home', roles: MANAGERS },
  { label: 'Today', to: '/today', icon: 'today', roles: MANAGERS },
  { label: 'People', to: '/employees', icon: 'people', roles: MANAGERS },
  { label: 'Onboarding', to: '/onboarding', icon: 'onboarding', roles: MANAGERS },
  { label: 'Offboarding', to: '/offboarding', icon: 'offboarding', roles: MANAGERS },
  { label: 'Schedules', to: '/schedules', icon: 'schedule', roles: MANAGERS },
  { label: 'Attendance', to: '/attendance', icon: 'attendance', roles: MANAGERS },
  { label: 'Leave', to: '/leave', icon: 'leave', roles: MANAGERS },
  { label: 'Documents', to: '/documents', icon: 'documents', roles: MANAGERS },
  { label: 'Recruiting', to: '/recruiting', icon: 'recruiting', roles: MANAGERS },
  { label: 'Payroll', to: '/payroll', icon: 'payroll', roles: ADMINS },
  { label: 'Payroll inputs', to: '/payroll', icon: 'payroll', roles: ['location_manager'] },
  { label: 'Reports', to: '/reports', icon: 'reports', roles: MANAGERS },
  { label: 'Workflows', to: '/workflows', icon: 'workflows', roles: ADMINS },
  { label: 'Admin', to: '/admin', icon: 'admin', roles: ADMINS },
  // The owner has no employee record, so no personal clock.
  { label: 'My clock', to: '/clock', icon: 'clock', roles: ['entity_admin', 'location_manager'] },
  { label: 'My Interviews', to: '/my-interviews', icon: 'interviews', roles: MANAGERS, requires: 'interviewAssignment' },
  { label: 'Notifications', to: '/notifications', icon: 'notifications', roles: MANAGERS },
  { label: 'Help & Guides', to: '/help', icon: 'help', roles: MANAGERS },
]

export interface NavContext {
  hasInterviewAssignments?: boolean
  hasOnboarding?: boolean
  hasPayrollAccess?: boolean
}

/** Full ordered nav for a role (desktop sidebar). */
export function navForRole(role: UserRole | null | undefined, ctx: NavContext = {}): NavItem[] {
  if (!role) return []
  const source = isSelfServiceRole(role) ? STAFF_NAV : MANAGEMENT_NAV
  return source.filter((item) => {
    if (!item.roles.includes(role)) return false
    if (item.requires === 'interviewAssignment' && !ctx.hasInterviewAssignments) return false
    if (item.requires === 'onboarding' && !ctx.hasOnboarding) return false
    if (item.requires === 'payrollAccess' && !ctx.hasPayrollAccess) return false
    return true
  })
}

/**
 * Mobile bottom bar: exactly four primary destinations plus "More". Staff get
 * Home, Schedule, Clock, Leave (spec section 7); everything else goes into
 * the More sheet (which also holds Sign out).
 */
export function mobileNavForRole(
  role: UserRole | null | undefined,
  ctx: NavContext = {}
): { primary: NavItem[]; more: NavItem[] } {
  const items = navForRole(role, ctx)
  if (isSelfServiceRole(role)) {
    // A new starter's onboarding replaces Clock in the bar until it is closed;
    // a supervisor's Today board replaces Leave.
    const primaryPaths = ctx.hasOnboarding
      ? ['/', '/onboarding', '/schedules', '/leave']
      : role === 'shift_supervisor'
        ? ['/', '/today', '/schedules', '/clock']
        : ['/', '/schedules', '/clock', '/leave']
    return {
      primary: primaryPaths.map((p) => items.find((i) => i.to === p)!).filter(Boolean),
      more: items.filter((i) => !primaryPaths.includes(i.to)),
    }
  }
  // Location managers get Today, Schedules, Leave, Attendance in the bar (Home
  // and People move to More); owners/entity admins keep Home, Today,
  // Schedules, People. Everything else lives in More on phones.
  const managerPrimary =
    role === 'location_manager' ? ['/today', '/schedules', '/leave', '/attendance'] : ['/', '/today', '/schedules', '/employees']
  const primary = managerPrimary.map((p) => items.find((i) => i.to === p)).filter((i): i is NavItem => Boolean(i))
  return { primary, more: items.filter((i) => !primary.includes(i)) }
}
