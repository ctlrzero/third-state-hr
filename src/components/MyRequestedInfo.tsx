import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useLocation } from 'react-router-dom'
import { Alert, Field } from './ui'
import {
  PAYMENT_METHODS,
  fillMyRequestedProfileInfo,
  getMyEmployeeRequests,
  submitRequestedPaymentDetails,
  type MyEmployeeRequest,
  type PaymentMethod,
  type ProfileInfoValues,
} from '../lib/api/employeeRequests'
import { fmtDate } from '../lib/format'

// My profile: the forms for "missing information" and "bank / payment
// details" requests. Only shown while such a request is open; the Home
// screen button links here with #missing-details or #payment-details.
export default function MyRequestedInfo({ onSaved }: { onSaved?: () => void }) {
  const [rows, setRows] = useState<MyEmployeeRequest[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const location = useLocation()

  async function load() {
    const res = await getMyEmployeeRequests()
    if (res.error) setError(res.error)
    else setRows(res.data ?? [])
  }

  useEffect(() => {
    load()
  }, [])

  useEffect(() => {
    if (!rows || !location.hash) return
    const el = document.getElementById(location.hash.slice(1))
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [rows, location.hash])

  const profileReq = rows?.find((r) => r.kind === 'profile_info')
  const paymentReq = rows?.find((r) => r.kind === 'payment_details')

  function saved(msg: string) {
    setDone(msg)
    load()
    onSaved?.()
  }

  return (
    <>
      {error && <Alert tone="error">{error}</Alert>}
      {done && (
        <Alert tone="success" onDismiss={() => setDone(null)}>
          {done}
        </Alert>
      )}
      {profileReq && <ProfileInfoForm request={profileReq} onSaved={saved} />}
      {paymentReq && <PaymentDetailsForm request={paymentReq} onSaved={saved} />}
    </>
  )
}

function RequestIntro({ request }: { request: MyEmployeeRequest }) {
  return (
    <p className="text-sm text-muted">
      {request.requested_by_name ?? 'Your manager'} asked for this
      {request.due_date ? ` — please do it by ${fmtDate(request.due_date)}` : ''}.
      {request.note && <span className="mt-1 block text-ink">“{request.note}”</span>}
    </p>
  )
}

function ProfileInfoForm({ request, onSaved }: { request: MyEmployeeRequest; onSaved: (msg: string) => void }) {
  const fields = request.fields ?? []
  const [values, setValues] = useState<ProfileInfoValues>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const ref = useRef<HTMLElement>(null)
  const set = (k: keyof ProfileInfoValues) => (e: { target: { value: string } }) => setValues((v) => ({ ...v, [k]: e.target.value }))

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    const res = await fillMyRequestedProfileInfo(values)
    setBusy(false)
    if (res.error) setError(res.error)
    else onSaved(res.data && res.data.still_open > 0 ? 'Saved. Some details are still missing — please fill them in too.' : 'Thank you! Your details are saved.')
  }

  return (
    <section id="missing-details" ref={ref} className="card scroll-mt-20 space-y-3 border-brand-warning/50" aria-labelledby="missing-details-h">
      <h2 id="missing-details-h" className="text-base font-semibold text-ink">
        Please fill in your missing details
      </h2>
      <RequestIntro request={request} />
      <form onSubmit={submit} className="space-y-3">
        {fields.includes('phone') && (
          <Field label="Your phone number" hint="For example +971 50 123 4567">
            {(p) => <input {...p} type="tel" inputMode="tel" autoComplete="tel" className="input min-h-11" value={values.phone ?? ''} onChange={set('phone')} />}
          </Field>
        )}
        {fields.includes('emergency_contact') && (
          <>
            <Field label="Emergency contact name" hint="Someone we can call if something happens to you">
              {(p) => <input {...p} className="input min-h-11" value={values.emergency_contact_name ?? ''} onChange={set('emergency_contact_name')} />}
            </Field>
            <Field label="Emergency contact phone">
              {(p) => <input {...p} type="tel" inputMode="tel" className="input min-h-11" value={values.emergency_contact_phone ?? ''} onChange={set('emergency_contact_phone')} />}
            </Field>
          </>
        )}
        {fields.includes('dob') && (
          <Field label="Date of birth">
            {(p) => <input {...p} type="date" autoComplete="bday" className="input min-h-11" value={values.dob ?? ''} onChange={set('dob')} />}
          </Field>
        )}
        {fields.includes('nationality') && (
          <Field label="Nationality" hint="For example Indian, Filipino, Egyptian">
            {(p) => <input {...p} className="input min-h-11" value={values.nationality ?? ''} onChange={set('nationality')} />}
          </Field>
        )}
        {fields.includes('residential_address') && (
          <Field label="Home address in the UAE">
            {(p) => <textarea {...p} rows={2} autoComplete="street-address" className="input" value={values.residential_address ?? ''} onChange={set('residential_address')} />}
          </Field>
        )}
        {error && <Alert tone="error">{error}</Alert>}
        <button type="submit" className="btn-primary min-h-11 w-full sm:w-auto" disabled={busy}>
          {busy ? 'Saving…' : 'Save my details'}
        </button>
      </form>
    </section>
  )
}

function PaymentDetailsForm({ request, onSaved }: { request: MyEmployeeRequest; onSaved: (msg: string) => void }) {
  const [method, setMethod] = useState<PaymentMethod>('bank_transfer')
  const [bankName, setBankName] = useState('')
  const [accountName, setAccountName] = useState('')
  const [iban, setIban] = useState('')
  const [routingCode, setRoutingCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const needsIban = method === 'bank_transfer'

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    if (needsIban && !iban.trim()) {
      setError('Please enter your IBAN.')
      return
    }
    setBusy(true)
    const res = await submitRequestedPaymentDetails({ method, bankName, accountName, iban, routingCode })
    setBusy(false)
    if (res.error) setError(res.error)
    else onSaved('Thank you! Your bank details are sent. Payroll will check them before pay day.')
  }

  return (
    <section id="payment-details" className="card scroll-mt-20 space-y-3 border-brand-warning/50" aria-labelledby="payment-details-h">
      <h2 id="payment-details-h" className="text-base font-semibold text-ink">
        Your bank / payment details
      </h2>
      <RequestIntro request={request} />
      <form onSubmit={submit} className="space-y-3">
        <Field label="How do you want to be paid?" required>
          {(p) => (
            <select {...p} className="input min-h-11" value={method} onChange={(e) => setMethod(e.target.value as PaymentMethod)}>
              {PAYMENT_METHODS.map((m) => (
                <option key={m.value} value={m.value}>
                  {m.label}
                </option>
              ))}
            </select>
          )}
        </Field>
        {method !== 'cash' && (
          <>
            <Field label={method === 'exchange_house' ? 'Exchange house name' : 'Bank name'}>
              {(p) => <input {...p} className="input min-h-11" value={bankName} onChange={(e) => setBankName(e.target.value)} />}
            </Field>
            <Field label="Name on the account">
              {(p) => <input {...p} autoComplete="name" className="input min-h-11" value={accountName} onChange={(e) => setAccountName(e.target.value)} />}
            </Field>
            <Field label={needsIban ? 'IBAN' : 'IBAN (if you have one)'} required={needsIban} hint="Starts with AE and has 23 characters. Spaces are OK.">
              {(p) => (
                <input
                  {...p}
                  className="input min-h-11 font-mono uppercase"
                  autoCapitalize="characters"
                  spellCheck={false}
                  value={iban}
                  onChange={(e) => setIban(e.target.value)}
                />
              )}
            </Field>
            {method !== 'bank_transfer' && (
              <Field label="Card or routing number (optional)">
                {(p) => <input {...p} className="input min-h-11" value={routingCode} onChange={(e) => setRoutingCode(e.target.value)} />}
              </Field>
            )}
          </>
        )}
        <p className="text-xs text-muted">Any bank details you sent before will be replaced by these.</p>
        {error && <Alert tone="error">{error}</Alert>}
        <button type="submit" className="btn-primary min-h-11 w-full sm:w-auto" disabled={busy}>
          {busy ? 'Sending…' : 'Send bank details'}
        </button>
      </form>
    </section>
  )
}
