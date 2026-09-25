import { callRpc } from './client'

/** get_owner_dashboard_kpis result (API contract §9). */
export interface OwnerDashboardKpis {
  entity_id: string | null
  scope: 'entity' | 'all_entities'
  generated_at: string
  headcount: { candidate: number; pre_boarding: number; active: number; inactive: number; total: number }
  document_expiry: { expired: number; expiring_30_days: number; ok: number }
  document_review_queue: number
  leave: { pending_requests: number; approved_this_month: number }
  payroll: { draft_runs: number; in_review_runs: number; approved_unpaid_runs: number; paid_runs: number }
  recruitment: { open_requisitions: number; candidates_in_pipeline: number }
  workflow: { active_rules: number; runs_last_7_days: number }
}

/** Owner: null = all entities. Entity admin: own entity only (null or own id). */
export const getOwnerDashboardKpis = (entityId: string | null) =>
  callRpc<OwnerDashboardKpis>('get_owner_dashboard_kpis', { p_entity_id: entityId })
