type Tone = 'neutral' | 'info' | 'warning' | 'risk' | 'success'

// Soft-pill badges: tint background + a darker stop of the same ramp for
// text, no border, no dot — matching the reference build's `.status.teal`
// pattern (bg #e8f8f6 / text #087f73, radius 999px).
const TONE_CLASSES: Record<Tone, string> = {
  neutral: 'bg-surface-alt text-muted',
  info: 'bg-brand-info-soft text-brand-info-text',
  warning: 'bg-brand-warning-soft text-brand-warning-solid',
  risk: 'bg-brand-risk-soft text-brand-risk-text',
  success: 'bg-brand-action-soft text-brand-action-text',
}

// Status vocabulary kept consistent with UI/UX Spec section 4.1 / 8:
// Draft, Pending Review, Published, Adjusted, Approved, Rejected, Expired, Inactive, etc.
const STATUS_TONE: Record<string, Tone> = {
  draft: 'neutral',
  pending: 'warning',
  pending_review: 'warning',
  pending_activation: 'warning',
  expiring: 'warning',
  in_review: 'warning',
  submitted: 'info',
  published: 'success',
  approved: 'success',
  active: 'success',
  current: 'success',
  paid: 'success',
  claimed: 'info',
  adjusted: 'info',
  open: 'info',
  rejected: 'risk',
  expired: 'risk',
  cancelled: 'neutral',
  inactive: 'neutral',
  candidate: 'neutral',
  pre_boarding: 'info',
  superseded: 'neutral',
  archived: 'neutral',
  non_expiring: 'neutral',
}

function label(status: string) {
  return status
    .split('_')
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ')
}

export function StatusBadge({ status, tone }: { status: string; tone?: Tone }) {
  const resolvedTone = tone ?? STATUS_TONE[status.toLowerCase()] ?? 'neutral'
  return (
    <span
      className={`inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold ${TONE_CLASSES[resolvedTone]}`}
    >
      {label(status)}
    </span>
  )
}
