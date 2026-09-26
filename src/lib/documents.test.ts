import { describe, expect, it } from 'vitest'
import { canRoleApprove, canRoleSeeDocType, completenessItemLabel, docTypeLabel, expiryStatus, isRestrictedDocType } from './documents'

describe('expiryStatus', () => {
  const today = new Date('2026-08-13T12:00:00Z')

  it('treats a null expiry_date as non_expiring', () => {
    expect(expiryStatus(null, today)).toBe('non_expiring')
  })

  it('treats a past date as expired', () => {
    expect(expiryStatus('2026-08-12', today)).toBe('expired')
  })

  it('treats today itself as expiring, not expired', () => {
    expect(expiryStatus('2026-08-13', today)).toBe('expiring')
  })

  it('treats exactly 30 days out as expiring (inclusive boundary)', () => {
    expect(expiryStatus('2026-09-12', today)).toBe('expiring')
  })

  it('treats 31 days out as current', () => {
    expect(expiryStatus('2026-09-13', today)).toBe('current')
  })

  it('treats a far-future date as current', () => {
    expect(expiryStatus('2030-01-01', today)).toBe('current')
  })
})

describe('isRestrictedDocType / canRoleSeeDocType', () => {
  it('flags the full sensitive set as restricted', () => {
    for (const t of [
      'passport',
      'emirates_id',
      'visa',
      'contract',
      'offer_letter',
      'bank_payment_document',
      'compensation_document',
    ]) {
      expect(isRestrictedDocType(t)).toBe(true)
    }
  })

  it('does not flag operational document types', () => {
    for (const t of ['labor_card', 'health_card', 'other']) {
      expect(isRestrictedDocType(t)).toBe(false)
    }
  })

  it('blocks location_manager from sensitive types', () => {
    expect(canRoleSeeDocType('location_manager', 'contract')).toBe(false)
    expect(canRoleSeeDocType('location_manager', 'offer_letter')).toBe(false)
    expect(canRoleSeeDocType('location_manager', 'passport')).toBe(false)
    expect(canRoleSeeDocType('location_manager', 'emirates_id')).toBe(false)
    expect(canRoleSeeDocType('location_manager', 'visa')).toBe(false)
    expect(canRoleSeeDocType('location_manager', 'bank_payment_document')).toBe(false)
    expect(canRoleSeeDocType('location_manager', 'compensation_document')).toBe(false)
    expect(canRoleSeeDocType('location_manager', 'labor_card')).toBe(true)
  })

  it('does not restrict owner, entity_admin or staff', () => {
    for (const role of ['owner', 'entity_admin', 'staff'] as const) {
      expect(canRoleSeeDocType(role, 'contract')).toBe(true)
      expect(canRoleSeeDocType(role, 'offer_letter')).toBe(true)
      expect(canRoleSeeDocType(role, 'passport')).toBe(true)
    }
  })
})

describe('canRoleApprove', () => {
  it('lets owner approve anything', () => {
    expect(canRoleApprove('staff', 'owner', 'passport', false, false)).toBe(true)
    expect(canRoleApprove('entity_admin', 'owner', 'passport', false, false)).toBe(true)
    expect(canRoleApprove('location_manager', 'owner', 'labor_card', false, false)).toBe(true)
  })

  it('never lets a submitter approve their own document', () => {
    expect(canRoleApprove('staff', 'staff', 'labor_card', false, true)).toBe(false)
    expect(canRoleApprove('entity_admin', 'entity_admin', 'labor_card', true, true)).toBe(true) // only when flag is on
    expect(canRoleApprove('entity_admin', 'entity_admin', 'labor_card', false, true)).toBe(false)
  })

  it('employee upload: entity_admin always, location_manager only if not sensitive', () => {
    expect(canRoleApprove('staff', 'entity_admin', 'passport', false, false)).toBe(true)
    expect(canRoleApprove('staff', 'location_manager', 'labor_card', false, false)).toBe(true)
    expect(canRoleApprove('staff', 'location_manager', 'passport', false, false)).toBe(false)
  })

  it('location_manager upload: only entity_admin (or owner) may approve, never another location_manager', () => {
    expect(canRoleApprove('location_manager', 'entity_admin', 'labor_card', false, false)).toBe(true)
    expect(canRoleApprove('location_manager', 'location_manager', 'labor_card', false, false)).toBe(false)
  })

  it('entity_admin upload of a sensitive type always needs owner, never self', () => {
    expect(canRoleApprove('entity_admin', 'entity_admin', 'contract', true, true)).toBe(false)
    expect(canRoleApprove('entity_admin', 'owner', 'contract', true, false)).toBe(true)
  })
})

describe('docTypeLabel', () => {
  it('maps known types to their display label', () => {
    expect(docTypeLabel('labor_card')).toBe('Labor card')
    expect(docTypeLabel('emirates_id')).toBe('Emirates ID')
  })

  it('falls back to a humanised version of unknown types', () => {
    expect(docTypeLabel('some_new_type')).toBe('some new type')
  })
})

describe('completenessItemLabel', () => {
  it('labels key-document codes with the document display label', () => {
    expect(completenessItemLabel('emirates_id_document')).toBe('Emirates ID')
    expect(completenessItemLabel('passport_document')).toBe('Passport')
  })

  it('humanises non-document items', () => {
    expect(completenessItemLabel('emergency_contact')).toBe('Emergency contact')
    expect(completenessItemLabel('join_date')).toBe('Join date')
  })
})
