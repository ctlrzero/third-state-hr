import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'
import { hasOwnOpenOnboarding } from '../lib/api/onboarding'
import type { Entity, Profile } from '../types/db'
import { isSelfServiceRole } from '../types/db'

type AuthStatus = 'loading' | 'signed-out' | 'no-assignment' | 'ready'

/** Why a signed-in user has no usable workspace (drives the /no-assignment copy). */
export type NoAssignmentReason = 'inactive' | 'unassigned' | null

/** sessionStorage flag set when Supabase ends a session the user didn't sign out of. */
export const SESSION_EXPIRED_KEY = 'ts-hr:session-expired'

interface AuthContextValue {
  status: AuthStatus
  session: Session | null
  profile: Profile | null
  /** All entities the signed-in user is authorised to view (owner sees every active entity). */
  entities: Entity[]
  /** Currently selected entity for scoping dashboard/report queries. */
  activeEntityId: string | null
  setActiveEntityId: (id: string) => void
  /**
   * Whether the signed-in employee has at least one interview assignment
   * (has_interview_assignments() RPC — resolved from auth.uid() server-side,
   * never a client-supplied employee id). Drives whether "My Interviews"
   * shows in navigation. This is a UI convenience only: RLS and the
   * get_my_interviews()/get_interview_detail() RPCs are what actually gate
   * access to interview data, so a false value here never has to be trusted
   * as a security control by itself, and a true value can't grant more than
   * those checks already allow.
   */
  hasInterviewAssignments: boolean
  /**
   * Staff only: shows the Onboarding nav item when the person has their own
   * open onboarding, or can review new starters' pay (payroll approver).
   * UI convenience; the onboarding RPCs are the real gate.
   */
  hasOnboarding: boolean
  noAssignmentReason: NoAssignmentReason
  signInWithPassword: (email: string, password: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
  refreshProfile: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined)

const LAST_ENTITY_KEY = 'ts-hr:last-entity-id'

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [entities, setEntities] = useState<Entity[]>([])
  const [activeEntityId, setActiveEntityIdState] = useState<string | null>(null)
  const [status, setStatus] = useState<AuthStatus>('loading')
  const [hasInterviewAssignments, setHasInterviewAssignments] = useState(false)
  const [hasOnboarding, setHasOnboarding] = useState(false)
  const [noAssignmentReason, setNoAssignmentReason] = useState<NoAssignmentReason>(null)
  const manualSignOut = useRef(false)

  async function loadProfileAndEntities(currentSession: Session) {
    const userId = currentSession.user.id

    const { data: profileRow, error: profileError } = await supabase
      .from('profiles')
      .select('id, full_name, role, entity_id, location_id, created_at, is_active')
      .eq('id', userId)
      .maybeSingle()

    if (profileError || !profileRow) {
      setProfile(null)
      setEntities([])
      setNoAssignmentReason('unassigned')
      setStatus('no-assignment')
      return
    }

    // Revoked / inactivated accounts: the backend already resolves them to no
    // role, so every RPC denies them — show the dedicated state, not a shell.
    if ((profileRow as Profile).is_active === false) {
      setProfile(null)
      setEntities([])
      setNoAssignmentReason('inactive')
      setStatus('no-assignment')
      return
    }
    setNoAssignmentReason(null)

    setProfile(profileRow as Profile)

    supabase
      .rpc('has_interview_assignments')
      .then(
        ({ data }) => setHasInterviewAssignments(Boolean(data)),
        () => setHasInterviewAssignments(false)
      )

    setHasOnboarding(false)
    if (isSelfServiceRole((profileRow as Profile).role)) {
      const entityId = (profileRow as Profile).entity_id
      Promise.all([
        hasOwnOpenOnboarding(),
        entityId ? supabase.rpc('payroll_can', { p_entity_id: entityId, p_cap: 'approve' }).then((r) => Boolean(r.data)) : Promise.resolve(false),
      ]).then(
        ([own, pay]) => setHasOnboarding(own || pay),
        () => setHasOnboarding(false)
      )
    }

    // Owner has entity_id = null and is authorised to view every entity; everyone
    // else is scoped to exactly one entity by row-level security on `entities`.
    const { data: entityRows } = await supabase
      .from('entities')
      .select('id, name, trade_license_no, emirate, default_currency, created_at')
      .order('name', { ascending: true })

    const authorisedEntities = entityRows ?? []
    setEntities(authorisedEntities as Entity[])

    const remembered = localStorage.getItem(LAST_ENTITY_KEY)
    const stillAuthorised = authorisedEntities.some((e) => e.id === remembered)
    const nextActiveEntity =
      (stillAuthorised && remembered) ||
      (profileRow as Profile).entity_id ||
      authorisedEntities[0]?.id ||
      null

    setActiveEntityIdState(nextActiveEntity)
    if (authorisedEntities.length === 0) setNoAssignmentReason('unassigned')
    setStatus(authorisedEntities.length > 0 ? 'ready' : 'no-assignment')
  }

  useEffect(() => {
    let cancelled = false

    supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return
      setSession(data.session)
      if (data.session) {
        await loadProfileAndEntities(data.session)
      } else {
        setStatus('signed-out')
      }
    })

    const { data: listener } = supabase.auth.onAuthStateChange(async (_event, newSession) => {
      setSession(newSession)
      if (newSession) {
        setStatus('loading')
        await loadProfileAndEntities(newSession)
      } else {
        // A session that ends without the user pressing Sign out (refresh
        // token expired/revoked) gets a friendly notice on the sign-in page.
        if (!manualSignOut.current && _event === 'SIGNED_OUT') {
          try {
            sessionStorage.setItem(SESSION_EXPIRED_KEY, '1')
          } catch {
            /* storage unavailable — notice is best-effort */
          }
        }
        manualSignOut.current = false
        setProfile(null)
        setEntities([])
        setActiveEntityIdState(null)
        setHasInterviewAssignments(false)
        setNoAssignmentReason(null)
        localStorage.removeItem(LAST_ENTITY_KEY)
        setStatus('signed-out')
      }
    })

    return () => {
      cancelled = true
      listener.subscription.unsubscribe()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  function setActiveEntityId(id: string) {
    setActiveEntityIdState(id)
    localStorage.setItem(LAST_ENTITY_KEY, id)
  }

  async function signInWithPassword(email: string, password: string) {
    try {
      sessionStorage.removeItem(SESSION_EXPIRED_KEY)
    } catch {
      /* ignore */
    }
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    return { error: error?.message ?? null }
  }

  async function signOut() {
    // Clear anything scope-sensitive before the network round trip completes
    // so a slow connection can't briefly show stale, previously-authorised data.
    manualSignOut.current = true
    setProfile(null)
    setEntities([])
    setActiveEntityIdState(null)
    setHasInterviewAssignments(false)
    localStorage.removeItem(LAST_ENTITY_KEY)
    await supabase.auth.signOut()
  }

  async function refreshProfile() {
    if (session) await loadProfileAndEntities(session)
  }

  const value = useMemo(
    () => ({
      status,
      session,
      profile,
      entities,
      activeEntityId,
      setActiveEntityId,
      hasInterviewAssignments,
      hasOnboarding,
      noAssignmentReason,
      signInWithPassword,
      signOut,
      refreshProfile,
    }),
    [status, session, profile, entities, activeEntityId, hasInterviewAssignments, hasOnboarding, noAssignmentReason]
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within AuthProvider')
  return ctx
}
