import { addDays, todayDubai } from './format'
import type { UserRole } from '../types/db'

export const DOC_TYPES = [
  { value: 'passport', label: 'Passport' },
  { value: 'visa', label: 'Visa' },
  { value: 'labor_card', label: 'Labor card' },
  { value: 'health_card', label: 'Health card' },
  { value: 'emirates_id', label: 'Emirates ID' },
  { value: 'offer_letter', label: 'Offer letter' },
  { value: 'contract', label: 'Contract' },
  { value: 'bank_payment_document', label: 'Bank / payment document' },
  { value: 'compensation_document', label: 'Salary / compensation evidence' },
  { value: 'other', label: 'Other' },
] as const

export type DocType = (typeof DOC_TYPES)[number]['value']

// Mirrors the DB helper public.is_restricted_doc_type() — the "sensitive"
// document set. These are withheld from location_manager entirely (table
// RLS / storage RLS / this UI) and always require Owner or Entity Admin
// approval, never a location_manager, and never an Entity Admin's own
// self-approval regardless of the entity_admin_self_approval_enabled
// setting. UI-side is belt-and-suspenders — RLS/triggers are what actually
// enforce it.
export const RESTRICTED_DOC_TYPES: readonly string[] = [
  'passport',
  'emirates_id',
  'visa',
  'contract',
  'offer_letter',
  'bank_payment_document',
  'compensation_document',
]

export function isRestrictedDocType(docType: string): boolean {
  return RESTRICTED_DOC_TYPES.includes(docType)
}

export function canRoleSeeDocType(role: UserRole | undefined, docType: string): boolean {
  if (role === 'location_manager') return !isRestrictedDocType(docType)
  return true
}

// Mirrors the DB helper public.can_review_document(): who may approve a
// document submitted by someone in `submitterRole`, given the reviewer's
// own role and (for entity_admin self-approval) whether the owner has
// turned that setting on. This is UI-only guidance to hide/disable actions
// that would be rejected anyway — the database trigger is authoritative.
export function canRoleApprove(
  submitterRole: UserRole | undefined,
  reviewerRole: UserRole | undefined,
  docType: string,
  entityAdminSelfApprovalEnabled: boolean,
  isSelf: boolean
): boolean {
  if (reviewerRole === 'owner') return true
  const sensitive = isRestrictedDocType(docType)

  if (submitterRole === 'staff' || submitterRole === 'shift_supervisor') {
    if (isSelf) return false
    if (reviewerRole === 'entity_admin') return true
    if (reviewerRole === 'location_manager') return !sensitive
    return false
  }
  if (submitterRole === 'location_manager') {
    return reviewerRole === 'entity_admin'
  }
  if (submitterRole === 'entity_admin') {
    if (sensitive) return false
    if (isSelf) return reviewerRole === 'entity_admin' && entityAdminSelfApprovalEnabled
    return false
  }
  // submitterRole === 'owner': only the owner may approve, and that case was
  // already handled by the reviewerRole === 'owner' check above.
  return false
}

export type ExpiryStatus = 'expired' | 'expiring' | 'current' | 'non_expiring'

/** Days before expiry that a document counts as "expiring" — matches the first renewal reminder (P2-5). */
export const EXPIRING_WINDOW_DAYS = 60

/**
 * Expiry status is always computed from expiry_date, never stored — kept
 * completely separate from review_status (the approval workflow state).
 * Dates are compared as Dubai calendar days.
 *   expired:      expiry_date < today
 *   expiring:     today <= expiry_date <= today + 60 days (staff can upload a new copy)
 *   current:      expiry_date > today + 60 days
 *   non_expiring: expiry_date is null
 */
export function expiryStatus(expiryDate: string | null, today: Date = new Date()): ExpiryStatus {
  if (!expiryDate) return 'non_expiring'
  const todayStr = todayDubai(today)
  const limitStr = addDays(todayStr, EXPIRING_WINDOW_DAYS)
  if (expiryDate < todayStr) return 'expired'
  if (expiryDate <= limitStr) return 'expiring'
  return 'current'
}

export function docTypeLabel(docType: string): string {
  return DOC_TYPES.find((t) => t.value === docType)?.label ?? docType.replace(/_/g, ' ')
}

/**
 * Label for a code in get_employee_completeness().missing: key-document codes
 * arrive as "<doc_type>_document" (e.g. "emirates_id_document" → "Emirates ID");
 * everything else ("emergency_contact", "join_date") is humanised.
 */
export type DocumentRequirementStatus = 'missing' | 'pending_review' | 'approved' | 'rejected' | 'expiring' | 'archived' | 'waived'

export interface DocumentRequirement {
  id: string
  employee_id: string
  doc_type: string
  status: DocumentRequirementStatus
  is_restricted: boolean
  document_id: string | null
  document_review_status: string | null
  document_expiry_date: string | null
  document_upload_method: string | null
  document_uploaded_by: string | null
  waived_reason: string | null
  waived_at: string | null
  created_at: string
  updated_at: string
}

export const REQ_STATUS_LABEL: Record<DocumentRequirementStatus, string> = {
  missing: 'Missing',
  pending_review: 'Pending review',
  approved: 'Approved',
  rejected: 'Rejected',
  expiring: 'Expiring',
  archived: 'Archived',
  waived: 'Waived',
}

export function completenessItemLabel(code: string): string {
  const docType = code.replace(/_document$/, '')
  const known = DOC_TYPES.find((t) => t.value === docType)
  if (known) return known.label
  const s = code.replace(/_/g, ' ')
  return s.charAt(0).toUpperCase() + s.slice(1)
}
