import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { NotificationBell } from './NotificationBell'
import { mobileNavForRole, navForRole, type NavIcon } from '../lib/nav'
import type { UserRole } from '../types/db'

const ICON_PATHS: Record<NavIcon, string> = {
  home: 'M3 11.5 12 4l9 7.5M5 10v9.5a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V10',
  people:
    'M16 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9.5 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm7 9v-1a3.5 3.5 0 0 0-2.5-3.36M14.5 3.13a3.5 3.5 0 0 1 0 6.75',
  onboarding: 'M15 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm7.5 1 2 2 4-4',
  profile: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8a7 7 0 0 1 14 0',
  interviews: 'M9 11l3 3L22 4M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7',
  documents: 'M8 3h6l4 4v13a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Zm6 0v4h4',
  recruiting: 'M16 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9.5 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM19 8v6M22 11h-6',
  schedule: 'M4 5h16M4 5v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1V5M8 3v4M16 3v4M4 10h16',
  clock: 'M12 7v5l3 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z',
  attendance: 'M9 12l2 2 4-4M4 5h16v14H4zM8 3v4M16 3v4',
  leave: 'M5 21V4M5 4h11l-2 4 2 4H5',
  payroll: 'M4 6h16v12H4zM4 10h16M8 15h4',
  reports: 'M4 19V9m6 10V4m6 15v-7',
  workflows: 'M6 3v6m0 0a3 3 0 1 0 0 6 3 3 0 0 0 0-6Zm0 6v12M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm0 0v3a3 3 0 0 1-3 3H9',
  admin:
    'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.4-3a7.4 7.4 0 0 0-.1-1.2l2-1.6-2-3.4-2.4 1a7.3 7.3 0 0 0-2-1.2L14.5 3h-5l-.4 2.6a7.3 7.3 0 0 0-2 1.2l-2.4-1-2 3.4 2 1.6a7.4 7.4 0 0 0 0 2.4l-2 1.6 2 3.4 2.4-1a7.3 7.3 0 0 0 2 1.2l.4 2.6h5l.4-2.6a7.3 7.3 0 0 0 2-1.2l2.4 1 2-3.4-2-1.6c.1-.4.1-.8.1-1.2Z',
  notifications: 'M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9ZM13.73 21a2 2 0 0 1-3.46 0',
}

export function NavGlyph({ icon, className = 'h-5 w-5' }: { icon: NavIcon | 'more'; className?: string }) {
  const d = icon === 'more' ? 'M4 6h16M4 12h16M4 18h16' : ICON_PATHS[icon]
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth={1.75} aria-hidden="true">
      <path d={d} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

const ROLE_LABEL: Record<UserRole, string> = {
  owner: 'Owner',
  entity_admin: 'Entity Admin',
  location_manager: 'Location Manager',
  staff: 'Employee',
}

export function AppShell({ children }: { children: ReactNode }) {
  const { profile, entities, activeEntityId, setActiveEntityId, hasInterviewAssignments, hasOnboarding, signOut } = useAuth()
  const [moreOpen, setMoreOpen] = useState(false)
  const location = useLocation()
  const moreButtonRef = useRef<HTMLButtonElement>(null)
  const sheetRef = useRef<HTMLDivElement>(null)

  const ctx = { hasInterviewAssignments, hasOnboarding }
  const items = useMemo(() => navForRole(profile?.role, ctx), [profile?.role, hasInterviewAssignments, hasOnboarding]) // eslint-disable-line react-hooks/exhaustive-deps
  const mobile = useMemo(() => mobileNavForRole(profile?.role, ctx), [profile?.role, hasInterviewAssignments, hasOnboarding]) // eslint-disable-line react-hooks/exhaustive-deps

  // Close the More sheet on navigation; manage focus + Escape while open.
  useEffect(() => setMoreOpen(false), [location.pathname])
  useEffect(() => {
    if (!moreOpen) return
    sheetRef.current?.querySelector<HTMLElement>('a,button')?.focus()
    const opener = moreButtonRef.current
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') setMoreOpen(false)
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      opener?.focus()
    }
  }, [moreOpen])

  const activeEntity = entities.find((e) => e.id === activeEntityId)
  const canSwitchEntity = profile?.role === 'owner' && entities.length > 1
  const moreActive = mobile.more.some((i) => location.pathname.startsWith(i.to) && i.to !== '/')

  return (
    <div className="min-h-screen bg-surface-alt">
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-50 focus:rounded-lg focus:bg-surface focus:px-3 focus:py-2 focus:text-sm focus:font-semibold focus:text-brand-blue focus:shadow-card"
      >
        Skip to content
      </a>
      <div className="mx-auto flex min-h-screen max-w-[1440px]">
        {/* Desktop sidebar */}
        <aside className="hidden w-[232px] shrink-0 flex-col border-r border-border bg-surface px-4 pb-[18px] pt-6 md:flex">
          <div className="mb-6 flex items-center gap-3 px-1">
            <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[11px] bg-brand-primary text-[11px] font-extrabold text-white">
              TS
            </div>
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-ink">Third State HR</p>
              <p className="truncate text-[11px] text-muted">Multi-entity people ops</p>
            </div>
          </div>
          <nav aria-label="Main" className="flex-1 space-y-0.5 overflow-y-auto">
            {items.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                end={item.to === '/'}
                className={({ isActive }) =>
                  `flex min-h-11 items-center gap-3 rounded-[11px] px-3.5 text-[13px] font-semibold transition ${
                    isActive ? 'bg-brand-primary text-white' : 'text-muted-strong hover:bg-surface-alt'
                  }`
                }
              >
                <NavGlyph icon={item.icon} />
                {item.label}
              </NavLink>
            ))}
          </nav>
          <div className="border-t border-border px-1 pt-4 text-[11px] text-muted">{profile && ROLE_LABEL[profile.role]}</div>
        </aside>

        <div className="flex min-w-0 flex-1 flex-col">
          <header className="sticky top-0 z-10 flex items-center justify-between gap-3 border-b border-border bg-surface px-4 py-2.5 md:px-6">
            <div className="flex min-w-0 items-center gap-3">
              <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-[10px] bg-brand-primary text-[10px] font-extrabold text-white md:hidden">
                TS
              </div>
              {canSwitchEntity ? (
                <select
                  value={activeEntityId ?? ''}
                  onChange={(e) => setActiveEntityId(e.target.value)}
                  aria-label="Active entity"
                  className="min-h-11 min-w-0 rounded-lg border border-border bg-surface px-3 text-sm font-medium text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
                >
                  {entities.map((entity) => (
                    <option key={entity.id} value={entity.id}>
                      {entity.name}
                    </option>
                  ))}
                </select>
              ) : (
                <span className="truncate rounded-lg bg-surface-alt px-3 py-1.5 text-sm font-medium text-ink">
                  {activeEntity?.name ?? 'No entity assigned'}
                </span>
              )}
            </div>

            <div className="flex items-center gap-2">
              <NotificationBell />
              <span className="hidden text-sm text-muted sm:inline">{profile?.full_name ?? 'Signed in'}</span>
              <button onClick={() => signOut()} className="btn-secondary hidden md:inline-flex">
                Sign out
              </button>
            </div>
          </header>

          <main id="main" tabIndex={-1} className="flex-1 px-4 pb-28 pt-5 focus:outline-none md:px-6 md:pb-8">
            {children}
          </main>
        </div>
      </div>

      {/* Mobile bottom navigation — 4 destinations + More */}
      <nav
        aria-label="Main"
        className="fixed inset-x-0 bottom-0 z-20 flex border-t border-border bg-surface pb-[env(safe-area-inset-bottom)] md:hidden"
      >
        {mobile.primary.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.to === '/'}
            className={({ isActive }) =>
              `flex min-h-14 flex-1 flex-col items-center justify-center gap-0.5 text-xs font-medium ${
                isActive ? 'text-brand-blue' : 'text-muted'
              }`
            }
          >
            <NavGlyph icon={item.icon} className="h-6 w-6" />
            {item.label}
          </NavLink>
        ))}
        <button
          ref={moreButtonRef}
          type="button"
          onClick={() => setMoreOpen(true)}
          aria-haspopup="dialog"
          aria-expanded={moreOpen}
          className={`flex min-h-14 flex-1 flex-col items-center justify-center gap-0.5 text-xs font-medium ${
            moreActive ? 'text-brand-blue' : 'text-muted'
          }`}
        >
          <NavGlyph icon="more" className="h-6 w-6" />
          More
        </button>
      </nav>

      {moreOpen && (
        <div className="fixed inset-0 z-30 flex items-end bg-ink/40 md:hidden" onClick={() => setMoreOpen(false)}>
          <div
            ref={sheetRef}
            role="dialog"
            aria-modal="true"
            aria-label="More destinations"
            className="w-full rounded-t-2xl bg-surface p-4 pb-[calc(1rem+env(safe-area-inset-bottom))]"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="mx-auto mb-3 h-1 w-10 rounded-full bg-border" aria-hidden="true" />
            <div className="space-y-1">
              {mobile.more.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  className={({ isActive }) =>
                    `flex min-h-12 items-center gap-3 rounded-lg px-3 text-base ${
                      isActive ? 'bg-brand-blue-soft text-brand-blue-text' : 'text-ink hover:bg-surface-alt'
                    }`
                  }
                >
                  <NavGlyph icon={item.icon} />
                  {item.label}
                </NavLink>
              ))}
              <button
                type="button"
                onClick={() => signOut()}
                className="flex min-h-12 w-full items-center gap-3 rounded-lg px-3 text-left text-base text-brand-risk hover:bg-brand-risk-soft"
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
