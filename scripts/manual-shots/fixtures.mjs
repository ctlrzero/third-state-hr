// Fictional sample data for the end-user manual screenshots.
// Test-only: served to the browser by mock.mjs via Playwright routing.
// "Today" is Sat 26 Sep 2026 (Asia/Dubai).

const u = (prefix, n) => `00000000-0000-4000-8000-${prefix}${String(n).padStart(12 - prefix.length, '0')}`

export const TODAY = '2026-09-26'

// ---------- ids ----------
export const ID = {
  entTS: u('e', 1),
  entAT: u('e', 2),
  locExpo: u('10', 1),
  locCorp: u('10', 2),
  locShj: u('10', 3),
  posBarista: u('20', 1),
  posSenior: u('20', 2),
  posLead: u('20', 3),
  posTea: u('20', 4),
  posSeniorAT: u('20', 5),
  // employees
  maria: u('ee', 1),
  omar: u('ee', 2),
  priya: u('ee', 3),
  joseph: u('ee', 4),
  ahmed: u('ee', 5),
  noura: u('ee', 6),
  fatima: u('ee', 7),
  arjun: u('ee', 8),
  // auth users
  uOwner: u('aa', 1),
  uOmar: u('aa', 2),
  uMaria: u('aa', 3),
  uPriya: u('aa', 4),
  uAhmed: u('aa', 5),
  uFatima: u('aa', 6),
  uArjun: u('aa', 7),
  uHessa: u('aa', 8),
  // leave types
  ltAnnualTS: u('30', 1),
  ltSickTS: u('30', 2),
  ltAnnualAT: u('30', 3),
  ltSickAT: u('30', 4),
  // payroll
  runSep: u('40', 1),
  runAug: u('40', 2),
  runJul: u('40', 3),
  runSepAT: u('40', 4),
}

const ts = (d, hm) => new Date(`${d}T${hm}:00+04:00`).toISOString()

export const entities = [
  { id: ID.entTS, name: 'Third State Cafe', code: 'TSC', trade_license_no: 'DED-1187342', emirate: 'Dubai', default_currency: 'AED', payroll_day: 28, is_active: true, created_at: '2025-11-02T08:00:00Z' },
  { id: ID.entAT, name: 'Ateej Tea Brew', code: 'ATB', trade_license_no: 'SEDD-782015', emirate: 'Sharjah', default_currency: 'AED', payroll_day: 28, is_active: true, created_at: '2026-02-14T08:00:00Z' },
]

export const locations = [
  { id: ID.locExpo, entity_id: ID.entTS, name: 'Expo City CRC Concession', code: 'EXPO-CRC', address: 'Community Resource Centre, Expo City Dubai', is_active: true, created_at: '2025-11-02T08:00:00Z' },
  { id: ID.locCorp, entity_id: ID.entTS, name: 'Corporate Concession', code: 'CORP', address: 'Level 2 staff lounge, Expo City Dubai HQ', is_active: true, created_at: '2025-12-01T08:00:00Z' },
  { id: ID.locShj, entity_id: ID.entAT, name: 'Sharjah Retail', code: 'SHJ-01', address: 'Tilal City, Sharjah', is_active: true, created_at: '2026-02-14T08:00:00Z' },
]

export const positions = [
  { id: ID.posBarista, entity_id: ID.entTS, title: 'Barista', department: 'Front of house', created_at: '2025-11-02T08:00:00Z' },
  { id: ID.posSenior, entity_id: ID.entTS, title: 'Senior Barista', department: 'Front of house', created_at: '2025-11-02T08:00:00Z' },
  { id: ID.posLead, entity_id: ID.entTS, title: 'Shift Lead', department: 'Operations', created_at: '2025-11-02T08:00:00Z' },
  { id: ID.posTea, entity_id: ID.entAT, title: 'Tea Specialist', department: 'Front of house', created_at: '2026-02-14T08:00:00Z' },
  { id: ID.posSeniorAT, entity_id: ID.entAT, title: 'Senior Barista', department: 'Front of house', created_at: '2026-02-14T08:00:00Z' },
]

function emp(o) {
  return {
    photo_url: null,
    preferred_name: null,
    gender: null,
    dob: null,
    notes: null,
    labor_card_exp: null,
    health_card_exp: null,
    probation_end_date: null,
    created_at: '2026-01-05T08:00:00Z',
    updated_at: '2026-09-20T08:00:00Z',
    employment_type: 'full_time',
    ...o,
  }
}

export const employees = [
  emp({ id: ID.maria, entity_id: ID.entTS, home_location_id: ID.locExpo, position_id: ID.posBarista, auth_user_id: ID.uMaria, full_name: 'Maria Santos', gender: 'female', nationality: 'Philippines', dob: '1996-04-18', phone: '+971 50 214 7781', email: 'maria.santos@thirdstate.ae', emergency_contact_name: 'Ana Santos (sister)', emergency_contact_phone: '+971 55 390 1142', passport_exp: '2030-03-11', visa_exp: '2026-10-14', labor_card_exp: '2027-06-30', health_card_exp: '2026-10-08', employment_status: 'active', join_date: '2026-01-12', probation_end_date: '2026-07-11' }),
  emp({ id: ID.omar, entity_id: ID.entTS, home_location_id: ID.locExpo, position_id: ID.posLead, auth_user_id: ID.uOmar, full_name: 'Omar Haddad', gender: 'male', nationality: 'Jordan', dob: '1990-09-02', phone: '+971 52 118 4420', email: 'omar.haddad@thirdstate.ae', emergency_contact_name: 'Lina Haddad', emergency_contact_phone: '+971 52 118 4421', passport_exp: '2029-01-20', visa_exp: '2027-11-30', employment_status: 'active', join_date: '2025-11-10' }),
  emp({ id: ID.priya, entity_id: ID.entTS, home_location_id: ID.locExpo, position_id: ID.posSenior, auth_user_id: ID.uPriya, full_name: 'Priya Nair', gender: 'female', nationality: 'India', dob: '1994-12-07', phone: '+971 56 702 3318', email: 'priya.nair@thirdstate.ae', emergency_contact_name: 'Vikram Nair', emergency_contact_phone: '+971 56 702 3319', passport_exp: '2031-05-16', visa_exp: '2027-08-04', employment_status: 'active', join_date: '2025-12-01' }),
  emp({ id: ID.joseph, entity_id: ID.entTS, home_location_id: ID.locExpo, position_id: ID.posBarista, auth_user_id: null, full_name: 'Joseph Mwangi', gender: 'male', nationality: 'Kenya', dob: '1998-02-25', phone: '+971 54 661 0923', email: 'joseph.mwangi@thirdstate.ae', emergency_contact_name: 'Grace Wanjiku', emergency_contact_phone: '+254 722 481 007', passport_exp: '2028-07-09', visa_exp: '2027-03-22', employment_status: 'active', join_date: '2026-03-02' }),
  emp({ id: ID.ahmed, entity_id: ID.entTS, home_location_id: ID.locCorp, position_id: ID.posBarista, auth_user_id: ID.uAhmed, full_name: 'Ahmed Raza', gender: 'male', nationality: 'Pakistan', dob: '1997-06-13', phone: '+971 50 889 2045', email: 'ahmed.raza@thirdstate.ae', emergency_contact_name: 'Sana Raza', emergency_contact_phone: '+971 50 889 2046', passport_exp: '2029-10-01', visa_exp: '2027-05-18', employment_status: 'active', join_date: '2026-02-09', employment_type: 'part_time' }),
  emp({ id: ID.noura, entity_id: ID.entTS, home_location_id: ID.locExpo, position_id: ID.posBarista, auth_user_id: null, full_name: 'Noura Khalil', gender: 'female', nationality: 'Lebanon', dob: '2000-08-30', phone: '+971 58 430 7716', email: 'noura.khalil@thirdstate.ae', emergency_contact_name: 'Rami Khalil', emergency_contact_phone: '+961 3 552 108', passport_exp: '2032-02-14', visa_exp: null, employment_status: 'pre_boarding', join_date: '2026-10-04', created_at: '2026-09-18T09:00:00Z' }),
  emp({ id: ID.fatima, entity_id: ID.entAT, home_location_id: ID.locShj, position_id: ID.posTea, auth_user_id: ID.uFatima, full_name: 'Fatima Al Hashimi', gender: 'female', nationality: 'United Arab Emirates', dob: '1995-03-21', phone: '+971 50 667 1209', email: 'fatima.alhashimi@thirdstate.ae', emergency_contact_name: 'Mariam Al Hashimi', emergency_contact_phone: '+971 50 667 1210', passport_exp: '2031-01-09', visa_exp: null, employment_status: 'active', join_date: '2026-03-01' }),
  emp({ id: ID.arjun, entity_id: ID.entAT, home_location_id: ID.locShj, position_id: ID.posSeniorAT, auth_user_id: ID.uArjun, full_name: 'Arjun Menon', gender: 'male', nationality: 'India', dob: '1993-11-11', phone: '+971 55 214 9087', email: 'arjun.menon@thirdstate.ae', emergency_contact_name: 'Divya Menon', emergency_contact_phone: '+971 55 214 9088', passport_exp: '2028-12-03', visa_exp: '2027-09-15', employment_status: 'active', join_date: '2026-03-01' }),
]

// ---------- documents ----------
let docN = 0
function doc(o) {
  docN += 1
  return {
    id: u('d0', docN),
    storage_path: `${o.employee_id}/${o.doc_type}-v${o.version_number ?? 1}.pdf`,
    notes: null,
    review_status: 'approved',
    version_number: 1,
    supersedes_document_id: null,
    is_current: true,
    submitted_by: ID.uOwner,
    submitted_at: '2026-01-10T09:00:00Z',
    reviewed_by: ID.uOwner,
    reviewed_at: '2026-01-10T12:00:00Z',
    rejection_reason: null,
    archived_at: null,
    archived_by: null,
    created_at: '2026-01-10T09:00:00Z',
    updated_at: '2026-01-10T12:00:00Z',
    upload_confirmed: true,
    ...o,
  }
}

const mariaHealthV1 = doc({ employee_id: ID.maria, doc_type: 'health_card', expiry_date: '2026-10-08', submitted_at: '2025-10-09T08:10:00Z', created_at: '2025-10-09T08:10:00Z' })
const nouraEid = doc({ employee_id: ID.noura, doc_type: 'emirates_id', expiry_date: '2028-09-15', review_status: 'pending_review', is_current: false, submitted_at: '2026-09-24T10:42:00Z', reviewed_by: null, reviewed_at: null })

export const employee_documents = [
  // Maria Santos
  doc({ employee_id: ID.maria, doc_type: 'passport', expiry_date: '2030-03-11' }),
  doc({ employee_id: ID.maria, doc_type: 'visa', expiry_date: '2026-10-14' }),
  doc({ employee_id: ID.maria, doc_type: 'emirates_id', expiry_date: '2028-01-11' }),
  doc({ employee_id: ID.maria, doc_type: 'contract', expiry_date: '2028-01-11' }),
  mariaHealthV1,
  doc({ employee_id: ID.maria, doc_type: 'health_card', expiry_date: '2027-10-07', version_number: 2, supersedes_document_id: mariaHealthV1.id, is_current: false, review_status: 'pending_review', submitted_by: ID.uMaria, submitted_at: '2026-09-25T06:18:00Z', reviewed_by: null, reviewed_at: null, notes: 'Renewed at DHA Al Karama centre' }),
  // Omar
  doc({ employee_id: ID.omar, doc_type: 'passport', expiry_date: '2029-01-20' }),
  doc({ employee_id: ID.omar, doc_type: 'visa', expiry_date: '2027-11-30' }),
  doc({ employee_id: ID.omar, doc_type: 'emirates_id', expiry_date: '2027-11-30' }),
  doc({ employee_id: ID.omar, doc_type: 'contract', expiry_date: null }),
  // Priya
  doc({ employee_id: ID.priya, doc_type: 'passport', expiry_date: '2031-05-16' }),
  doc({ employee_id: ID.priya, doc_type: 'visa', expiry_date: '2027-08-04' }),
  doc({ employee_id: ID.priya, doc_type: 'emirates_id', expiry_date: '2027-08-04' }),
  doc({ employee_id: ID.priya, doc_type: 'contract', expiry_date: null }),
  // Joseph
  doc({ employee_id: ID.joseph, doc_type: 'passport', expiry_date: '2028-07-09' }),
  doc({ employee_id: ID.joseph, doc_type: 'visa', expiry_date: '2027-03-22' }),
  doc({ employee_id: ID.joseph, doc_type: 'emirates_id', expiry_date: '2027-03-22' }),
  doc({ employee_id: ID.joseph, doc_type: 'contract', expiry_date: null }),
  // Ahmed
  doc({ employee_id: ID.ahmed, doc_type: 'passport', expiry_date: '2029-10-01' }),
  doc({ employee_id: ID.ahmed, doc_type: 'visa', expiry_date: '2027-05-18' }),
  doc({ employee_id: ID.ahmed, doc_type: 'emirates_id', expiry_date: '2027-05-18' }),
  doc({ employee_id: ID.ahmed, doc_type: 'contract', expiry_date: null }),
  // Noura (pre-boarding)
  doc({ employee_id: ID.noura, doc_type: 'passport', expiry_date: '2032-02-14', submitted_at: '2026-09-18T09:30:00Z' }),
  nouraEid,
  // Ateej
  doc({ employee_id: ID.fatima, doc_type: 'passport', expiry_date: '2031-01-09' }),
  doc({ employee_id: ID.fatima, doc_type: 'emirates_id', expiry_date: '2030-03-21' }),
  doc({ employee_id: ID.fatima, doc_type: 'contract', expiry_date: null }),
  doc({ employee_id: ID.arjun, doc_type: 'passport', expiry_date: '2028-12-03' }),
  doc({ employee_id: ID.arjun, doc_type: 'visa', expiry_date: '2027-09-15' }),
  doc({ employee_id: ID.arjun, doc_type: 'emirates_id', expiry_date: '2027-09-15' }),
  doc({ employee_id: ID.arjun, doc_type: 'contract', expiry_date: null }),
]

export const completeness = {
  [ID.noura]: { percent: 62.5, missing: ['visa_document', 'emirates_id_document', 'contract_document'], total: 8, complete: false },
}
export const defaultCompleteness = { percent: 100, missing: [], total: 8, complete: true }

// ---------- leave ----------
export const leave_types = [
  { id: ID.ltAnnualTS, entity_id: ID.entTS, name: 'Annual Leave', accrual_days_per_year: 30, requires_approval: true, created_at: '2025-11-02T08:00:00Z' },
  { id: ID.ltSickTS, entity_id: ID.entTS, name: 'Sick Leave', accrual_days_per_year: 15, requires_approval: true, created_at: '2025-11-02T08:00:00Z' },
  { id: ID.ltAnnualAT, entity_id: ID.entAT, name: 'Annual Leave', accrual_days_per_year: 30, requires_approval: true, created_at: '2026-02-14T08:00:00Z' },
  { id: ID.ltSickAT, entity_id: ID.entAT, name: 'Sick Leave', accrual_days_per_year: 15, requires_approval: true, created_at: '2026-02-14T08:00:00Z' },
]

let lbN = 0
const bal = (employee_id, leave_type_id, balance_days) => ({ id: u('lb', ++lbN), employee_id, leave_type_id, balance_days, updated_at: '2026-09-01T00:05:00Z' })
export const leave_balances = [
  bal(ID.maria, ID.ltAnnualTS, 18),
  bal(ID.maria, ID.ltSickTS, 13),
  bal(ID.omar, ID.ltAnnualTS, 21),
  bal(ID.omar, ID.ltSickTS, 15),
  bal(ID.priya, ID.ltAnnualTS, 16),
  bal(ID.priya, ID.ltSickTS, 12),
  bal(ID.joseph, ID.ltAnnualTS, 12),
  bal(ID.joseph, ID.ltSickTS, 15),
  bal(ID.ahmed, ID.ltAnnualTS, 9),
  bal(ID.ahmed, ID.ltSickTS, 14),
  bal(ID.fatima, ID.ltAnnualAT, 14),
  bal(ID.fatima, ID.ltSickAT, 15),
  bal(ID.arjun, ID.ltAnnualAT, 13),
  bal(ID.arjun, ID.ltSickAT, 15),
]

let lrN = 0
const lr = (o) => ({ id: u('lr', ++lrN), decided_by: null, decided_at: null, manager_notes: null, reason: null, ...o })
export const leave_requests = [
  lr({ employee_id: ID.maria, leave_type_id: ID.ltAnnualTS, start_date: '2026-10-12', end_date: '2026-10-15', days_requested: 4, status: 'pending', reason: 'Family visit to Manila', requested_at: '2026-09-24T07:40:00Z' }),
  lr({ employee_id: ID.maria, leave_type_id: ID.ltSickTS, start_date: '2026-08-04', end_date: '2026-08-05', days_requested: 2, status: 'approved', requested_at: '2026-08-04T04:10:00Z', decided_by: ID.uOmar, decided_at: '2026-08-04T06:00:00Z', manager_notes: 'Get well soon — medical certificate received.' }),
  lr({ employee_id: ID.maria, leave_type_id: ID.ltAnnualTS, start_date: '2026-06-14', end_date: '2026-06-19', days_requested: 6, status: 'approved', requested_at: '2026-05-20T10:00:00Z', decided_by: ID.uOmar, decided_at: '2026-05-21T08:00:00Z' }),
  lr({ employee_id: ID.priya, leave_type_id: ID.ltAnnualTS, start_date: '2026-09-06', end_date: '2026-09-10', days_requested: 5, status: 'approved', requested_at: '2026-08-18T09:00:00Z', decided_by: ID.uOmar, decided_at: '2026-08-19T08:00:00Z' }),
  lr({ employee_id: ID.joseph, leave_type_id: ID.ltAnnualTS, start_date: '2026-09-17', end_date: '2026-09-18', days_requested: 2, status: 'rejected', requested_at: '2026-09-10T09:00:00Z', decided_by: ID.uOmar, decided_at: '2026-09-11T08:00:00Z', manager_notes: 'Expo event days — minimum staffing needed.' }),
  lr({ employee_id: ID.ahmed, leave_type_id: ID.ltSickTS, start_date: '2026-09-01', end_date: '2026-09-01', days_requested: 1, status: 'approved', requested_at: '2026-09-01T05:00:00Z', decided_by: ID.uOwner, decided_at: '2026-09-01T07:00:00Z' }),
  lr({ employee_id: ID.fatima, leave_type_id: ID.ltAnnualAT, start_date: '2026-10-19', end_date: '2026-10-21', days_requested: 3, status: 'pending', reason: 'Family wedding', requested_at: '2026-09-23T11:00:00Z' }),
]

export const leave_accrual_policies = [
  { id: u('ap', 1), entity_id: ID.entTS, leave_type_id: ID.ltAnnualTS, frequency: 'monthly', days_per_period: 2.5, rounding: 'nearest_half_day', max_balance_days: 45, carry_forward_cap_days: 15, probation_days: 0, policy_start_date: '2026-01-01', is_approved: true, approved_by: ID.uOwner, approved_at: '2026-01-02T08:00:00Z', created_by: ID.uOwner, created_at: '2026-01-02T07:00:00Z', updated_at: '2026-01-02T08:00:00Z' },
]

// ---------- schedule ----------
const DAYS = []
for (let i = -6; i <= 7; i++) {
  const d = new Date(`${TODAY}T12:00:00Z`)
  d.setUTCDate(d.getUTCDate() + i)
  DAYS.push(d.toISOString().slice(0, 10))
}
export const addDays = (iso, n) => {
  const d = new Date(`${iso}T12:00:00Z`)
  d.setUTCDate(d.getUTCDate() + n)
  return d.toISOString().slice(0, 10)
}

// Weekly pattern per employee: day offset (0=Sun..6=Sat) -> 'AM' | 'PM' | null
const AM = ['09:00:00', '17:00:00']
const PM = ['12:00:00', '20:00:00']
const PATTERN = {
  [ID.maria]: { 0: AM, 1: PM, 2: null, 3: PM, 4: AM, 5: AM, 6: AM },
  [ID.omar]: { 0: AM, 1: AM, 2: AM, 3: AM, 4: null, 5: null, 6: AM },
  [ID.priya]: { 0: PM, 1: AM, 2: AM, 3: null, 4: PM, 5: PM, 6: PM },
  [ID.joseph]: { 0: null, 1: PM, 2: PM, 3: PM, 4: PM, 5: AM, 6: PM },
  [ID.ahmed]: { 0: AM, 1: AM, 2: null, 3: AM, 4: AM, 5: null, 6: null },
  [ID.fatima]: { 0: AM, 1: AM, 2: AM, 3: null, 4: PM, 5: PM, 6: AM },
  [ID.arjun]: { 0: PM, 1: PM, 2: PM, 3: AM, 4: null, 5: AM, 6: PM },
}
let shN = 0
export const shifts = []
for (const d of DAYS) {
  const dow = new Date(`${d}T12:00:00Z`).getUTCDay()
  for (const e of employees) {
    const p = PATTERN[e.id]?.[dow]
    if (!p) continue
    shN += 1
    const future = d > addDays(TODAY, 4)
    shifts.push({
      id: u('5f', shN),
      entity_id: e.entity_id,
      location_id: e.home_location_id,
      position_id: e.position_id,
      employee_id: e.id,
      shift_date: d,
      start_time: p[0],
      end_time: p[1],
      status: 'assigned',
      notes: null,
      created_by: ID.uOmar,
      created_at: '2026-09-13T10:00:00Z',
      // Next week beyond Wed is still draft (generated, not yet published)
      is_published: !future,
      generated_from_template_id: null,
    })
  }
}
// One open shift at Corporate Concession on Mon 28 Sep
shifts.push({ id: u('5f', 900), entity_id: ID.entTS, location_id: ID.locCorp, position_id: ID.posBarista, employee_id: null, shift_date: '2026-09-28', start_time: '12:00:00', end_time: '20:00:00', status: 'open', notes: 'Extra cover for CRC event', created_by: ID.uOmar, created_at: '2026-09-22T10:00:00Z', is_published: true, generated_from_template_id: null })

export const findShift = (empId, date) => shifts.find((s) => s.employee_id === empId && s.shift_date === date)

let tplN = 0
const tpl = (employee_id, location_id, position_id, dow, [s, e]) => ({ id: u('7e', ++tplN), entity_id: ID.entTS, location_id, employee_id, position_id, day_of_week: dow, start_time: s, end_time: e, break_minutes: 60, effective_start_date: '2026-09-01', effective_end_date: null, version_number: 1, supersedes_template_id: null, is_active: true, created_by: ID.uOmar, created_at: '2026-08-28T10:00:00Z', updated_at: '2026-08-28T10:00:00Z' })
export const schedule_templates = [
  tpl(ID.maria, ID.locExpo, ID.posBarista, 0, AM),
  tpl(ID.maria, ID.locExpo, ID.posBarista, 1, PM),
  tpl(ID.priya, ID.locExpo, ID.posSenior, 1, AM),
  tpl(ID.joseph, ID.locExpo, ID.posBarista, 3, PM),
  tpl(ID.omar, ID.locExpo, ID.posLead, 6, AM),
  tpl(ID.ahmed, ID.locCorp, ID.posBarista, 0, AM),
]

export const shift_swap_requests = [
  { id: u('5a', 1), shift_id: findShift(ID.priya, '2026-09-29').id, requested_by: ID.priya, claimed_by: ID.joseph, status: 'claimed', notes: 'Dentist appointment', created_at: '2026-09-24T12:00:00Z', resolved_by: null, resolved_at: null },
]

// ---------- attendance ----------
// Maria's clock history (last week). Thu 24 Sep = late 14 min.
export const mariaAttendance = [
  { d: '2026-09-20', in: '08:57', out: '17:03' },
  { d: '2026-09-21', in: '11:58', out: '20:05' },
  { d: '2026-09-23', in: '11:55', out: '20:01' },
  { d: '2026-09-24', in: '09:14', out: '17:02', late: 14 },
  { d: '2026-09-25', in: '08:54', out: '17:06' },
]

let arN = 0
export const attendance_records = []
function addRecord(employee_id, d, inHm, outHm, extra = {}) {
  const sh = findShift(employee_id, d)
  const e = employees.find((x) => x.id === employee_id)
  const rec = {
    id: u('a7', ++arN),
    entity_id: e.entity_id,
    location_id: e.home_location_id,
    employee_id,
    shift_id: sh?.id ?? null,
    clock_in_at: ts(d, inHm),
    clock_out_at: outHm ? ts(d, outHm) : null,
    original_clock_in_at: null,
    original_clock_out_at: null,
    corrected: false,
    correction_reason: null,
    corrected_by: null,
    corrected_at: null,
    created_at: ts(d, inHm),
    updated_at: ts(d, outHm ?? inHm),
    ...extra,
  }
  attendance_records.push(rec)
  return rec
}
for (const a of mariaAttendance) addRecord(ID.maria, a.d, a.in, a.out)
export const josephMissingOut = addRecord(ID.joseph, '2026-09-23', '12:02', null)
export const mariaLate = attendance_records.find((r) => r.employee_id === ID.maria && r.clock_in_at === ts('2026-09-24', '09:14'))

export function mariaMyAttendance(clockedIn, clockInIso) {
  const rows = mariaAttendance.map((a) => {
    const sh = findShift(ID.maria, a.d)
    const rec = attendance_records.find((r) => r.employee_id === ID.maria && r.clock_in_at === ts(a.d, a.in))
    const mins = Math.round((new Date(ts(a.d, a.out)) - new Date(ts(a.d, a.in))) / 60000)
    return {
      attendance_id: rec.id,
      shift_id: sh?.id ?? null,
      business_date: a.d,
      location_id: ID.locExpo,
      location_name: 'Expo City CRC Concession',
      planned_start: sh ? ts(a.d, sh.start_time.slice(0, 5)) : null,
      planned_end: sh ? ts(a.d, sh.end_time.slice(0, 5)) : null,
      clock_in_at: ts(a.d, a.in),
      clock_out_at: ts(a.d, a.out),
      worked_minutes: mins,
      late_minutes: a.late ?? 0,
      status: 'completed',
      corrected: false,
      correction_reason: null,
    }
  })
  const today = findShift(ID.maria, TODAY)
  rows.push({
    attendance_id: clockedIn ? u('a7', 777) : null,
    shift_id: today.id,
    business_date: TODAY,
    location_id: ID.locExpo,
    location_name: 'Expo City CRC Concession',
    planned_start: ts(TODAY, '09:00'),
    planned_end: ts(TODAY, '17:00'),
    clock_in_at: clockedIn ? clockInIso : null,
    clock_out_at: null,
    worked_minutes: null,
    late_minutes: 0,
    status: clockedIn ? 'in_progress' : 'scheduled',
    corrected: false,
    correction_reason: null,
  })
  return rows
}

export function attendanceExceptions(locationId) {
  if (locationId !== ID.locExpo) return []
  const pShift = findShift(ID.priya, '2026-09-22')
  return [
    { exception_type: 'missing_clock_out', employee_id: ID.joseph, employee_name: 'Joseph Mwangi', shift_date: '2026-09-23', record_id: josephMissingOut.id, shift_id: josephMissingOut.shift_id, clock_in_at: josephMissingOut.clock_in_at, clock_out_at: null },
    { exception_type: 'late_clock_in', employee_id: ID.maria, employee_name: 'Maria Santos', shift_date: '2026-09-24', record_id: mariaLate.id, shift_id: mariaLate.shift_id, clock_in_at: mariaLate.clock_in_at, clock_out_at: mariaLate.clock_out_at },
    { exception_type: 'unmatched_shift', employee_id: ID.priya, employee_name: 'Priya Nair', shift_date: '2026-09-22', record_id: null, shift_id: pShift?.id ?? null, clock_in_at: null, clock_out_at: null },
  ]
}

const shiftMinutes = (s) => {
  const [h1, m1] = s.start_time.split(':').map(Number)
  const [h2, m2] = s.end_time.split(':').map(Number)
  return h2 * 60 + m2 - (h1 * 60 + m1)
}
export function payableForLocation(locationId, start, end) {
  return shifts
    .filter((s) => s.location_id === locationId && s.employee_id && s.is_published && s.shift_date >= start && s.shift_date <= end && s.shift_date < TODAY)
    .map((s, i) => ({
      id: u('9a', shifts.indexOf(s) + 1),
      shift_id: s.id,
      employee_id: s.employee_id,
      planned_minutes: shiftMinutes(s),
      planned_break_minutes: 60,
      default_payable_minutes: shiftMinutes(s) - 60,
      final_payable_minutes: null,
      status: 'pending',
    }))
}

// ---------- payroll ----------
export const payroll_runs = [
  { id: ID.runSep, entity_id: ID.entTS, period_start: '2026-09-01', period_end: '2026-09-30', status: 'draft', tip_distribution_rule: 'equal', created_by: ID.uOwner, created_at: '2026-09-21T09:00:00Z', approved_by: null, approved_at: null, overtime_holiday_pay_confirmed: true, tips_distribution_confirmed: true, revises_payroll_run_id: null },
  { id: ID.runAug, entity_id: ID.entTS, period_start: '2026-08-01', period_end: '2026-08-31', status: 'approved', tip_distribution_rule: 'equal', created_by: ID.uOwner, created_at: '2026-08-24T09:00:00Z', approved_by: ID.uOwner, approved_at: '2026-08-27T13:00:00Z', overtime_holiday_pay_confirmed: true, tips_distribution_confirmed: true, revises_payroll_run_id: null },
  { id: ID.runJul, entity_id: ID.entTS, period_start: '2026-07-01', period_end: '2026-07-31', status: 'paid', tip_distribution_rule: 'equal', created_by: ID.uOwner, created_at: '2026-07-24T09:00:00Z', approved_by: ID.uOwner, approved_at: '2026-07-27T13:00:00Z', overtime_holiday_pay_confirmed: true, tips_distribution_confirmed: true, revises_payroll_run_id: null },
  { id: ID.runSepAT, entity_id: ID.entAT, period_start: '2026-09-01', period_end: '2026-09-30', status: 'draft', tip_distribution_rule: 'equal', created_by: ID.uOwner, created_at: '2026-09-21T09:00:00Z', approved_by: null, approved_at: null, overtime_holiday_pay_confirmed: false, tips_distribution_confirmed: false, revises_payroll_run_id: null },
]

// Payslip figures (AED)
const PS = {
  [ID.runSep]: [
    [ID.maria, 3500, 131.25, 0, 385, 0, 176, 6],
    [ID.omar, 6500, 0, 0, 385, 0, 184, 0],
    [ID.priya, 4200, 262.5, 0, 385, 0, 176, 10],
    [ID.joseph, 3500, 0, 0, 385, 75, 168, 0],
    [ID.ahmed, 3500, 87.5, 0, 420, 200, 120, 4],
  ],
  [ID.runAug]: [
    [ID.maria, 3500, 218.75, 0, 420, 150, 184, 10],
    [ID.omar, 6500, 0, 0, 420, 0, 184, 0],
    [ID.priya, 4200, 175, 0, 420, 0, 184, 7],
    [ID.joseph, 3500, 43.75, 0, 420, 0, 176, 2],
    [ID.ahmed, 3500, 0, 0, 380, 0, 112, 0],
  ],
  [ID.runJul]: [
    [ID.maria, 3500, 87.5, 0, 314.5, 0, 184, 4],
    [ID.omar, 6500, 0, 0, 314.5, 0, 184, 0],
    [ID.priya, 4200, 131.25, 0, 314.5, 0, 176, 5],
    [ID.joseph, 3500, 0, 0, 314.5, 0, 168, 0],
    [ID.ahmed, 3500, 43.75, 0, 300, 0, 104, 2],
  ],
}
const DED = {
  [ID.runSep]: [
    [ID.joseph, 'uniform', 75, 'Replacement apron and cap'],
    [ID.ahmed, 'advance', 200, 'Salary advance recovery (2 of 3)'],
  ],
  [ID.runAug]: [[ID.maria, 'uniform', 150, 'Uniform replacement']],
  [ID.runJul]: [],
}
export const payslips = []
export const timesheet_entries = []
export const payslip_deductions = []
let psN = 0
for (const [runId, rows] of Object.entries(PS)) {
  for (const [employee_id, base, ot, hol, tips, ded, regH, otH] of rows) {
    psN += 1
    payslips.push({ id: u('b5', psN), payroll_run_id: runId, employee_id, base_pay: base, overtime_pay: ot, holiday_pay: hol, tips_share: tips, total_deductions: ded, net_pay: Math.round((base + ot + hol + tips - ded) * 100) / 100, generated_at: '2026-09-25T10:00:00Z' })
    timesheet_entries.push({ id: u('b6', psN), payroll_run_id: runId, employee_id, regular_hours: regH, overtime_hours: otH, holiday_hours: 0, notes: null })
  }
}
let pdN = 0
for (const [runId, rows] of Object.entries(DED)) {
  for (const [employee_id, deduction_type, amount, notes] of rows) {
    payslip_deductions.push({ id: u('b7', ++pdN), payroll_run_id: runId, employee_id, deduction_type, amount, notes, created_at: '2026-09-24T10:00:00Z' })
  }
}
export const tips_pools = [
  { id: u('b8', 1), payroll_run_id: ID.runSep, location_id: ID.locExpo, total_amount: 1540, notes: 'Card + cash tips, 1–25 Sep', updated_at: '2026-09-25T09:00:00Z' },
  { id: u('b8', 2), payroll_run_id: ID.runSep, location_id: ID.locCorp, total_amount: 420, notes: 'Card tips', updated_at: '2026-09-25T09:00:00Z' },
  { id: u('b8', 3), payroll_run_id: ID.runAug, location_id: ID.locExpo, total_amount: 1680, notes: null, updated_at: '2026-08-26T09:00:00Z' },
  { id: u('b8', 4), payroll_run_id: ID.runAug, location_id: ID.locCorp, total_amount: 380, notes: null, updated_at: '2026-08-26T09:00:00Z' },
]

export const payroll_run_totals = payroll_runs.map((r) => {
  const ps = payslips.filter((p) => p.payroll_run_id === r.id)
  const sum = (k) => Math.round(ps.reduce((s, p) => s + p[k], 0) * 100) / 100
  return {
    payroll_run_id: r.id,
    entity_id: r.entity_id,
    period_start: r.period_start,
    period_end: r.period_end,
    status: r.status,
    employee_count: r.id === ID.runSepAT ? 2 : ps.length,
    total_base_pay: sum('base_pay'),
    total_overtime_pay: sum('overtime_pay'),
    total_holiday_pay: sum('holiday_pay'),
    total_tips: sum('tips_share'),
    total_deductions: sum('total_deductions'),
    total_net_pay: sum('net_pay'),
  }
})

export function payslipDetail(payslipId) {
  const p = payslips.find((x) => x.id === payslipId)
  if (!p) return null
  const run = payroll_runs.find((r) => r.id === p.payroll_run_id)
  const e = employees.find((x) => x.id === p.employee_id)
  const ent = entities.find((x) => x.id === e.entity_id)
  const ts_ = timesheet_entries.find((t) => t.payroll_run_id === run.id && t.employee_id === e.id)
  const earnings = [
    { code: 'base', label: 'Basic salary', amount: p.base_pay },
    ...(p.overtime_pay ? [{ code: 'overtime', label: `Overtime (${ts_.overtime_hours} h × 1.25)`, amount: p.overtime_pay }] : []),
    ...(p.holiday_pay ? [{ code: 'holiday', label: 'Holiday pay', amount: p.holiday_pay }] : []),
    ...(p.tips_share ? [{ code: 'tips', label: 'Tips share', amount: p.tips_share }] : []),
  ]
  const deductions = payslip_deductions
    .filter((d) => d.payroll_run_id === run.id && d.employee_id === e.id)
    .map((d) => ({ type: d.deduction_type, label: d.deduction_type === 'uniform' ? 'Uniform' : d.deduction_type === 'advance' ? 'Salary advance' : undefined, amount: d.amount, notes: d.notes }))
  const gross = Math.round((p.base_pay + p.overtime_pay + p.holiday_pay + p.tips_share) * 100) / 100
  return {
    payslip_id: p.id,
    payroll_run_id: run.id,
    version: 1,
    is_revision: false,
    revises_payroll_run_id: null,
    superseded: false,
    run_status: run.status,
    period_start: run.period_start,
    period_end: run.period_end,
    published_at: run.approved_at,
    generated_at: p.generated_at,
    currency: 'AED',
    employer: { entity_id: ent.id, name: ent.name, trade_license_no: ent.trade_license_no, emirate: ent.emirate },
    employee: {
      employee_id: e.id,
      full_name: e.full_name,
      preferred_name: e.preferred_name,
      position_title: positions.find((x) => x.id === e.position_id)?.title ?? null,
      location_name: locations.find((x) => x.id === e.home_location_id)?.name ?? null,
      employment_type: e.employment_type,
      join_date: e.join_date,
    },
    salary: { pay_type: 'monthly', pay_rate: p.base_pay, overtime_multiplier: 1.25, holiday_multiplier: 1.5, regular_hours: ts_.regular_hours, overtime_hours: ts_.overtime_hours, holiday_hours: 0 },
    earnings,
    allowances: [],
    deductions,
    gross_pay: gross,
    total_deductions: p.total_deductions,
    net_pay: p.net_pay,
  }
}

export function myPayslipsFor(employeeId) {
  return payslips
    .filter((p) => p.employee_id === employeeId)
    .map((p) => ({ p, run: payroll_runs.find((r) => r.id === p.payroll_run_id) }))
    .filter(({ run }) => run.status === 'approved' || run.status === 'paid')
    .sort((a, b) => b.run.period_start.localeCompare(a.run.period_start))
    .map(({ p, run }) => ({
      payslip_id: p.id,
      payroll_run_id: run.id,
      period_start: run.period_start,
      period_end: run.period_end,
      run_status: run.status,
      version: 1,
      is_revision: false,
      superseded: false,
      published_at: run.approved_at,
      currency: 'AED',
      gross_pay: Math.round((p.base_pay + p.overtime_pay + p.holiday_pay + p.tips_share) * 100) / 100,
      total_deductions: p.total_deductions,
      net_pay: p.net_pay,
    }))
}

// ---------- change requests ----------
export const employee_change_requests = [
  { id: u('c4', 1), employee_id: ID.priya, field_name: 'phone', old_value: '+971 56 702 3318', new_value: '+971 56 702 9950', reason: 'New number from du', status: 'pending', requested_at: '2026-09-25T14:20:00Z', decided_by: null, decided_at: null, decision_reason: null },
  { id: u('c4', 2), employee_id: ID.maria, field_name: 'emergency_contact_phone', old_value: '+971 55 390 1100', new_value: '+971 55 390 1142', reason: 'Sister changed her number', status: 'approved', requested_at: '2026-08-12T08:00:00Z', decided_by: ID.uOmar, decided_at: '2026-08-12T11:00:00Z', decision_reason: null },
]

// ---------- workflows ----------
export const workflow_rules = [
  { id: u('f1', 1), entity_id: ID.entTS, name: 'Tell the manager about new leave requests', module: 'leave', trigger_event: 'leave_submitted', condition_field: null, condition_operator: null, condition_value: null, action_type: 'notify_role', action_target_role: 'location_manager', action_message_template: 'A new leave request is waiting for your decision.', is_active: true, is_starter: true, version_number: 1, created_at: '2025-11-02T08:00:00Z', updated_at: '2025-11-02T08:00:00Z', activated_at: '2025-11-02T08:00:00Z', deactivated_at: null },
  { id: u('f1', 2), entity_id: ID.entTS, name: 'Late clock-in alert (10+ minutes)', module: 'attendance', trigger_event: 'late_clock_in', condition_field: 'late_minutes', condition_operator: 'gte', condition_value: '10', action_type: 'notify_role', action_target_role: 'location_manager', action_message_template: 'A team member clocked in 10 or more minutes late. Check Attendance.', is_active: true, is_starter: false, version_number: 1, created_at: '2026-03-04T08:00:00Z', updated_at: '2026-03-04T08:00:00Z', activated_at: '2026-03-04T08:30:00Z', deactivated_at: null },
  { id: u('f1', 3), entity_id: ID.entTS, name: 'Document expiring within 30 days', module: 'document', trigger_event: 'document_expiring_soon', condition_field: 'days_to_expiry', condition_operator: 'lte', condition_value: '30', action_type: 'notify_role', action_target_role: 'entity_admin', action_message_template: 'A staff document expires within 30 days. Start the renewal.', is_active: true, is_starter: true, version_number: 1, created_at: '2025-11-02T08:00:00Z', updated_at: '2025-11-02T08:00:00Z', activated_at: '2025-11-02T08:00:00Z', deactivated_at: null },
  { id: u('f1', 4), entity_id: ID.entTS, name: 'Let staff know their payslip is ready', module: 'payroll', trigger_event: 'payslip_published', condition_field: null, condition_operator: null, condition_value: null, action_type: 'notify_employee', action_target_role: null, action_message_template: 'Your payslip is ready in the app.', is_active: false, is_starter: true, version_number: 1, created_at: '2025-11-02T08:00:00Z', updated_at: '2025-11-02T08:00:00Z', activated_at: null, deactivated_at: '2026-01-15T08:00:00Z' },
]
export const workflow_runs = [
  { id: u('f2', 1), rule_id: u('f1', 1), entity_id: ID.entTS, source_table: 'leave_requests', source_record_id: leave_requests[0].id, event_type: 'leave_submitted', result: 'matched', details: null, ran_at: '2026-09-24T07:40:02Z' },
  { id: u('f2', 2), rule_id: u('f1', 2), entity_id: ID.entTS, source_table: 'attendance_records', source_record_id: mariaLate.id, event_type: 'late_clock_in', result: 'matched', details: null, ran_at: '2026-09-24T05:14:03Z' },
  { id: u('f2', 3), rule_id: u('f1', 3), entity_id: ID.entTS, source_table: 'employee_documents', source_record_id: u('d0', 2), event_type: 'document_expiring_soon', result: 'matched', details: null, ran_at: '2026-09-14T02:00:05Z' },
]

export const workflow_catalog = {
  leave: { leave_submitted: ['employee_id', 'location_id', 'leave_type_id', 'days_requested'] },
  document: {
    document_expiring_soon: ['employee_id', 'location_id', 'document_id', 'doc_type', 'expiry_date', 'days_to_expiry'],
    submitted_for_review: ['employee_id', 'location_id', 'document_id', 'doc_type', 'is_renewal'],
  },
  attendance: { late_clock_in: ['employee_id', 'location_id', 'shift_id', 'attendance_id', 'late_minutes'] },
  schedule: {
    schedule_published: ['employee_id', 'location_id', 'shift_date'],
    shift_adjusted: ['employee_id', 'previous_employee_id', 'location_id', 'shift_date', 'change_type'],
  },
  payroll: { payslip_published: ['employee_id', 'payroll_run_id', 'period_start', 'period_end', 'is_revision'] },
}

// ---------- audit ----------
let auN = 0
const au = (table_name, action, changed_at, employee_id = null, location_id = ID.locExpo) => ({ id: u('ad', ++auN), table_name, record_id: u('ad', 500 + auN), changed_by: ID.uOmar, changed_at, action, old_value: null, new_value: null, entity_id: ID.entTS, location_id, employee_id })
export const audit_log = [
  au('employee_documents', 'document_submitted', '2026-09-25T06:18:00Z', ID.maria),
  au('attendance_records', 'clock_out', '2026-09-25T13:06:00Z', ID.maria),
  au('leave_requests', 'leave_submitted', '2026-09-24T07:40:00Z', ID.maria),
  au('employee_documents', 'document_submitted', '2026-09-24T10:42:00Z', ID.noura),
  au('shifts', 'schedule_published', '2026-09-22T11:15:00Z'),
  au('payroll_runs', 'payroll_calculated', '2026-09-25T10:00:00Z', null, null),
  au('payslips', 'payslip_viewed', '2026-09-23T16:02:00Z', ID.priya),
  au('employees', 'employee_created', '2026-09-18T09:00:00Z', ID.noura),
  au('leave_requests', 'leave_rejected', '2026-09-11T08:00:00Z', ID.joseph),
  au('employees', 'employee_updated', '2026-09-10T12:30:00Z', ID.ahmed, ID.locCorp),
].sort((a, b) => b.changed_at.localeCompare(a.changed_at))

// ---------- notifications ----------
let nN = 0
const nt = (o) => ({ id: u('n0', ++nN), resolved_at: null, priority: 'normal', read_at: null, ...o })
export const notifications = {
  owner: [
    nt({ notification_type: 'document_review', title: 'Document waiting for review', message: 'Maria Santos submitted a Health card renewal.', target_type: 'employee_documents', created_at: '2026-09-25T06:18:30Z' }),
    nt({ notification_type: 'document_review', title: 'Document waiting for review', message: 'Noura Khalil — Emirates ID uploaded during pre-boarding.', target_type: 'employee_documents', created_at: '2026-09-24T10:43:00Z' }),
    nt({ notification_type: 'workflow', title: 'Document expiring within 30 days', message: 'Maria Santos — Visa expires 14 Oct 2026. Start the renewal.', target_type: 'employee_documents', priority: 'high', created_at: '2026-09-14T02:00:05Z' }),
    nt({ notification_type: 'payroll', title: 'Payroll run ready to review', message: 'September 2026 draft for Third State Cafe has been calculated.', target_type: 'payslips', created_at: '2026-09-25T10:00:30Z', read_at: '2026-09-25T11:00:00Z' }),
    nt({ notification_type: 'leave', title: 'Leave request submitted', message: 'Fatima Al Hashimi requested 3 days of Annual Leave.', target_type: 'leave_requests', created_at: '2026-09-23T11:00:30Z', read_at: '2026-09-23T12:00:00Z' }),
  ],
  manager: [
    nt({ notification_type: 'workflow', title: 'Leave request submitted', message: 'A new leave request is waiting for your decision.', target_type: 'leave_requests', created_at: '2026-09-24T07:40:02Z' }),
    nt({ notification_type: 'workflow', title: 'Late clock-in alert (10+ minutes)', message: 'Maria Santos clocked in 14 minutes late (Thu 24 Sep, Expo City CRC Concession).', target_type: 'attendance_records', priority: 'high', created_at: '2026-09-24T05:14:03Z' }),
    nt({ notification_type: 'swap', title: 'Shift swap needs approval', message: 'Priya Nair → Joseph Mwangi, Tue 29 Sep 09:00–17:00.', target_type: 'shift_swap_requests', created_at: '2026-09-24T12:00:30Z' }),
    nt({ notification_type: 'attendance', title: 'Missing clock-out', message: 'Joseph Mwangi did not clock out on Wed 23 Sep.', target_type: 'attendance_records', created_at: '2026-09-24T00:05:00Z', read_at: '2026-09-24T06:00:00Z' }),
  ],
  staff: [
    nt({ notification_type: 'document', title: 'Your visa expires soon', message: 'Your visa expires on 14 Oct 2026. Please upload the renewed visa.', target_type: 'employee_documents', priority: 'high', created_at: '2026-09-14T02:00:05Z' }),
    nt({ notification_type: 'schedule', title: 'New schedule published', message: 'Your shifts for 27 – 30 Sep are now available.', target_type: 'shifts', created_at: '2026-09-22T11:15:00Z' }),
    nt({ notification_type: 'document', title: 'Renewal received', message: 'Your Health card renewal was submitted and is waiting for review.', target_type: 'employee_documents', created_at: '2026-09-25T06:18:30Z', read_at: '2026-09-25T06:20:00Z' }),
    nt({ notification_type: 'payslip', title: 'Payslip ready', message: 'Your payslip for August 2026 is available.', target_type: 'payslips', created_at: '2026-08-27T13:00:30Z', read_at: '2026-08-27T18:00:00Z' }),
  ],
}

// ---------- users & access ----------
export const user_access = [
  { user_id: ID.uOwner, email: 'aisha@thirdstate.ae', full_name: 'Aisha A.', role: 'owner', entity_id: null, location_id: null, employee_id: null, is_active: true, last_sign_in_at: '2026-09-26T05:58:00Z', is_pending: false, grant_id: null },
  { user_id: ID.uHessa, email: 'hessa.almarri@thirdstate.ae', full_name: 'Hessa Al Marri', role: 'entity_admin', entity_id: ID.entTS, location_id: null, employee_id: null, is_active: true, last_sign_in_at: '2026-09-25T12:10:00Z', is_pending: false, grant_id: null },
  { user_id: ID.uOmar, email: 'omar.haddad@thirdstate.ae', full_name: 'Omar Haddad', role: 'location_manager', entity_id: ID.entTS, location_id: ID.locExpo, employee_id: ID.omar, is_active: true, last_sign_in_at: '2026-09-26T04:47:00Z', is_pending: false, grant_id: null },
  { user_id: ID.uMaria, email: 'maria.santos@thirdstate.ae', full_name: 'Maria Santos', role: 'staff', entity_id: ID.entTS, location_id: null, employee_id: ID.maria, is_active: true, last_sign_in_at: '2026-09-25T04:51:00Z', is_pending: false, grant_id: null },
  { user_id: ID.uPriya, email: 'priya.nair@thirdstate.ae', full_name: 'Priya Nair', role: 'staff', entity_id: ID.entTS, location_id: null, employee_id: ID.priya, is_active: true, last_sign_in_at: '2026-09-24T08:02:00Z', is_pending: false, grant_id: null },
  { user_id: ID.uAhmed, email: 'ahmed.raza@thirdstate.ae', full_name: 'Ahmed Raza', role: 'staff', entity_id: ID.entTS, location_id: null, employee_id: ID.ahmed, is_active: true, last_sign_in_at: '2026-09-22T05:30:00Z', is_pending: false, grant_id: null },
  { user_id: null, email: 'joseph.mwangi@thirdstate.ae', full_name: 'Joseph Mwangi', role: 'staff', entity_id: ID.entTS, location_id: null, employee_id: ID.joseph, is_active: false, last_sign_in_at: null, is_pending: true, grant_id: u('9c', 1) },
]

export const owner_kpis = {
  entity_id: null,
  scope: 'all_entities',
  generated_at: '2026-09-26T06:15:00Z',
  headcount: { candidate: 0, pre_boarding: 1, active: 7, inactive: 0, total: 8 },
  document_expiry: { expired: 0, expiring_30_days: 2, ok: 27 },
  document_review_queue: 2,
  leave: { pending_requests: 2, approved_this_month: 2 },
  payroll: { draft_runs: 2, in_review_runs: 0, approved_unpaid_runs: 1, paid_runs: 1 },
  recruitment: { open_requisitions: 1, candidates_in_pipeline: 4 },
  workflow: { active_rules: 3, runs_last_7_days: 2 },
}

// ---------- personas ----------
export const personas = {
  owner: { key: 'owner', userId: ID.uOwner, email: 'aisha@thirdstate.ae', role: 'owner', full_name: 'Aisha A.', entityId: null, locationId: null, employeeId: null, notif: 'owner' },
  manager: { key: 'manager', userId: ID.uOmar, email: 'omar.haddad@thirdstate.ae', role: 'location_manager', full_name: 'Omar Haddad', entityId: ID.entTS, locationId: ID.locExpo, employeeId: ID.omar, notif: 'manager' },
  staff: { key: 'staff', userId: ID.uMaria, email: 'maria.santos@thirdstate.ae', role: 'staff', full_name: 'Maria Santos', entityId: ID.entTS, locationId: ID.locExpo, employeeId: ID.maria, notif: 'staff' },
}

export const tables = {
  entities,
  locations,
  positions,
  employees,
  employee_documents,
  leave_types,
  leave_balances,
  leave_requests,
  leave_accrual_policies,
  shifts,
  schedule_templates,
  shift_swap_requests,
  attendance_records,
  payroll_runs,
  payroll_run_totals,
  payslips,
  timesheet_entries,
  payslip_deductions,
  tips_pools,
  employee_change_requests,
  audit_log,
  data_retention_policies: [
    { id: u('dr', 1), entity_id: ID.entTS, table_name: 'attendance_records', retention_years: 5, disposal_method: 'manual_review', legal_basis: 'UAE Labour Law record-keeping', is_approved: true, approved_at: '2026-01-05T08:00:00Z', created_at: '2026-01-04T08:00:00Z' },
  ],
  job_requisitions: [{ id: u('jr', 1), entity_id: ID.entTS, location_id: ID.locCorp, position_id: ID.posBarista, headcount: 1, status: 'open', created_by: ID.uOwner, created_at: '2026-09-15T08:00:00Z' }],
  payable_shift_records: [],
  attendance_adjustments: [],
  employee_compensation: [],
  employee_identity_documents: [],
}

tables.payable_shift_records = [ID.locExpo, ID.locCorp, ID.locShj].flatMap((l) => payableForLocation(l, '2026-09-01', '2026-10-31'))
