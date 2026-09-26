import { supabase } from '../supabase'
import { callRpc, type ApiResult } from './client'
import type { UserRole } from '../../types/db'
import type { InviteStatus } from '../authFlows'

// Admin / settings RPCs. Several of these are being created by the backend
// in parallel — keep names/params exactly as agreed so any later tweak is a
// one-file fix.

export interface EntityRow {
  id: string
  name: string
  code?: string | null
  trade_license_no: string | null
  emirate: string | null
  default_currency: string | null
  payroll_day?: number | null
  is_active?: boolean | null
  created_at: string | null
}

export interface LocationRow {
  id: string
  entity_id: string
  name: string
  code?: string | null
  address: string | null
  is_active?: boolean | null
  created_at: string | null
}

export interface EntityInput {
  id: string | null
  name: string
  code: string
  trade_license_no: string
  emirate: string
  default_currency: string
  payroll_day: number | null
  is_active: boolean
}

export interface LocationInput {
  id: string | null
  entity_id: string
  name: string
  code: string
  address: string
  is_active: boolean
}

export interface DependencySummary {
  entity_id?: string | null
  location_id?: string | null
  active_employees: number
  future_shifts: number
  open_leave_requests: number
  draft_payroll_runs: number
}

export interface UserAccessRow {
  user_id: string | null
  email: string | null
  full_name: string | null
  role: UserRole
  entity_id: string | null
  location_id: string | null
  employee_id: string | null
  is_active: boolean
  last_sign_in_at: string | null
  is_pending: boolean
  grant_id: string | null
}

export interface RetentionPolicy {
  id: string
  entity_id: string
  table_name: string
  retention_years: number
  disposal_method: 'manual_review' | 'soft_delete' | 'hard_delete'
  legal_basis: string | null
  is_approved: boolean
  approved_at: string | null
  created_at: string
}

export interface BulkImportResultRow {
  row_index: number
  success: boolean
  employee_id: string | null
  errors: string[] | null
}

// ---------- reads (RLS-scoped tables) ----------

export async function listEntities(): Promise<ApiResult<EntityRow[]>> {
  const { data, error } = await supabase.from('entities').select('*').order('name')
  return { data: (data ?? []) as EntityRow[], error: error?.message ?? null }
}

export async function listLocations(entityId?: string | null): Promise<ApiResult<LocationRow[]>> {
  let q = supabase.from('locations').select('*').order('name')
  if (entityId) q = q.eq('entity_id', entityId)
  const { data, error } = await q
  return { data: (data ?? []) as LocationRow[], error: error?.message ?? null }
}

export async function listPositions(entityId: string) {
  const { data, error } = await supabase.from('positions').select('id, title, department').eq('entity_id', entityId).order('title')
  return { data: (data ?? []) as { id: string; title: string; department: string | null }[], error: error?.message ?? null }
}

export async function listRetentionPolicies(entityId?: string | null): Promise<ApiResult<RetentionPolicy[]>> {
  let q = supabase.from('data_retention_policies').select('*').order('created_at', { ascending: false })
  if (entityId) q = q.eq('entity_id', entityId)
  const { data, error } = await q
  return { data: (data ?? []) as RetentionPolicy[], error: error?.message ?? null }
}

// ---------- entities & branches ----------

export const adminUpsertEntity = (i: EntityInput) =>
  callRpc<string>('admin_upsert_entity', {
    p_id: i.id,
    p_name: i.name,
    p_code: i.code || null,
    p_trade_license_no: i.trade_license_no || null,
    p_emirate: i.emirate || null,
    p_default_currency: i.default_currency || 'AED',
    p_payroll_day: i.payroll_day,
    p_is_active: i.is_active,
  })

export const adminUpsertLocation = (i: LocationInput) =>
  callRpc<string>('admin_upsert_location', {
    p_id: i.id,
    p_entity_id: i.entity_id,
    p_name: i.name,
    p_code: i.code || null,
    p_address: i.address || null,
    p_is_active: i.is_active,
  })

export const getEntityDependencySummary = (entityId: string | null, locationId: string | null) =>
  callRpc<DependencySummary>('get_entity_dependency_summary', { p_entity_id: entityId, p_location_id: locationId })

// ---------- users & access ----------

/** Owner: null = every entity. Entity admin: own entity (null or own id). */
export const adminListUserAccess = (entityId: string | null) =>
  callRpc<UserAccessRow[]>('admin_list_user_access', { p_entity_id: entityId })

export const adminGrantAccess = (
  email: string,
  role: UserRole,
  entityId: string | null,
  locationId: string | null,
  employeeId: string | null
) =>
  callRpc<string>('admin_grant_access', {
    p_email: email,
    p_role: role,
    p_entity_id: entityId,
    p_location_id: locationId,
    p_employee_id: employeeId,
  })

export const adminRevokeAccess = (userId: string | null, grantId: string | null, reason: string) =>
  callRpc<null>('admin_revoke_access', { p_user_id: userId, p_grant_id: grantId, p_reason: reason })

// ---------- policies ----------

export const proposeDataRetentionPolicy = (
  tableName: string,
  retentionYears: number,
  disposalMethod: string,
  legalBasis: string | null,
  /** Owner must pass the target entity; entity_admin may pass null (own). */
  entityId: string | null
) =>
  callRpc<string>('propose_data_retention_policy', {
    p_table_name: tableName,
    p_retention_years: retentionYears,
    p_disposal_method: disposalMethod,
    p_legal_basis: legalBasis,
    p_entity_id: entityId,
  })

export const approveDataRetentionPolicy = (policyId: string) =>
  callRpc<null>('approve_data_retention_policy', { p_policy_id: policyId })

export const getEntityAdminSelfApproval = () => callRpc<boolean>('entity_admin_self_approval_enabled')
export const setEntityAdminSelfApproval = (enabled: boolean) =>
  callRpc<null>('set_entity_admin_self_approval', { p_enabled: enabled })

// ---------- bulk import ----------

export const bulkImportEmployees = (entityId: string, rows: Record<string, unknown>[]) =>
  callRpc<BulkImportResultRow[]>('bulk_import_employees', { p_entity_id: entityId, p_rows: rows })

// ---------- invitations (Edge Function) ----------

export interface InviteResult {
  status: InviteStatus | null
  message: string | null
  errorCode: string | null
  httpStatus: number | null
}

/**
 * Ask the invite-user Edge Function to send (or re-send) the Supabase
 * invitation email for an email that already has an access grant. The
 * function re-checks the caller's role/scope server-side; this never throws.
 */
export async function sendInvite(email: string): Promise<InviteResult> {
  try {
    const { data, error } = await supabase.functions.invoke<{ status?: InviteStatus; message?: string }>('invite-user', {
      body: { email },
    })
    if (!error) return { status: data?.status ?? null, message: data?.message ?? null, errorCode: null, httpStatus: 200 }
    // FunctionsHttpError carries the Response; read the JSON {error, message} body.
    const ctx = (error as { context?: unknown }).context
    if (ctx instanceof Response) {
      let body: { error?: string; message?: string } = {}
      try {
        body = await ctx.clone().json()
      } catch {
        /* non-JSON body */
      }
      return { status: null, message: body.message ?? null, errorCode: body.error ?? null, httpStatus: ctx.status }
    }
    return { status: null, message: error.message ?? null, errorCode: null, httpStatus: null }
  } catch (e) {
    return { status: null, message: e instanceof Error ? e.message : null, errorCode: null, httpStatus: null }
  }
}
