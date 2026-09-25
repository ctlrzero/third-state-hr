import { useAuth } from '../auth/AuthContext'

/**
 * Small uppercase label above a page title naming the legal entity the page
 * is scoped to. Uses the active entity from the switcher (owner) or the
 * user's own entity, so Ateej and UAT users never see "Third State Café".
 */
export function EntityEyebrow() {
  const { entities, activeEntityId } = useAuth()
  const name = entities.find((e) => e.id === activeEntityId)?.name ?? 'Third State HR'
  return <p className="text-xs font-semibold uppercase tracking-wider text-muted">{name}</p>
}
