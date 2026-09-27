import { supabase } from '../supabase'
import { callRpc, type ApiResult } from './client'

// Smart onboarding (Builds A–E). Every action is a SECURITY DEFINER RPC that
// re-checks the caller's role, company, branch and — for pay/bank — payroll
// permission; the onboarding tables are read-only to the app. Readiness is
// always computed on the server: the UI only displays it.

export type OnboardingStatus =
  | 'initiated'
  | 'awaiting_employee'
  | 'under_review'
  | 'changes_required'
  | 'blocked'
  | 'ready_for_activation'
  | 'activated'
  | 'day_one'
  | 'in_progress'
  | 'completed'
  | 'cancelled'
  | 'withdrawn'

export type TaskStatus = 'not_started' | 'in_progress' | 'submitted' | 'changes_required' | 'approved' | 'waived' | 'cancelled'
export type OwnerRole = 'employee' | 'location_manager' | 'hr' | 'payroll' | 'approver'
export type ReviewerRole = 'location_manager' | 'hr' | 'payroll'
export type TaskKind = 'manual' | 'profile' | 'document' | 'acknowledgement' | 'contract_acceptance' | 'payment_details' | 'compensation' | 'availability'
export type Phase = 'pre_activation' | 'day_one' | 'initial_period'
export type ListTab =
  | 'all'
  | 'new'
  | 'awaiting_employee'
  | 'under_review'
  | 'blocked'
  | 'ready'
  | 'starting_soon'
  | 'in_progress'
  | 'completed'
  | 'cancelled'

export interface ReadinessItem {
  code: string
  message: string
  owner_role?: OwnerRole
  task_id?: string
  exception_id?: string
  due_date?: string | null
}

export interface Readiness {
  ready: boolean
  blockers: ReadinessItem[]
  warnings: ReadinessItem[]
  blocking_count: number
  required_total: number
  required_done: number
  percent: number
  next_action: string | null
  computed_at: string
}

export interface OnboardingRow {
  onboarding_instance_id: string
  employee_id: string
  name: string
  employee_number: string | null
  branch: string | null
  position: string | null
  status: OnboardingStatus
  source: 'offer' | 'direct_hire' | 'existing_employee'
  proposed_start_date: string | null
  days_in_stage: number
  row_version: number
  blocking_count: number
  overdue_tasks: number
  next_due: string | null
  last_activity: string
}

export interface OnboardingTask {
  id: string
  item_key: string
  item_label: string
  section: string
  phase: Phase
  kind: TaskKind
  owner_role: OwnerRole
  reviewer_role: ReviewerRole | null
  status: TaskStatus
  is_required: boolean
  is_waivable: boolean
  due_date: string | null
  review_reason: string | null
  waived_reason?: string | null
  depends_on: string[] | null
  description?: string | null
  doc_type?: string | null
  policy_key?: string | null
  mine?: boolean
}

export interface OnboardingException {
  id: string
  exception_type: string
  is_blocking: boolean
  description: string
  owner_role: Exclude<OwnerRole, 'employee'>
  due_date: string | null
  status: 'open' | 'resolved' | 'cancelled'
  resolution: string | null
  raised_at: string
  resolved_at: string | null
}

export interface PendingCompensation {
  instance_id: string
  pay_type: 'monthly' | 'hourly'
  basic_monthly: number | null
  hourly_rate: number | null
  overtime_eligible: boolean
  effective_from: string | null
  reason: string | null
  offer_amount: number | null
  variance_reason: string | null
  status: 'pending_review' | 'approved' | 'changes_required'
  set_by: string | null
  set_at: string
  reviewed_by: string | null
  review_reason: string | null
}

export interface PaymentDetails {
  id?: string
  method: 'bank_transfer' | 'exchange_house' | 'wps_card' | 'cash'
  bank_name?: string | null
  account_name?: string | null
  iban?: string | null
  iban_last4?: string | null
  status: 'submitted' | 'verified' | 'rejected' | 'superseded'
  submitted_by?: string | null
  submitted_at?: string
  rejection_reason?: string | null
}

export interface ProbationPeriod {
  id: string
  start_date: string
  end_date: string
  review_due_date: string
  status: 'active' | 'confirmed' | 'extended' | 'not_confirmed'
  previous_period_id: string | null
  decision_reason: string | null
}

export interface OnboardingInstance {
  id: string
  employee_id: string
  entity_id: string
  home_location_id: string | null
  position_id: string | null
  reporting_manager_employee_id: string | null
  employment_type: string | null
  proposed_start_date: string | null
  actual_start_date: string | null
  status: OnboardingStatus
  row_version: number
  source: OnboardingRow['source']
  offer_id: string | null
  day_one_outcome: 'started' | 'no_show' | 'delayed' | null
  activated_at: string | null
  completed_at: string | null
  end_reason: string | null
  started_at: string
}

export interface Workspace {
  instance: OnboardingInstance
  template: { id: string | null; name: string | null; version: number | null }
  employee: {
    id: string
    name: string
    employee_number: string | null
    email: string | null
    phone: string | null
    employment_status: string
    has_login: boolean
    nationality: string | null
  }
  permissions: { manage: boolean; payroll: boolean; approve: boolean; operate: boolean }
  readiness: Readiness
  tasks: OnboardingTask[]
  sections: { id: string; section: string; version: number; status: string; submitted_at: string; submitted_by: string | null }[]
  reviews: { section: string; decision: string; reason: string | null; reviewer_role: string; at: string }[]
  exceptions: OnboardingException[]
  invitation: { status: 'issued' | 'accepted' | 'expired' | 'revoked'; sent_to: string | null; issued_at: string; expires_at: string; accepted_at: string | null } | null
  compensation: PendingCompensation | null
  payment_details: PaymentDetails | null
  contract: { accepted_at: string; document_id: string; document_version: number } | null
  probation: ProbationPeriod[] | null
  timeline: { action: string; at: string; by: string | null }[]
}

export interface DashboardSummary {
  open: number
  by_status: Partial<Record<OnboardingStatus, number>>
  starting_7_days: number
  start_at_risk: number
  ready_for_activation: number
  awaiting_review: number
  overdue_tasks: number
  open_exceptions: number
  pay_awaiting_review: number | null
  bank_awaiting_verification: number | null
  probation_reviews_due: number
}

export interface MyOnboarding {
  id: string
  status: OnboardingStatus
  row_version: number
  proposed_start_date: string | null
  actual_start_date: string | null
  company: string | null
  branch: { name: string; address: string | null } | null
  position: { title: string; department: string | null; description: string | null } | null
  manager: { name: string; phone: string | null } | null
  profile: {
    full_name: string
    preferred_name: string | null
    email: string | null
    phone: string | null
    dob: string | null
    gender: string | null
    nationality: string | null
    residential_address: string | null
    emergency_contact_name: string | null
    emergency_contact_phone: string | null
    employee_number: string | null
  }
  readiness: Readiness
  tasks: OnboardingTask[]
  sections: Record<string, string>
  documents: { id: string; doc_type: string; review_status: string; is_current: boolean; expiry_date: string | null; rejection_reason: string | null; submitted_at: string }[]
  payment_details: { method: PaymentDetails['method']; bank_name: string | null; account_name: string | null; iban_last4: string | null; status: PaymentDetails['status']; rejection_reason: string | null } | null
  policies: { id: string; policy_key: string; title: string; version: string; body: string; acknowledged_at: string | null }[]
  contract: { document_id: string; version: number; approved: boolean; accepted_at: string | null } | null
}

export interface ProbationDueRow {
  period_id: string
  employee_id: string
  full_name: string
  location: string | null
  start_date: string
  end_date: string
  review_due_date: string
  is_extension: boolean
  reviews: number
  overdue: boolean
}

export interface OnboardingTemplate {
  id: string
  name: string
  description: string | null
  version_number: number
  is_active: boolean
  applies_to_employment_types: string[] | null
  applies_to_position_ids: string[] | null
  created_at: string
}

export interface OnboardingPolicy {
  id: string
  policy_key: string
  version: string
  title: string
  body: string
  is_active: boolean
}

export interface OnboardingSettings {
  invitation_valid_days: number
  probation_months: number
  probation_review_days_before: number
  default_task_sla_days: number
  require_distinct_activation_approver: boolean
}

export type ReportKind =
  | 'funnel'
  | 'ageing'
  | 'blocked_reasons'
  | 'starting_soon'
  | 'overdue_tasks'
  | 'invitations'
  | 'document_rejections'
  | 'day_one'
  | 'probation_due'
  | 'time_to_activate'

// ------------------------------------------------------------- reads
export const listOnboarding = (entityId: string, tab: ListTab = 'all') =>
  callRpc<OnboardingRow[]>('list_onboarding', { p_entity_id: entityId, p_tab: tab })

export const getWorkspace = (instanceId: string) => callRpc<Workspace>('get_onboarding_workspace', { p_instance_id: instanceId })

export const dashboardSummary = (entityId: string) =>
  callRpc<DashboardSummary>('onboarding_dashboard_summary', { p_entity_id: entityId })

export const calculateReadiness = (instanceId: string) =>
  callRpc<Readiness>('calculate_onboarding_readiness', { p_instance_id: instanceId })

export async function getMyOnboarding(): Promise<ApiResult<MyOnboarding | null>> {
  const res = await callRpc<{ ok: boolean; onboarding: MyOnboarding | null }>('get_my_onboarding')
  return { data: res.data?.onboarding ?? null, error: res.error }
}

export const listProbationDue = (entityId: string, withinDays = 30) =>
  callRpc<ProbationDueRow[]>('list_probation_due', { p_entity_id: entityId, p_within_days: withinDays })

export const onboardingReport = (entityId: string, kind: ReportKind, from?: string, to?: string) =>
  callRpc<{ kind: ReportKind; from: string; to: string; data: unknown }>('onboarding_report', {
    p_entity_id: entityId,
    p_kind: kind,
    p_from: from ?? null,
    p_to: to ?? null,
  })

/** Open onboarding for an employee (RLS-scoped direct read), or null. */
export async function findOpenOnboarding(employeeId: string): Promise<{ id: string; status: OnboardingStatus } | null> {
  const { data, error } = await supabase
    .from('onboarding_instances')
    .select('id, status')
    .eq('employee_id', employeeId)
    .not('status', 'in', '(completed,cancelled,withdrawn)')
    .limit(1)
    .maybeSingle()
  if (error || !data) return null
  return data as { id: string; status: OnboardingStatus }
}

/** Does the signed-in person have their own open onboarding? (false if the backend is not deployed) */
export async function hasOwnOpenOnboarding(): Promise<boolean> {
  const { data: me } = await supabase.rpc('my_employee_id')
  if (!me) return false
  return (await findOpenOnboarding(me as string)) !== null
}

export async function listTemplates(entityId: string): Promise<ApiResult<OnboardingTemplate[]>> {
  const { data, error } = await supabase
    .from('onboarding_templates')
    .select('id, name, description, version_number, is_active, applies_to_employment_types, applies_to_position_ids, created_at')
    .eq('entity_id', entityId)
    .order('is_active', { ascending: false })
    .order('created_at', { ascending: false })
  return { data: (data ?? []) as OnboardingTemplate[], error: error ? error.message : null }
}

export async function listTemplateTasks(templateId: string): Promise<ApiResult<(OnboardingTask & { due_offset_days: number | null; is_statutory: boolean; depends_on: string[] })[]>> {
  const { data, error } = await supabase
    .from('onboarding_template_tasks')
    .select('*')
    .eq('template_id', templateId)
    .order('sort_order')
  return { data: (data ?? []) as never, error: error ? error.message : null }
}

export async function listPolicies(entityId: string): Promise<ApiResult<OnboardingPolicy[]>> {
  const { data, error } = await supabase
    .from('onboarding_policies')
    .select('id, policy_key, version, title, body, is_active')
    .eq('entity_id', entityId)
    .eq('is_active', true)
    .order('policy_key')
  return { data: (data ?? []) as OnboardingPolicy[], error: error ? error.message : null }
}

export async function getSettings(entityId: string): Promise<ApiResult<OnboardingSettings>> {
  const { data, error } = await supabase.from('onboarding_settings').select('*').eq('entity_id', entityId).maybeSingle()
  const defaults: OnboardingSettings = {
    invitation_valid_days: 7,
    probation_months: 6,
    probation_review_days_before: 14,
    default_task_sla_days: 3,
    require_distinct_activation_approver: true,
  }
  return { data: { ...defaults, ...((data ?? {}) as Partial<OnboardingSettings>) }, error: error ? error.message : null }
}

export async function getNumbering(entityId: string): Promise<{ prefix: string; next_value: number; pad_width: number }> {
  const { data } = await supabase.from('employee_numbering').select('prefix, next_value, pad_width').eq('entity_id', entityId).maybeSingle()
  return (data as { prefix: string; next_value: number; pad_width: number } | null) ?? { prefix: 'EMP-', next_value: 1, pad_width: 4 }
}

// --------------------------------------------------------- setup (A)
export const setSettings = (entityId: string, s: Partial<OnboardingSettings>) =>
  callRpc<OnboardingSettings>('set_onboarding_settings', { p_entity_id: entityId, p: s })

export const setNumbering = (entityId: string, prefix: string, nextValue: number, padWidth: number) =>
  callRpc<unknown>('set_employee_numbering', { p_entity_id: entityId, p_prefix: prefix, p_next_value: nextValue, p_pad_width: padWidth })

export const seedDefaultTemplate = (entityId: string) => callRpc<string>('seed_default_onboarding_template', { p_entity_id: entityId })

export const deactivateTemplate = (templateId: string) => callRpc<null>('deactivate_onboarding_template', { p_template_id: templateId })

export const replaceTemplate = (
  templateId: string,
  name: string,
  description: string | null,
  tasks: unknown[],
  employmentTypes: string[] | null,
  positionIds: string[] | null
) =>
  callRpc<string>('replace_onboarding_template', {
    p_template_id: templateId,
    p_name: name,
    p_description: description,
    p_tasks: tasks,
    p_employment_types: employmentTypes,
    p_position_ids: positionIds,
  })

export const upsertPolicy = (entityId: string, key: string, version: string, title: string, body: string) =>
  callRpc<string>('upsert_onboarding_policy', { p_entity_id: entityId, p_policy_key: key, p_version: version, p_title: title, p_body: body })

// ------------------------------------------------------ lifecycle (A)
interface StartResult {
  ok: boolean
  already_started?: boolean
  employee_id: string
  onboarding_instance_id: string
  task_count?: number
}

export const startFromOffer = (offerId: string, managerEmployeeId: string | null) =>
  callRpc<StartResult>('start_onboarding_from_offer', { p_offer_id: offerId, p_reporting_manager_employee_id: managerEmployeeId })

export interface DirectHireInput {
  entityId: string
  fullName: string
  email: string | null
  phone: string | null
  gender: string | null
  locationId: string | null
  positionId: string | null
  employmentType: string | null
  startDate: string | null
  managerEmployeeId: string | null
  reason: string
}

export const startDirectHire = (i: DirectHireInput) =>
  callRpc<StartResult>('start_onboarding_direct_hire', {
    p_entity_id: i.entityId,
    p_full_name: i.fullName,
    p_email: i.email,
    p_phone: i.phone,
    p_gender: i.gender,
    p_home_location_id: i.locationId,
    p_position_id: i.positionId,
    p_employment_type: i.employmentType,
    p_start_date: i.startDate,
    p_reporting_manager_employee_id: i.managerEmployeeId,
    p_reason: i.reason,
  })

export const startForEmployee = (employeeId: string, managerEmployeeId: string | null, reason: string) =>
  callRpc<StartResult>('start_onboarding_for_employee', {
    p_employee_id: employeeId,
    p_reporting_manager_employee_id: managerEmployeeId,
    p_reason: reason,
  })

export const updateSetup = (instanceId: string, patch: Record<string, string | null>, reason: string, expectedVersion: number) =>
  callRpc<Readiness | null>('update_onboarding_setup', {
    p_instance_id: instanceId,
    p: patch,
    p_reason: reason,
    p_expected_version: expectedVersion,
  })

export const cancelOnboarding = (instanceId: string, reason: string) =>
  callRpc<unknown>('cancel_onboarding', { p_instance_id: instanceId, p_reason: reason })

export const withdrawOnboarding = (instanceId: string, reason: string) =>
  callRpc<unknown>('withdraw_onboarding', { p_instance_id: instanceId, p_reason: reason })

// ---------------------------------------------------- pre-boarding (B)
export interface InvitationResult {
  ok: boolean
  already_issued: boolean
  invitation_id: string
  email: string
  expires_at: string
  send_email: boolean
}

export const issueInvitation = (instanceId: string) => callRpc<InvitationResult>('issue_onboarding_invitation', { p_instance_id: instanceId })

export const reissueInvitation = (instanceId: string, reason: string, newEmail: string | null) =>
  callRpc<InvitationResult>('reissue_onboarding_invitation', { p_instance_id: instanceId, p_reason: reason, p_new_email: newEmail })

export const saveMyProfile = (patch: Record<string, string | null>) => callRpc<{ ok: boolean }>('save_my_onboarding_profile', { p: patch })

export const saveMyPaymentDetails = (method: string, bankName: string, accountName: string, iban: string | null) =>
  callRpc<{ ok: boolean; id: string }>('save_my_payment_details', {
    p_method: method,
    p_bank_name: bankName,
    p_account_name: accountName,
    p_iban: iban,
    p_routing_code: null,
  })

export const acknowledgePolicy = (policyId: string) => callRpc<{ ok: boolean; already: boolean }>('acknowledge_onboarding_policy', { p_policy_id: policyId })

export const acceptContract = (instanceId: string) =>
  callRpc<{ ok: boolean; already_accepted: boolean }>('accept_employment_contract', { p_onboarding_instance_id: instanceId })

export const submitSection = (instanceId: string, section: string) =>
  callRpc<Readiness>('submit_onboarding_section', { p_instance_id: instanceId, p_section: section })

export const completeTask = (taskId: string, evidence: Record<string, unknown> | null) =>
  callRpc<{ ok: boolean; status: TaskStatus }>('complete_onboarding_task', { p_task_id: taskId, p_evidence: evidence })

const BUCKET = 'employee-documents'

/**
 * Employee self-upload: stage (server derives the path) → upload bytes →
 * confirm (server checks the object exists). Same flow as Documents.tsx.
 */
export async function uploadMyDocument(docType: string, file: File, expiryDate: string | null): Promise<ApiResult<string>> {
  const ext = file.name.split('.').pop()?.toLowerCase() ?? ''
  if (!['pdf', 'jpg', 'jpeg', 'png'].includes(ext)) return { data: null, error: 'Only PDF, JPG and PNG files are accepted.' }
  if (file.size > 10 * 1024 * 1024) return { data: null, error: 'The file is larger than 10 MB.' }
  const staged = await callRpc<{ id: string; storage_path: string }>('stage_my_onboarding_document', {
    p_doc_type: docType,
    p_file_extension: ext,
    p_expiry_date: expiryDate,
    p_notes: null,
  })
  if (staged.error || !staged.data) return { data: null, error: staged.error }
  const { error: upErr } = await supabase.storage.from(BUCKET).upload(staged.data.storage_path, file, { upsert: false })
  if (upErr) return { data: null, error: `Upload failed: ${upErr.message}. Please try again.` }
  const confirmed = await callRpc<{ ok: boolean; code?: string }>('confirm_document_upload', { p_document_id: staged.data.id })
  if (confirmed.error) return { data: null, error: confirmed.error }
  if (!confirmed.data?.ok) return { data: null, error: 'The upload did not complete — please try again.' }
  return { data: staged.data.id, error: null }
}

/** Short-lived link to view one of the caller's own (or in-scope) documents. */
export async function documentLink(storagePath: string): Promise<string | null> {
  const { data } = await supabase.storage.from(BUCKET).createSignedUrl(storagePath, 60)
  return data?.signedUrl ?? null
}

export async function getMyContract(): Promise<ApiResult<{ document_id: string; version: number; storage_path: string; accepted_at: string | null } | null>> {
  const res = await callRpc<{ ok: boolean; contract: { document_id: string; version: number; storage_path: string; accepted_at: string | null } | null }>(
    'get_my_contract'
  )
  return { data: res.data?.contract ?? null, error: res.error }
}

// --------------------------------------------------------- reviews (C)
export const reviewSection = (instanceId: string, section: string, decision: 'approved' | 'changes_required' | 'rejected', reason: string | null) =>
  callRpc<Readiness>('review_onboarding_section', { p_instance_id: instanceId, p_section: section, p_decision: decision, p_reason: reason })

export const reviewTask = (taskId: string, decision: 'approved' | 'changes_required', reason: string | null) =>
  callRpc<{ ok: boolean }>('review_onboarding_task', { p_task_id: taskId, p_decision: decision, p_reason: reason })

export const waiveTask = (taskId: string, reason: string) => callRpc<{ ok: boolean }>('waive_onboarding_task', { p_task_id: taskId, p_reason: reason })

export interface PayInput {
  effectiveFrom: string | null
  payType: 'monthly' | 'hourly'
  basicMonthly: number | null
  hourlyRate: number | null
  overtimeEligible: boolean
  reason: string | null
  varianceReason: string | null
}

export const setPendingPay = (instanceId: string, p: PayInput) =>
  callRpc<{ ok: boolean; status: string; differs_from_offer: boolean }>('set_onboarding_pending_compensation', {
    p_instance_id: instanceId,
    p_effective_from: p.effectiveFrom,
    p_pay_type: p.payType,
    p_basic_monthly: p.basicMonthly,
    p_hourly_rate: p.hourlyRate,
    p_overtime_eligible: p.overtimeEligible,
    p_reason: p.reason,
    p_variance_reason: p.varianceReason,
  })

export const reviewPay = (instanceId: string, decision: 'approved' | 'changes_required', reason: string | null) =>
  callRpc<{ ok: boolean }>('review_onboarding_compensation', { p_instance_id: instanceId, p_decision: decision, p_reason: reason })

export const verifyPaymentDetails = (id: string, decision: 'verified' | 'rejected', reason: string | null) =>
  callRpc<{ ok: boolean }>('verify_payment_details', { p_payment_details_id: id, p_decision: decision, p_reason: reason })

export const raiseException = (
  instanceId: string,
  type: string,
  description: string,
  ownerRole: string,
  blocking: boolean,
  dueDate: string | null
) =>
  callRpc<{ ok: boolean }>('raise_onboarding_exception', {
    p_instance_id: instanceId,
    p_type: type,
    p_description: description,
    p_owner_role: ownerRole,
    p_is_blocking: blocking,
    p_due_date: dueDate,
  })

export const resolveException = (exceptionId: string, resolution: string, cancel = false) =>
  callRpc<{ ok: boolean }>('resolve_onboarding_exception', { p_exception_id: exceptionId, p_resolution: resolution, p_cancel: cancel })

// ------------------------------------------------------ activation (D)
export interface ActivationResult {
  ok: boolean
  already_activated: boolean
  employee_id: string
  status: string
  join_date?: string
  probation_end_date?: string | null
  post_start_tasks?: number
}

export const approveAndActivate = (instanceId: string, expectedVersion: number, reason: string | null) =>
  callRpc<ActivationResult>('approve_and_activate_employee', {
    p_instance_id: instanceId,
    p_expected_version: expectedVersion,
    p_reason: reason,
  })

// ------------------------------------------- day one / probation (E)
export const recordDayOne = (instanceId: string, outcome: 'started' | 'no_show' | 'delayed', newDate: string | null, reason: string | null) =>
  callRpc<{ ok: boolean }>('record_day_one_outcome', {
    p_instance_id: instanceId,
    p_outcome: outcome,
    p_new_start_date: newDate,
    p_reason: reason,
  })

export const closeOnboarding = (instanceId: string, notes: string | null) =>
  callRpc<{ ok: boolean }>('close_onboarding', { p_instance_id: instanceId, p_notes: notes })

export const recordProbationReview = (
  periodId: string,
  recommendation: 'confirm' | 'extend' | 'not_confirm',
  comments: string,
  ratings: Record<string, number> | null
) =>
  callRpc<{ ok: boolean }>('record_probation_review', {
    p_period_id: periodId,
    p_recommendation: recommendation,
    p_comments: comments,
    p_ratings: ratings,
  })

export const decideProbation = (
  periodId: string,
  outcome: 'confirmed' | 'extended' | 'not_confirmed',
  effectiveDate: string | null,
  newEndDate: string | null,
  reason: string | null
) =>
  callRpc<{ ok: boolean }>('decide_probation_outcome', {
    p_period_id: periodId,
    p_outcome: outcome,
    p_effective_date: effectiveDate,
    p_new_end_date: newEndDate,
    p_reason: reason,
  })

// --------------------------------------------------- jobs (migration 011)
export interface Position {
  id: string
  title: string
  department: string | null
  description: string | null
}

export async function listPositions(entityId: string): Promise<ApiResult<Position[]>> {
  const { data, error } = await supabase.from('positions').select('id, title, department, description').eq('entity_id', entityId).order('title')
  return { data: (data ?? []) as Position[], error: error ? error.message : null }
}

export const upsertPosition = (entityId: string, id: string | null, title: string, department: string | null, description: string | null) =>
  callRpc<string>('upsert_position', { p_entity_id: entityId, p_position_id: id, p_title: title, p_department: department, p_description: description })

// ----------------------------------------------------- template editor
export interface TemplateTaskInput {
  item_key: string
  item_label: string
  description?: string | null
  section: string
  phase: Phase
  kind: TaskKind
  owner_role: OwnerRole
  reviewer_role?: ReviewerRole | null
  doc_type?: string | null
  policy_key?: string | null
  is_required: boolean
  is_statutory: boolean
  is_waivable?: boolean
  due_offset_days?: number | null
  depends_on: string[]
  sort_order?: number
}

export const createTemplate = (
  entityId: string,
  name: string,
  description: string | null,
  tasks: TemplateTaskInput[],
  employmentTypes: string[] | null,
  positionIds: string[] | null
) =>
  callRpc<string>('create_onboarding_template', {
    p_entity_id: entityId,
    p_name: name,
    p_description: description,
    p_tasks: tasks,
    p_employment_types: employmentTypes,
    p_position_ids: positionIds,
  })

// ------------------------------------------------ availability (011)
export interface AvailabilityDay {
  day_of_week: number
  is_available: boolean
  start_time: string | null
  end_time: string | null
}

export async function getMyAvailability(): Promise<ApiResult<{ confirmed_at: string | null; days: AvailabilityDay[] }>> {
  return callRpc<{ confirmed_at: string | null; days: AvailabilityDay[] }>('get_my_availability')
}

export const saveMyAvailability = (days: AvailabilityDay[]) => callRpc<{ ok: boolean }>('save_my_availability', { p_days: days })

// --------------------------------------------- work permit / visa (012)
export type ImmigrationTrack = 'outside_uae' | 'inside_uae' | 'transfer' | 'own_visa' | 'uae_national' | 'gcc_national'
export type ImmigrationStepStatus = 'not_started' | 'in_progress' | 'done' | 'not_needed' | 'failed'

export interface ImmigrationCase {
  id: string
  employee_id: string
  track: ImmigrationTrack
  status: 'open' | 'completed' | 'cancelled'
  mohre_person_code: string | null
  work_permit_number: string | null
  uid_number: string | null
  visa_file_number: string | null
  notes: string | null
  opened_at: string
  close_reason: string | null
}

export interface ImmigrationStep {
  id: string
  step_key: string
  label: string
  sort_order: number
  status: ImmigrationStepStatus
  is_blocking: boolean
  due_date: string | null
  completed_at: string | null
  reference_number: string | null
  expiry_date: string | null
  notes: string | null
  fee_amount: number | null
  fee_paid_by: 'company' | 'employee' | null
}

export interface ImmigrationCaseRow {
  case_id: string
  employee_id: string
  name: string
  track: ImmigrationTrack
  status: ImmigrationCase['status']
  opened_at: string
  onboarding_instance_id: string | null
  done: number
  total: number
  blocking_open: number
  overdue: number
  next_step: string | null
  next_due: string | null
}

export const getImmigrationCase = (employeeId: string) =>
  callRpc<{ ok: boolean; suggested_track: ImmigrationTrack; case: ImmigrationCase | null; steps: ImmigrationStep[] }>('get_immigration_case', {
    p_employee_id: employeeId,
  })

export const listImmigrationCases = (entityId: string, status: 'open' | 'completed' | 'cancelled' | 'all' = 'open') =>
  callRpc<ImmigrationCaseRow[]>('list_immigration_cases', { p_entity_id: entityId, p_status: status })

export const openImmigrationCase = (employeeId: string, track: ImmigrationTrack, notes: string | null) =>
  callRpc<{ ok: boolean; case_id: string }>('open_immigration_case', { p_employee_id: employeeId, p_track: track, p_notes: notes })

export const changeImmigrationTrack = (caseId: string, track: ImmigrationTrack, reason: string) =>
  callRpc<{ ok: boolean }>('change_immigration_track', { p_case_id: caseId, p_track: track, p_reason: reason })

export const updateImmigrationStep = (
  stepId: string,
  status: ImmigrationStepStatus,
  reference: string | null,
  expiryDate: string | null,
  dueDate: string | null,
  notes: string | null,
  feeAmount: number | null = null,
  feePaidBy: 'company' | 'employee' | null = null
) =>
  callRpc<{ ok: boolean }>('update_immigration_step', {
    p_step_id: stepId,
    p_status: status,
    p_reference: reference,
    p_expiry_date: expiryDate,
    p_due_date: dueDate,
    p_notes: notes,
    p_fee_amount: feeAmount,
    p_fee_paid_by: feePaidBy,
  })

export const setImmigrationStepBlocking = (stepId: string, blocking: boolean, reason: string) =>
  callRpc<{ ok: boolean }>('set_immigration_step_blocking', { p_step_id: stepId, p_is_blocking: blocking, p_reason: reason })

export const updateImmigrationCase = (caseId: string, patch: Partial<Pick<ImmigrationCase, 'mohre_person_code' | 'work_permit_number' | 'uid_number' | 'visa_file_number' | 'notes'>>) =>
  callRpc<{ ok: boolean }>('update_immigration_case', { p_case_id: caseId, p: patch })

export interface ImmigrationCostRow {
  employee_id: string
  name: string
  case_id: string
  company_paid: number
  employee_paid: number
}

// Company-paid vs employee-paid visa/work-permit fee totals, HR/payroll only.
export const immigrationCostSummary = (entityId: string, from?: string, to?: string) =>
  callRpc<ImmigrationCostRow[]>('immigration_cost_summary', { p_entity_id: entityId, p_from: from ?? null, p_to: to ?? null })

export const closeImmigrationCase = (caseId: string, status: 'completed' | 'cancelled', reason: string | null) =>
  callRpc<{ ok: boolean }>('close_immigration_case', { p_case_id: caseId, p_status: status, p_reason: reason })

export async function getMyImmigration(): Promise<ApiResult<{ label: string; status: ImmigrationStepStatus; completed_at: string | null }[] | null>> {
  const r = await callRpc<{ ok: boolean; steps: { label: string; status: ImmigrationStepStatus; completed_at: string | null }[] | null }>('get_my_immigration')
  return { data: r.data?.steps ?? null, error: r.error }
}
