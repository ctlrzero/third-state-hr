import { callRpc, unwrapOk } from './client'

// "Ask an employee for something" — see docs/API_CONTRACT.md § Employee requests.

export type EmployeeRequestKind = 'document' | 'payment_details' | 'profile_info'
export type ProfileRequestField = 'phone' | 'emergency_contact' | 'dob' | 'nationality' | 'residential_address'

export const PROFILE_REQUEST_FIELDS: { key: ProfileRequestField; label: string }[] = [
  { key: 'phone', label: 'Phone number' },
  { key: 'emergency_contact', label: 'Emergency contact' },
  { key: 'dob', label: 'Date of birth' },
  { key: 'nationality', label: 'Nationality' },
  { key: 'residential_address', label: 'Home address' },
]

export interface EmployeeRequestRow {
  id: string
  employee_id: string
  kind: EmployeeRequestKind
  doc_type: string | null
  fields: ProfileRequestField[] | null
  label: string
  note: string | null
  due_date: string | null
  status: 'open' | 'done' | 'cancelled'
  requested_by: string
  requested_by_name: string | null
  created_at: string
  closed_at: string | null
  is_overdue: boolean
  can_cancel: boolean
}

export interface MyEmployeeRequest {
  id: string
  kind: EmployeeRequestKind
  doc_type: string | null
  fields: ProfileRequestField[] | null
  label: string
  note: string | null
  due_date: string | null
  requested_by_name: string | null
  created_at: string
  is_overdue: boolean
}

export const createEmployeeRequest = (args: {
  employeeId: string
  kind: EmployeeRequestKind
  docType?: string | null
  fields?: ProfileRequestField[] | null
  note?: string | null
  dueDate?: string | null
}) =>
  callRpc<{ ok: boolean; id: string }>('create_employee_request', {
    p_employee_id: args.employeeId,
    p_kind: args.kind,
    p_doc_type: args.kind === 'document' ? args.docType ?? null : null,
    p_fields: args.kind === 'profile_info' ? args.fields ?? null : null,
    p_note: args.note?.trim() || null,
    p_due_date: args.dueDate || null,
  }).then(unwrapOk)

export const cancelEmployeeRequest = (requestId: string) =>
  callRpc<{ ok: boolean }>('cancel_employee_request', { p_request_id: requestId }).then(unwrapOk)

export const getEmployeeRequests = (employeeId: string, includeClosed = false) =>
  callRpc<EmployeeRequestRow[]>('get_employee_requests', { p_employee_id: employeeId, p_include_closed: includeClosed })

export const getMyEmployeeRequests = () => callRpc<MyEmployeeRequest[]>('get_my_employee_requests')

export interface ProfileInfoValues {
  phone?: string
  emergency_contact_name?: string
  emergency_contact_phone?: string
  dob?: string
  nationality?: string
  residential_address?: string
}

export const fillMyRequestedProfileInfo = (values: ProfileInfoValues) =>
  callRpc<{ ok: boolean; updated: string[]; still_open: number }>('fill_my_requested_profile_info', { p_values: values }).then(unwrapOk)

export type PaymentMethod = 'bank_transfer' | 'exchange_house' | 'wps_card' | 'cash'

export const PAYMENT_METHODS: { value: PaymentMethod; label: string }[] = [
  { value: 'bank_transfer', label: 'Bank account (IBAN)' },
  { value: 'wps_card', label: 'Salary card (WPS)' },
  { value: 'exchange_house', label: 'Exchange house' },
  { value: 'cash', label: 'Cash' },
]

export const submitRequestedPaymentDetails = (args: {
  method: PaymentMethod
  bankName?: string
  accountName?: string
  iban?: string
  routingCode?: string
}) =>
  callRpc<{ ok: boolean; id: string }>('submit_requested_payment_details', {
    p_method: args.method,
    p_bank_name: args.bankName?.trim() || null,
    p_account_name: args.accountName?.trim() || null,
    p_iban: args.iban?.trim() || null,
    p_routing_code: args.routingCode?.trim() || null,
  }).then(unwrapOk)

/** Where the employee goes to fulfil a request. */
export function requestActionRoute(r: { kind: EmployeeRequestKind; doc_type?: string | null }): string {
  // ?upload= opens the upload form for that document straight away.
  if (r.kind === 'document') return r.doc_type ? `/documents?upload=${encodeURIComponent(r.doc_type)}` : '/documents'
  if (r.kind === 'payment_details') return '/me#payment-details'
  return '/me#missing-details'
}

export function requestActionLabel(r: { kind: EmployeeRequestKind }): string {
  if (r.kind === 'document') return 'Upload document'
  if (r.kind === 'payment_details') return 'Add bank details'
  return 'Fill in details'
}

/** Ask one employee for everything that's missing (documents, bank details, personal details). */
export const requestAllMissing = (employeeId: string, note?: string | null, dueDate?: string | null) =>
  callRpc<{ ok: boolean; employee: string; created: string[]; skipped: { item: string; reason: string }[] }>('request_all_missing', {
    p_employee_id: employeeId,
    p_note: note?.trim() || null,
    p_due_date: dueDate || null,
  })

/** Same for everyone in a company (or one branch). Branch managers are limited to their own branch by the server. */
export const requestAllMissingForMany = (entityId: string, locationId?: string | null, note?: string | null, dueDate?: string | null) =>
  callRpc<{ ok: boolean; people: number; requests: number; skipped: number; names: string[] }>('request_all_missing_for_many', {
    p_entity_id: entityId,
    p_location_id: locationId ?? null,
    p_note: note?.trim() || null,
    p_due_date: dueDate || null,
  })
