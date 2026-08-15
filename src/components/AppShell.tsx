import { useMemo, useState, type ReactNode } from 'react'
import { NavLink } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { NotificationBell } from './NotificationBell'
import type { UserRole } from '../types/db'

interface NavItem {
  label: string
  to: string
  roles: UserRole[]
  icon: ReactNode
  /** Extra gate beyond role — e.g. "My Interviews" only when assigned. */
  requires?: 'interviewAssignment'
}

function Icon({ d }: { d: string }) {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth={1.75}>
      <path d={d} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

// Section 3 (Information architecture): each destination is annotated with the
// roles authorised to see it. Payroll must never render for location_manager.
const NAV_ITEMS: NavItem[] = [
  {
    label: 'Home',
    to: '/',
    roles: ['owner', 'entity_admin', 'location_manager', 'staff'],
    icon: <Icon d="M3 11.5 12 4l9 7.5M5 10v9.5a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V10" />,
  },
  {
    label: 'People',
    to: '/employees',
    roles: ['owner', 'entity_admin', 'location_manager'],
    icon: <Icon d="M16 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9.5 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm7 9v-1a3.5 3.5 0 0 0-2.5-3.36M14.5 3.13a3.5 3.5 0 0 1 0 6.75" />,
  },
  {
    label: 'My Profile',
    to: '/me',
    roles: ['staff'],
    icon: <Icon d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8a7 7 0 0 1 14 0" />,
  },
  {
    label: 'My Interviews',
    to: '/my-interviews',
    // Employee-facing only — never the administrative Recruiting nav, and
    // only shown at all once has_interview_assignments() (resolved from
    // auth.uid()) says there's at least one assignment. This is a
    // convenience for discoverability, not the access control — RLS and the
    // get_my_interviews()/get_interview_detail() RPCs enforce the real
    // boundary regardless of whether this link is visible.
    roles: ['staff'],
    requires: 'interviewAssignment',
    icon: <Icon d="M9 11l3 3L22 4M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />,
  },
  {
    label: 'Documents',
    to: '/documents',
    roles: ['owner', 'entity_admin', 'location_manager', 'staff'],
    icon: <Icon d="M8 3h6l4 4v13a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Zm6 0v4h4" />,
  },
  {
    label: 'Recruiting',
    to: '/recruiting',
    // Matches candidates/job_requisitions RLS scope (owner/entity_admin any,
    // location_manager scoped to their own location); offers are
    // owner/entity_admin only within the page itself.
    roles: ['owner', 'entity_admin', 'location_manager'],
    icon: <Icon d="M16 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9.5 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM19 8v6M22 11h-6" />,
  },
  {
    label: 'Schedules',
    to: '/schedules',
    roles: ['owner', 'entity_admin', 'location_manager', 'staff'],
    icon: <Icon d="M4 5h16M4 5v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1V5M8 3v4M16 3v4M4 10h16" />,
  },
  {
    label: 'Leave',
    to: '/leave',
    roles: ['owner', 'entity_admin', 'location_manager', 'staff'],
    icon: <Icon d="M12 3v6l4 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z" />,
  },
  {
    label: 'Payroll',
    to: '/payroll',
    roles: ['owner', 'entity_admin', 'staff'],
    icon: <Icon d="M4 6h16v12H4zM4 10h16M8 15h4" />,
  },
  {
    label: 'Reports',
    to: '/reports',
    roles: ['owner', 'entity_admin', 'location_manager'],
    icon: <Icon d="M4 19V9m6 10V4m6 15v-7" />,
  },
]

const ROLE_LABEL: Record<UserRole, string> = {
  owner: 'Owner / Admin',
  entity_admin: 'Owner / Admin',
  location_manager: 'Café Manager',
  staff: 'Employee',
}

export function AppShell({ children }: { children: ReactNode }) {
  const { profile, entities, activeEntityId, setActiveEntityId, hasInterviewAssignments, signOut } = useAuth()
  const [mobileMoreOpen, setMobileMoreOpen] = useState(false)

  const items = useMemo(
    () =>
      NAV_ITEMS.filter((item) => {
        if (!profile || !item.roles.includes(profile.role)) return false
        if (item.requires === 'interviewAssignment' && !hasInterviewAssignments) return false
        return true
      }),
    [profile, hasInterviewAssignments]
  )

  const activeEntity = entities.find((e) => e.id === activeEntityId)
  const canSwitchEntity = profile?.role === 'owner' && entities.length > 1

  // Employee mobile portal uses exactly 5 bottom destinations per section 7 of the spec.
  const mobilePrimary = profile?.role === 'staff' ? items.slice(0, 4) : items.slice(0, 4)
  const mobileOverflow = items.slice(4)

  return (
    <div className="min-h-screen bg-surface-alt">
      <div className="mx-auto flex min-h-screen max-w-[1440px]">
        {/* Desktop sidebar */}
        <aside className="hidden w-[232px] shrink-0 flex-col border-r border-border bg-surface px-4 pb-[18px] pt-6 md:flex">
          <div className="mb-6 flex items-center gap-3 px-1">
            <div
              className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[11px] text-[11px] font-extrabold text-white shadow-[0_8px_18px_rgba(37,99,235,0.22)]"
              style={{ backgroundImage: 'linear-gradient(145deg, #1f62eb, #164dc2)' }}
            >
              TS
            </div>
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-ink">Third State HR</p>
              <p className="truncate text-[11px] text-muted">Multi-entity people ops</p>
            </div>
          </div>
          <nav className="flex-1 space-y-1">
            {items.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                end={item.to === '/'}
                className={({ isActive }) =>
                  `flex items-center gap-3 rounded-[11px] px-3.5 py-2.5 text-[13px] font-semibold transition ${
                    isActive ? 'text-white shadow-[0_8px_20px_rgba(37,99,235,0.22)]' : 'text-muted-strong hover:bg-surface-alt'
                  }`
                }
                style={({ isActive }) =>
                  isActive ? { backgroundImage: 'linear-gradient(135deg, #2d6cf6, #1f59dc)' } : undefined
                }
              >
                {item.icon}
                {item.label}
              </NavLink>
            ))}
          </nav>
          <div className="border-t border-border px-1 pt-4 text-[11px] text-muted">
            {profile && ROLE_LABEL[profile.role]}
          </div>
        </aside>

        <div className="flex min-w-0 flex-1 flex-col">
          {/* Context bar */}
          <header className="sticky top-0 z-10 flex items-center justify-between gap-3 border-b border-border bg-surface px-4 py-3 md:px-6">
            <div className="flex items-center gap-3">
              {canSwitchEntity ? (
                <select
                  value={activeEntityId ?? ''}
                  onChange={(e) => setActiveEntityId(e.target.value)}
                  aria-label="Active entity"
                  className="rounded-lg border border-border bg-surface px-3 py-1.5 text-sm font-medium text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                >
                  {entities.map((entity) => (
                    <option key={entity.id} value={entity.id}>
                      {entity.name}
                    </option>
                  ))}
                </select>
              ) : (
                <span className="rounded-lg bg-surface-alt px-3 py-1.5 text-sm font-medium text-ink">
                  {activeEntity?.name ?? 'No entity assigned'}
                </span>
              )}
            </div>

            <div className="flex items-center gap-3">
              <NotificationBell />
              <span className="hidden text-sm text-muted sm:inline">
                {profile?.full_name ?? 'Signed in'}
              </span>
              <button
                onClick={() => signOut()}
                className="rounded-lg border border-border px-3 py-1.5 text-sm text-muted transition hover:border-brand-risk/40 hover:text-brand-risk"
              >
                Sign out
              </button>
            </div>
          </header>

          <main className="flex-1 px-4 pb-24 pt-5 md:px-6 md:pb-8">{children}</main>
        </div>
      </div>

      {/* Mobile bottom navigation */}
      <nav className="fixed inset-x-0 bottom-0 z-20 flex border-t border-border bg-surface md:hidden">
        {mobilePrimary.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.to === '/'}
            className={({ isActive }) =>
              `flex flex-1 flex-col items-center gap-0.5 py-2.5 text-[11px] ${
                isActive ? 'text-brand-blue' : 'text-muted'
              }`
            }
          >
            {item.icon}
            {item.label}
          </NavLink>
        ))}
        {mobileOverflow.length > 0 && (
          <button
            onClick={() => setMobileMoreOpen(true)}
            className="flex flex-1 flex-col items-center gap-0.5 py-2.5 text-[11px] text-muted"
          >
            <Icon d="M4 6h16M4 12h16M4 18h16" />
            More
          </button>
        )}
      </nav>

      {mobileMoreOpen && (
        <div className="fixed inset-0 z-30 flex items-end bg-ink/40 md:hidden" onClick={() => setMobileMoreOpen(false)}>
          <div
            className="w-full rounded-t-2xl bg-surface p-4"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="mb-3 h-1 w-10 rounded-full bg-border mx-auto" />
            <div className="space-y-1">
              {mobileOverflow.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  onClick={() => setMobileMoreOpen(false)}
                  className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm text-ink hover:bg-surface-alt"
                >
                  {item.icon}
                  {item.label}
                </NavLink>
              ))}
              <button
                onClick={() => signOut()}
                className="flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-left text-sm text-brand-risk hover:bg-brand-risk/5"
              >
                Sign out
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
