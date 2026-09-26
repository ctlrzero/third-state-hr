import type { UserRole } from '../types/db'

// Single source of truth for which roles may see which destination. Hidden
// nav is a UX convenience only — RLS/RPC checks are the real boundary — but
// App.tsx also uses ROUTE_ROLES to render a generic access message on deep
// links so an unauthorised page never even mounts (and so never fires its
// data queries).

export type NavIcon =
  | 'home'
  | 'people'
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

export interface NavItem {
  label: string
  to: string
  icon: NavIcon
  roles: UserRole[]
  requires?: 'interviewAssignment'
}

const ALL: UserRole[] = ['owner', 'entity_admin', 'location_manager', 'staff']
const ADMINS: UserRole[] = ['owner', 'entity_admin']
const MANAGERS: UserRole[] = ['owner', 'entity_admin', 'location_manager']

export const ROUTE_ROLES: Record<string, UserRole[]> = {
  '/': ALL,
  '/employees': MANAGERS,
  '/employees/:id': MANAGERS,
  '/me': ALL,
  '/my-interviews': ALL,
  '/documents': ALL,
  // Recruiting redirects staff to /my-interviews itself (see Recruiting.tsx).
  '/recruiting': ALL,
  '/schedules': ALL,
  '/clock': ALL,
  '/attendance': MANAGERS,
  '/leave': ALL,
  // Staff see their own payslips (or the workspace if granted payroll
  // access); location managers get the hours/tips inputs sheet — the
  // server never returns pay amounts to them.
  '/payroll': ['owner', 'entity_admin', 'location_manager', 'staff'],
  '/reports': MANAGERS,
  '/workflows': ADMINS,
  '/admin': ADMINS,
  '/notifications': ALL,
}

export function canAccessRoute(role: UserRole | null | undefined, route: string): boolean {
  if (!role) return false
  const allowed = ROUTE_ROLES[route]
  return allowed ? allowed.includes(role) : false
}

const STAFF_NAV: NavItem[] = [
  { label: 'Home', to: '/', icon: 'home', roles: ['staff'] },
  { label: 'Schedule', to: '/schedules', icon: 'schedule', roles: ['staff'] },
  { label: 'Clock', to: '/clock', icon: 'clock', roles: ['staff'] },
  { label: 'Leave', to: '/leave', icon: 'leave', roles: ['staff'] },
  { label: 'Documents', to: '/documents', icon: 'documents', roles: ['staff'] },
  { label: 'Payslips', to: '/payroll', icon: 'payroll', roles: ['staff'] },
  { label: 'Profile', to: '/me', icon: 'profile', roles: ['staff'] },
  { label: 'My Interviews', to: '/my-interviews', icon: 'interviews', roles: ['staff'], requires: 'interviewAssignment' },
  { label: 'Notifications', to: '/notifications', icon: 'notifications', roles: ['staff'] },
]

const MANAGEMENT_NAV: NavItem[] = [
  { label: 'Home', to: '/', icon: 'home', roles: MANAGERS },
  { label: 'People', to: '/employees', icon: 'people', roles: MANAGERS },
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
]

export interface NavContext {
  hasInterviewAssignments?: boolean
}

/** Full ordered nav for a role (desktop sidebar). */
export function navForRole(role: UserRole | null | undefined, ctx: NavContext = {}): NavItem[] {
  if (!role) return []
  const source = role === 'staff' ? STAFF_NAV : MANAGEMENT_NAV
  return source.filter((item) => {
    if (!item.roles.includes(role)) return false
    if (item.requires === 'interviewAssignment' && !ctx.hasInterviewAssignments) return false
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
  if (role === 'staff') {
    const primaryPaths = ['/', '/schedules', '/clock', '/leave']
    return {
      primary: primaryPaths.map((p) => items.find((i) => i.to === p)!).filter(Boolean),
      more: items.filter((i) => !primaryPaths.includes(i.to)),
    }
  }
  return { primary: items.slice(0, 4), more: items.slice(4) }
}
