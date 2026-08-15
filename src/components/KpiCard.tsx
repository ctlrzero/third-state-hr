import type { ReactNode } from 'react'

interface KpiCardProps {
  label: string
  value: ReactNode
  hint?: string
  tone?: 'default' | 'warning' | 'risk'
  icon?: ReactNode
  loading?: boolean
  onClick?: () => void
}

const ICON_CHIP_TONE: Record<NonNullable<KpiCardProps['tone']>, string> = {
  default: 'bg-brand-blue-soft text-brand-blue-text',
  warning: 'bg-brand-warning-soft text-brand-warning-solid',
  risk: 'bg-brand-risk-soft text-brand-risk-text',
}

// Card recipe matches the reference build: white card, 1px #e3e8ef border,
// 14px radius, soft ambient shadow (0 10px 30px rgba(28,39,51,.05)).
export function KpiCard({ label, value, hint, tone = 'default', icon, loading, onClick }: KpiCardProps) {
  const valueTone =
    tone === 'warning' ? 'text-brand-warning-solid' : tone === 'risk' ? 'text-brand-risk-text' : 'text-ink'

  const Wrapper = onClick ? 'button' : 'div'

  return (
    <Wrapper
      onClick={onClick}
      className={`flex flex-col gap-3 rounded-[14px] border border-border bg-surface p-[18px] text-left shadow-card ${
        onClick ? 'transition hover:border-brand-blue/30' : ''
      }`}
    >
      <div className="flex items-center gap-3">
        {icon && (
          <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full ${ICON_CHIP_TONE[tone]}`}>
            {icon}
          </span>
        )}
        {loading ? (
          <span className="h-8 w-16 animate-pulse rounded bg-surface-alt" />
        ) : (
          <span className={`text-[26px] font-semibold ${valueTone}`}>{value}</span>
        )}
      </div>
      <div>
        <p className="text-sm text-muted">{label}</p>
        {hint && <p className="mt-2 text-xs text-muted">{hint}</p>}
      </div>
    </Wrapper>
  )
}
