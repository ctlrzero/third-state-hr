import { useEffect, useState } from 'react'
import { Alert, Drawer, Skeleton } from '../../components/ui'
import { supabase } from '../../lib/supabase'
import { adminListUserAccess, type UserAccessRow } from '../../lib/api/admin'
import { getSettings, saveSettings, setPermission, setRolePoints, type PayrollSettings } from '../../lib/api/payroll'
import { PAYMENT_METHODS } from './options'

// Company payroll setup. Values are effective-dated: saving creates (or
// replaces) the policy from the chosen month. Legal minimums are enforced
// by the server; everything else is the company's choice.
export default function SettingsDrawer({ entityId, onClose, onChanged }: { entityId: string; onClose: () => void; onChanged: () => void }) {
  const [s, setS] = useState<PayrollSettings | null>(null)
  const [from, setFrom] = useState(new Date().toISOString().slice(0, 7))
  const [err, setErr] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [positions, setPositions] = useState<{ id: string; title: string; points: number | null }[]>([])
  const [users, setUsers] = useState<UserAccessRow[]>([])
  const [perms, setPerms] = useState<{ user_id: string; preset: string; can_single_step_approve: boolean }[]>([])

  async function load() {
    const res = await getSettings(entityId)
    if (res.error) setErr(res.error)
    setS(res.data)
    const [p, pts, pm] = await Promise.all([
      supabase.from('positions').select('id, title').eq('entity_id', entityId).order('title'),
      supabase.from('tip_role_points').select('position_id, points'),
      supabase.from('payroll_permissions').select('user_id, preset, can_single_step_approve').eq('entity_id', entityId),
    ])
    const map = new Map(((pts.data ?? []) as { position_id: string; points: number }[]).map((x) => [x.position_id, x.points]))
    setPositions(((p.data ?? []) as { id: string; title: string }[]).map((x) => ({ ...x, points: map.get(x.id) ?? null })))
    setPerms((pm.data ?? []) as typeof perms)
    const u = await adminListUserAccess(entityId)
    setUsers((u.data ?? []).filter((x: UserAccessRow) => x.user_id && !x.is_pending))
  }
  useEffect(() => {
    load()
  }, [entityId]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!s) {
    return (
      <Drawer open wide title="Payroll settings" onClose={onClose}>
        {err ? <Alert tone="error">{err}</Alert> : <Skeleton rows={5} className="h-10" />}
      </Drawer>
    )
  }
  const edit = s.can_edit
  const set = <K extends keyof PayrollSettings>(k: K, v: PayrollSettings[K]) => (setS({ ...s, [k]: v }), setSaved(false))

  return (
    <Drawer
      open
      wide
      title="Payroll settings"
      description="Applies from the month you choose; earlier months keep their own settings."
      onClose={onClose}
      footer={
        edit ? (
          <button
            className="btn-primary"
            onClick={async () => {
              setErr(null)
              const res = await saveSettings(entityId, `${from}-01`, {
                pay_day: s.pay_day,
                day_rate_basis: s.day_rate_basis,
                approval_mode: s.approval_mode,
                unpaid_leave_basis: s.unpaid_leave_basis,
                overtime_multiplier: s.overtime_multiplier,
                night_overtime_multiplier: s.night_overtime_multiplier,
                holiday_multiplier: s.holiday_multiplier,
                max_deduction_pct: s.max_deduction_pct,
                default_payment_method: s.default_payment_method,
                payslip_note: s.payslip_note,
              })
              if (res.error) return setErr(res.error)
              setSaved(true)
              onChanged()
            }}
          >
            Save settings
          </button>
        ) : undefined
      }
    >
      <div className="space-y-5">
        {err && (
          <Alert tone="error" onDismiss={() => setErr(null)}>
            {err}
          </Alert>
        )}
        {saved && <Alert tone="success">Saved.</Alert>}
        {!s.confirmed && <Alert tone="info">These are the defaults. Review and save to confirm them.</Alert>}

        <fieldset disabled={!edit} className="grid gap-3 sm:grid-cols-2">
          <label>
            <span className="label">Applies from</span>
            <input type="month" className="input" value={from} onChange={(e) => setFrom(e.target.value)} />
          </label>
          <label>
            <span className="label">Pay day (of the following month)</span>
            <input className="input" inputMode="numeric" value={s.pay_day} onChange={(e) => set('pay_day', Number(e.target.value))} />
            <span className="mt-1 block text-xs text-muted">
              Legal: WPS wages are due on the 1st of the next month (Ministerial Resolution 340/2026).
            </span>
          </label>
          <label>
            <span className="label">Day rate for proration and unpaid leave</span>
            <select className="input" value={s.day_rate_basis} onChange={(e) => set('day_rate_basis', e.target.value as PayrollSettings['day_rate_basis'])}>
              <option value="calendar_days">Calendar days in the month</option>
              <option value="fixed_30">Fixed 30-day month</option>
            </select>
            <span className="mt-1 block text-xs text-muted">Company choice; the law sets no formula.</span>
          </label>
          <label>
            <span className="label">Unpaid-leave day includes</span>
            <select className="input" value={s.unpaid_leave_basis} onChange={(e) => set('unpaid_leave_basis', e.target.value as PayrollSettings['unpaid_leave_basis'])}>
              <option value="basic_and_allowances">Basic + allowances</option>
              <option value="basic">Basic only</option>
            </select>
          </label>
          <label className="sm:col-span-2">
            <span className="label">Approval</span>
            <select className="input" value={s.approval_mode} onChange={(e) => set('approval_mode', e.target.value as PayrollSettings['approval_mode'])}>
              <option value="two_step">Two people: one prepares, another approves</option>
              <option value="review_then_approve">Prepare → review → approve</option>
              <option value="owner_single_step" disabled={!s.is_owner}>
                Owner may prepare and approve alone{!s.is_owner ? ' (owner only)' : ''}
              </option>
            </select>
          </label>
          <label>
            <span className="label">Overtime rate (× basic hourly)</span>
            <input className="input" inputMode="decimal" value={s.overtime_multiplier} onChange={(e) => set('overtime_multiplier', Number(e.target.value))} />
            <span className="mt-1 block text-xs text-muted">Legal minimum 1.25 (Art. 19).</span>
          </label>
          <label>
            <span className="label">Night overtime 10pm–4am</span>
            <input className="input" inputMode="decimal" value={s.night_overtime_multiplier} onChange={(e) => set('night_overtime_multiplier', Number(e.target.value))} />
            <span className="mt-1 block text-xs text-muted">Legal minimum 1.50; shift workers excluded (Art. 19).</span>
          </label>
          <label>
            <span className="label">Rest day / public holiday work</span>
            <input className="input" inputMode="decimal" value={s.holiday_multiplier} onChange={(e) => set('holiday_multiplier', Number(e.target.value))} />
            <span className="mt-1 block text-xs text-muted">Legal minimum 1.50 or a substitute day off (Arts. 19, 28).</span>
          </label>
          <label>
            <span className="label">Deduction limit (% of pay)</span>
            <input className="input" inputMode="decimal" value={s.max_deduction_pct} onChange={(e) => set('max_deduction_pct', Number(e.target.value))} />
            <span className="mt-1 block text-xs text-muted">Legal maximum 50% (Art. 25).</span>
          </label>
          <label>
            <span className="label">Usual payment method</span>
            <select className="input" value={s.default_payment_method} onChange={(e) => set('default_payment_method', e.target.value as PayrollSettings['default_payment_method'])}>
              {PAYMENT_METHODS.map((m) => (
                <option key={m.value} value={m.value}>
                  {m.label}
                </option>
              ))}
            </select>
          </label>
          <label className="sm:col-span-2">
            <span className="label">Note printed on payslips</span>
            <input className="input" value={s.payslip_note ?? ''} onChange={(e) => set('payslip_note', e.target.value)} />
          </label>
        </fieldset>

        <section>
          <h3 className="mb-2 text-sm font-semibold text-ink">Tip role points</h3>
          <p className="mb-2 text-xs text-muted">Used by the role-points and hours × points tip splits. Positions without points count as 1.</p>
          <ul className="grid gap-2 sm:grid-cols-2">
            {positions.map((p) => (
              <li key={p.id} className="flex items-center gap-2">
                <span className="flex-1 text-sm">{p.title}</span>
                <input
                  className="input w-24"
                  aria-label={`${p.title} points`}
                  inputMode="decimal"
                  disabled={!edit}
                  defaultValue={p.points ?? ''}
                  onBlur={async (e) => {
                    const v = e.target.value.trim()
                    const res = await setRolePoints(p.id, v ? Number(v) : null)
                    if (res.error) setErr(res.error)
                  }}
                />
              </li>
            ))}
          </ul>
        </section>

        <section>
          <h3 className="mb-2 text-sm font-semibold text-ink">Payroll access</h3>
          <p className="mb-2 text-xs text-muted">
            Owner and entity admins always have full payroll access. Branch managers can enter hours and tips for their branch without seeing salaries.
            Grant an accountant access to reports and payments, or make someone a payroll admin.
          </p>
          <ul className="space-y-2">
            {users
              .filter((u) => u.role === 'staff' || u.role === 'location_manager')
              .map((u) => {
                const p = perms.find((x) => x.user_id === u.user_id)
                return (
                  <li key={u.user_id} className="flex flex-wrap items-center gap-2 text-sm">
                    <span className="flex-1">
                      {u.full_name ?? u.email} <span className="text-xs text-muted">({u.role.replace('_', ' ')})</span>
                    </span>
                    <select
                      className="input w-44"
                      aria-label={`Payroll access for ${u.full_name ?? u.email}`}
                      disabled={!edit}
                      value={p?.preset ?? ''}
                      onChange={async (e) => {
                        const v = (e.target.value || null) as 'payroll_admin' | 'accountant' | null
                        const res = await setPermission(u.user_id!, entityId, v, false)
                        if (res.error) setErr(res.error)
                        load()
                      }}
                    >
                      <option value="">No payroll access</option>
                      <option value="accountant">Accountant</option>
                      <option value="payroll_admin">Payroll admin</option>
                    </select>
                    {s.is_owner && p && (
                      <label className="flex items-center gap-1 text-xs">
                        <input
                          type="checkbox"
                          checked={p.can_single_step_approve}
                          onChange={async (e) => {
                            const res = await setPermission(u.user_id!, entityId, p.preset as 'payroll_admin' | 'accountant', e.target.checked)
                            if (res.error) setErr(res.error)
                            load()
                          }}
                        />
                        May approve own preparation
                      </label>
                    )}
                  </li>
                )
              })}
          </ul>
        </section>

        <section className="rounded-lg bg-surface-alt p-3 text-xs text-muted">
          <p className="font-semibold text-ink">Not configured yet</p>
          <ul className="mt-1 list-disc pl-4">
            <li>WPS salary file (SIF): needs your bank’s or exchange agent’s specification, employer MOHRE ID and each employee’s IBAN / routing code. Until then use the payment list.</li>
            <li>Pension contributions for UAE / GCC nationals (GPSSA): not calculated; add as deductions if needed.</li>
          </ul>
        </section>
      </div>
    </Drawer>
  )
}
