import { daysBetween } from './onboarding'

// Offboarding display helpers + a client mirror of the server's minimum
// notice rule (public._off_min_notice_days) so the form can warn before
// saving. The server decides.

export type SeparationType =
  | 'resignation'
  | 'termination'
  | 'dismissal_art44'
  | 'end_of_contract'
  | 'mutual_agreement'
  | 'probation_not_confirmed'
  | 'no_show'
  | 'retirement'
  | 'death'
  | 'other'
export type InitiatedBy = 'employee' | 'employer' | 'mutual' | 'none'

export const SEPARATION_LABEL: Record<SeparationType, string> = {
  resignation: 'Resignation',
  termination: 'Termination with notice',
  dismissal_art44: 'Dismissal without notice (Art. 44)',
  end_of_contract: 'End of limited contract',
  mutual_agreement: 'Mutual agreement',
  probation_not_confirmed: 'Probation not confirmed',
  no_show: 'Did not start / no-show',
  retirement: 'Retirement',
  death: 'Death in service',
  other: 'Other',
}

/** Who ended it, implied by the type (the form still lets HR change it). */
export function defaultInitiatedBy(t: SeparationType): InitiatedBy {
  if (t === 'resignation' || t === 'retirement') return 'employee'
  if (t === 'mutual_agreement') return 'mutual'
  if (t === 'death' || t === 'end_of_contract') return 'none'
  return 'employer'
}

/**
 * Minimum notice in days (Federal Decree-Law 33/2021):
 *  probation — employer 14 days (Art. 9(1)); employee 14 days if leaving the
 *  UAE, one month if joining another UAE employer (Art. 9(2)–(3));
 *  after probation at least 30 days (Art. 43). No notice for Art. 44
 *  dismissal, end of a limited contract, mutual agreement, death, no-show.
 */
export function minNoticeDays(t: SeparationType, by: InitiatedBy, inProbation: boolean, leavingUae: boolean): number {
  if (['no_show', 'death', 'dismissal_art44', 'end_of_contract', 'mutual_agreement'].includes(t)) return 0
  if (t === 'probation_not_confirmed') return 14
  if (inProbation && by === 'employer') return 14
  if (inProbation && by === 'employee') return leavingUae ? 14 : 30
  return 30
}

export function noticeDays(noticeDate: string, lastDay: string): number {
  return daysBetween(noticeDate, lastDay)
}

/** Final settlement is due within 14 days of the last working day (Art. 53). */
export function settlementDue(lastDay: string): string {
  const d = new Date(lastDay + 'T12:00:00Z')
  d.setUTCDate(d.getUTCDate() + 14)
  return d.toISOString().slice(0, 10)
}

export const OFF_OWNER_LABEL = { location_manager: 'Branch manager', hr: 'HR', payroll: 'Payroll' } as const
