// In-browser Supabase mock for manual screenshots. Every request to
// *.supabase.co is answered here from fixtures.mjs — nothing reaches a real
// backend. Unhandled requests are logged to stderr.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import * as F from './fixtures.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FONT = fs.readFileSync(path.join(HERE, 'vendor/inter-latin-wght-normal.woff2'))
export const PROJECT_REF = 'yclhzwghzrohusqxfasq'

function b64url(obj) {
  return Buffer.from(JSON.stringify(obj)).toString('base64url')
}

export function makeSession(persona) {
  const now = Math.floor(new Date('2026-09-26T04:00:00Z').getTime() / 1000)
  const exp = now + 60 * 60 * 24 * 365 * 5 // far future so no refresh is attempted
  const user = {
    id: persona.userId,
    aud: 'authenticated',
    role: 'authenticated',
    email: persona.email,
    email_confirmed_at: '2026-01-01T00:00:00Z',
    phone: '',
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: { full_name: persona.full_name },
    identities: [],
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-09-26T04:00:00Z',
    is_anonymous: false,
  }
  const access_token = `${b64url({ alg: 'HS256', typ: 'JWT' })}.${b64url({ sub: persona.userId, email: persona.email, role: 'authenticated', aud: 'authenticated', exp, iat: now, session_id: 'manual-shots' })}.c2lnbmF0dXJl`
  return { access_token, token_type: 'bearer', expires_in: exp - now, expires_at: exp, refresh_token: 'manual-shots-refresh', user }
}

// ---------- select parsing / embedding ----------
function splitTop(s) {
  const out = []
  let depth = 0
  let cur = ''
  for (const c of s) {
    if (c === '(') depth++
    if (c === ')') depth--
    if (c === ',' && depth === 0) {
      out.push(cur)
      cur = ''
    } else cur += c
  }
  if (cur.trim()) out.push(cur)
  return out.map((x) => x.trim()).filter(Boolean)
}

function parseSelect(sel) {
  const embeds = []
  for (const item of splitTop(sel || '*')) {
    const m = item.match(/^(?:([a-zA-Z_]+):)?([a-zA-Z_]+)(?:!([a-zA-Z_]+))?\((.*)\)$/s)
    if (m) embeds.push({ key: m[1] || m[2], rel: m[2], hint: m[3], inner: m[4] })
  }
  return embeds
}

const SINGULAR = { entities: 'entity', employees: 'employee', locations: 'location', positions: 'position', leave_types: 'leave_type', shifts: 'shift' }

function resolveEmbed(parentTable, row, rel) {
  const target = F.tables[rel]
  if (!target) return undefined
  let fk = `${SINGULAR[rel] ?? rel.replace(/s$/, '')}_id`
  if (parentTable === 'employees' && rel === 'locations') fk = 'home_location_id'
  if (fk in row) return target.find((t) => t.id === row[fk]) ?? null
  // one-to-many (parent id referenced by target)
  const back = `${SINGULAR[parentTable] ?? parentTable.replace(/s$/, '')}_id`
  if (target.length && back in target[0]) return target.filter((t) => t[back] === row.id)
  return null
}

function attach(table, rows, sel) {
  const embeds = parseSelect(sel)
  if (!embeds.length) return rows.map((r) => ({ ...r }))
  return rows.map((r) => {
    const out = { ...r }
    for (const e of embeds) {
      const v = resolveEmbed(table, r, e.rel)
      if (v === undefined) continue
      if (Array.isArray(v)) out[e.key] = attach(e.rel, v, e.inner)
      else out[e.key] = v ? attach(e.rel, [v], e.inner)[0] : null
    }
    return out
  })
}

// ---------- filters ----------
function cmp(val, op, arg) {
  const s = val === null || val === undefined ? null : String(val)
  switch (op) {
    case 'eq':
      return s === arg
    case 'neq':
      return s !== arg
    case 'gt':
      return s !== null && (isNum(s, arg) ? +s > +arg : s > arg)
    case 'gte':
      return s !== null && (isNum(s, arg) ? +s >= +arg : s >= arg)
    case 'lt':
      return s !== null && (isNum(s, arg) ? +s < +arg : s < arg)
    case 'lte':
      return s !== null && (isNum(s, arg) ? +s <= +arg : s <= arg)
    case 'in': {
      const list = arg.replace(/^\(|\)$/g, '').split(',').map((x) => x.replace(/^"|"$/g, ''))
      return s !== null && list.includes(s)
    }
    case 'is':
      if (arg === 'null') return val === null || val === undefined
      if (arg === 'true') return val === true
      if (arg === 'false') return val === false
      return false
    case 'ilike':
    case 'like': {
      const re = new RegExp('^' + arg.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/%/g, '.*') + '$', op === 'ilike' ? 'i' : '')
      return s !== null && re.test(s)
    }
    default:
      return true
  }
}
const isNum = (a, b) => /^-?\d+(\.\d+)?$/.test(a) && /^-?\d+(\.\d+)?$/.test(b)

function getPath(row, key) {
  const parts = key.split('.')
  let v = row
  for (const p of parts) {
    if (v === null || v === undefined) return { missing: true }
    v = v[p]
  }
  return { v }
}

function applyFilter(row, key, raw) {
  let neg = false
  let expr = raw
  if (expr.startsWith('not.')) {
    neg = true
    expr = expr.slice(4)
  }
  const dot = expr.indexOf('.')
  const op = expr.slice(0, dot)
  const arg = expr.slice(dot + 1)
  const { v, missing } = getPath(row, key)
  if (missing) return false
  const r = cmp(v, op, arg)
  return neg ? !r : r
}

function applyOr(row, expr) {
  const inner = expr.replace(/^\(|\)$/g, '')
  return splitTop(inner).some((cond) => {
    const [col, ...rest] = cond.split('.')
    return applyFilter(row, col, rest.join('.'))
  })
}

// ---------- RLS-like persona scoping ----------
function visibleEmployeeIds(p) {
  if (p.role === 'owner') return null
  if (p.role === 'staff') return new Set([p.employeeId])
  return new Set(F.employees.filter((e) => e.home_location_id === p.locationId || (p.role === 'entity_admin' && e.entity_id === p.entityId)).map((e) => e.id))
}

function scope(table, rows, p) {
  if (p.role === 'owner') return rows
  const ids = visibleEmployeeIds(p)
  const byEmp = (r) => ids.has(r.employee_id)
  switch (table) {
    case 'entities':
      return rows.filter((r) => r.id === p.entityId)
    case 'locations':
    case 'positions':
    case 'leave_types':
    case 'schedule_templates':
      return rows.filter((r) => r.entity_id === p.entityId)
    case 'employees':
      return rows.filter((r) => ids.has(r.id))
    case 'shifts':
      if (p.role === 'staff') return rows.filter((r) => (r.employee_id === p.employeeId || (r.status === 'open' && r.location_id === p.locationId)) && r.is_published)
      return rows.filter((r) => r.location_id === p.locationId)
    case 'shift_swap_requests':
      return rows.filter((r) => ids.has(r.requested_by) || ids.has(r.claimed_by))
    case 'payroll_runs':
    case 'payroll_run_totals':
    case 'payslips':
    case 'timesheet_entries':
    case 'payslip_deductions':
    case 'tips_pools':
    case 'audit_log':
    case 'employee_compensation':
    case 'employee_identity_documents':
      return []
    default:
      if (rows.length && 'employee_id' in rows[0]) return rows.filter(byEmp)
      if (rows.length && 'entity_id' in rows[0]) return rows.filter((r) => r.entity_id === p.entityId)
      return rows
  }
}

// ---------- RPCs ----------
function rpcHandlers(state) {
  const p = state.persona
  const empName = (id) => F.employees.find((e) => e.id === id)?.full_name
  return {
    has_interview_assignments: () => false,
    unread_notification_count: () => F.notifications[p.notif].filter((n) => !n.read_at).length,
    get_my_notifications: (a) => {
      let rows = F.notifications[p.notif].slice().sort((x, y) => y.created_at.localeCompare(x.created_at))
      if (a.p_unread_only) rows = rows.filter((n) => !n.read_at)
      if (a.p_before) rows = rows.filter((n) => n.created_at < a.p_before)
      return rows.slice(0, a.p_limit ?? 50)
    },
    mark_notification_read: () => ({ ok: true }),
    mark_all_notifications_read: () => ({ ok: true, updated: 0 }),
    get_owner_dashboard_kpis: () => F.owner_kpis,
    get_employee_completeness: (a) => F.completeness[a.p_employee_id] ?? F.defaultCompleteness,
    get_my_clock_status: () => {
      const sh = F.findShift(p.employeeId, F.TODAY)
      const loc = F.locations.find((l) => l.id === sh?.location_id)
      const pos = F.positions.find((x) => x.id === sh?.position_id)
      return {
        state: state.clockedIn ? 'clocked_in' : sh ? 'not_started' : 'no_shift',
        business_date: F.TODAY,
        server_time: new Date(state.nowIso).toISOString(),
        today_shift: sh
          ? { id: sh.id, shift_date: sh.shift_date, start_time: sh.start_time, end_time: sh.end_time, planned_start: `${F.TODAY}T05:00:00Z`, planned_end: `${F.TODAY}T13:00:00Z`, location_id: sh.location_id, location_name: loc?.name ?? null, position_title: pos?.title ?? null, status: sh.status }
          : null,
        attendance: state.clockedIn
          ? { id: '00000000-0000-4000-8000-a70000000777', shift_id: sh?.id ?? null, clock_in_at: state.clockInIso, clock_out_at: null, worked_minutes: null, late_minutes: 0, corrected: false }
          : null,
      }
    },
    get_my_attendance: () => F.mariaMyAttendance(state.clockedIn, state.clockInIso),
    clock_in: () => {
      state.clockedIn = true
      state.clockInIso = new Date(state.nowIso).toISOString()
      return { id: '00000000-0000-4000-8000-a70000000777', shift_id: F.findShift(p.employeeId, F.TODAY)?.id, clock_in_at: state.clockInIso, already_clocked_in: false }
    },
    get_location_attendance_overview: (a) =>
      F.payableForLocation(a.p_location_id, a.p_period_start, a.p_period_end).map((r) => ({
        shift_id: r.shift_id,
        employee_id: r.employee_id,
        shift_date: F.shifts.find((s) => s.id === r.shift_id).shift_date,
        planned_minutes: r.planned_minutes,
        default_payable_minutes: r.default_payable_minutes,
        final_payable_minutes: null,
        payable_status: 'pending',
        pending_adjustment: false,
      })),
    get_attendance_exceptions: (a) => F.attendanceExceptions(a.p_location_id),
    get_workflow_rules: (a) => F.workflow_rules.filter((r) => !a.p_entity_id || r.entity_id === a.p_entity_id),
    get_workflow_runs: (a) => F.workflow_runs.filter((r) => !a.p_entity_id || r.entity_id === a.p_entity_id),
    workflow_trigger_catalog: () => F.workflow_catalog,
    admin_list_user_access: (a) => F.user_access.filter((r) => !a.p_entity_id || r.entity_id === a.p_entity_id || r.role === 'owner'),
    get_audit_log: (a) => F.audit_log.filter((r) => !a.p_entity_id || r.entity_id === a.p_entity_id).slice(0, a.p_limit ?? 100),
    get_my_payslips: () => F.myPayslipsFor(p.employeeId),
    get_my_payslip: (a) => F.payslipDetail(a.p_payslip_id),
    get_payroll_payslip: (a) => F.payslipDetail(a.p_payslip_id),
    entity_admin_self_approval_enabled: () => false,
    get_documents_for_review: (a) =>
      F.employee_documents
        .filter((d) => visibleEmployeeIds(p)?.has(d.employee_id) ?? true)
        .map((d) => ({ ...d, employee_name: empName(d.employee_id) })),
    get_entity_dependency_summary: () => ({ active_employees: 5, future_shifts: 24, open_leave_requests: 1, draft_payroll_runs: 1 }),
  }
}

// ---------- router ----------
export async function installMock(page, persona, opts = {}) {
  const state = { persona, clockedIn: false, clockInIso: null, nowIso: opts.nowIso ?? '2026-09-26T10:15:00+04:00', unhandled: [] }

  await page.route('https://fonts.local/**', (route) => route.fulfill({ status: 200, body: FONT, contentType: 'font/woff2', headers: { 'access-control-allow-origin': '*' } }))
  await page.addInitScript(() => {
    const add = () => {
      const st = document.createElement('style')
      st.textContent = "@font-face{font-family:'Inter';font-style:normal;font-weight:100 900;font-display:block;src:url(https://fonts.local/inter.woff2) format('woff2');}"
      document.head.appendChild(st)
    }
    if (document.head) add()
    else document.addEventListener('DOMContentLoaded', add)
  })

  if (persona && opts.seedSession !== false) {
    const session = makeSession(persona)
    await page.addInitScript(
      ([key, value]) => {
        try {
          localStorage.setItem(key, value)
        } catch {
          /* ignore */
        }
      },
      [`sb-${PROJECT_REF}-auth-token`, JSON.stringify(session)]
    )
    await page.addInitScript(
      ([key, value]) => {
        try {
          if (!localStorage.getItem(key)) localStorage.setItem(key, value)
        } catch {
          /* ignore */
        }
      },
      ['ts-hr:last-entity-id', opts.entityId ?? F.ID.entTS]
    )
  }

  const handlers = rpcHandlers(state)
  const cors = {
    'access-control-allow-origin': '*',
    'access-control-allow-headers': '*',
    'access-control-allow-methods': 'GET,POST,PATCH,DELETE,HEAD,OPTIONS',
    'access-control-expose-headers': 'Content-Range, X-Total-Count',
  }
  const json = (route, body, status = 200, extra = {}) =>
    route.fulfill({ status, body: body === undefined ? '' : JSON.stringify(body), contentType: 'application/json', headers: { ...cors, ...extra } })

  await page.route('**/*.supabase.co/**', async (route) => {
    const req = route.request()
    const url = new URL(req.url())
    const method = req.method()
    if (method === 'OPTIONS') return route.fulfill({ status: 204, headers: cors })
    const p = url.pathname

    // ---- auth ----
    if (p.startsWith('/auth/v1/')) {
      if (p === '/auth/v1/user') return persona ? json(route, makeSession(persona).user) : json(route, { code: 401, msg: 'no session' }, 401)
      if (p === '/auth/v1/token') return persona ? json(route, makeSession(persona)) : json(route, { error: 'invalid_grant', error_description: 'Invalid login credentials' }, 400)
      if (p === '/auth/v1/logout') return route.fulfill({ status: 204, headers: cors })
      state.unhandled.push(`${method} ${p}`)
      return json(route, {})
    }

    // ---- rpc ----
    if (p.startsWith('/rest/v1/rpc/')) {
      const name = p.slice('/rest/v1/rpc/'.length)
      let args = {}
      try {
        args = req.postDataJSON() ?? {}
      } catch {
        args = {}
      }
      const h = handlers[name]
      if (!h) {
        state.unhandled.push(`RPC ${name}`)
        process.stderr.write(`[mock] UNHANDLED RPC ${name} ${JSON.stringify(args)}\n`)
        return json(route, { code: 'PGRST202', message: `Could not find the function public.${name}` }, 404)
      }
      const out = h(args)
      return json(route, out === undefined ? null : out)
    }

    // ---- tables ----
    if (p.startsWith('/rest/v1/')) {
      const table = p.slice('/rest/v1/'.length)
      if (!persona) {
        state.unhandled.push(`${method} ${table} (no persona)`)
        return json(route, [])
      }
      if (method === 'POST' || method === 'PATCH' || method === 'DELETE') {
        process.stderr.write(`[mock] write ${method} ${table} ignored\n`)
        return json(route, null, 201)
      }
      if (table === 'profiles') {
        const prof = {
          id: persona.userId,
          full_name: persona.full_name,
          role: persona.role,
          entity_id: persona.entityId,
          location_id: persona.locationId,
          created_at: '2026-01-01T00:00:00Z',
          is_active: true,
        }
        return json(route, req.headers()['accept']?.includes('vnd.pgrst.object') ? prof : [prof])
      }
      const base = F.tables[table]
      if (!base) {
        state.unhandled.push(`TABLE ${table}`)
        process.stderr.write(`[mock] UNHANDLED TABLE ${table} ${url.search}\n`)
        return json(route, [])
      }
      const sp = url.searchParams
      let rows = attach(table, scope(table, base, persona), sp.get('select') ?? '*')
      for (const [k, v] of sp.entries()) {
        if (['select', 'order', 'limit', 'offset', 'on_conflict', 'columns'].includes(k)) continue
        if (k === 'or') rows = rows.filter((r) => applyOr(r, v))
        else rows = rows.filter((r) => applyFilter(r, k, v))
      }
      const order = sp.get('order')
      if (order) {
        const keys = order.split(',').map((o) => {
          const [col, dir] = o.split('.')
          return { col, desc: dir === 'desc' }
        })
        rows.sort((a, b) => {
          for (const { col, desc } of keys) {
            const x = a[col]
            const y = b[col]
            if (x === y) continue
            if (x === null || x === undefined) return 1
            if (y === null || y === undefined) return -1
            const c = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y))
            return desc ? -c : c
          }
          return 0
        })
      }
      const total = rows.length
      const limit = sp.get('limit')
      if (limit) rows = rows.slice(0, Number(limit))
      const headers = { 'content-range': total ? `0-${rows.length - 1}/${total}` : `*/${total}` }
      if (method === 'HEAD') return route.fulfill({ status: 200, headers: { ...cors, ...headers } })
      const accept = req.headers()['accept'] ?? ''
      if (accept.includes('vnd.pgrst.object')) {
        if (rows.length !== 1) return json(route, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: `${rows.length} rows`, hint: null }, 406)
        return json(route, rows[0], 200, headers)
      }
      return json(route, rows, 200, headers)
    }

    state.unhandled.push(`${method} ${p}`)
    process.stderr.write(`[mock] UNHANDLED ${method} ${url.href}\n`)
    return json(route, {}, 404)
  })

  return state
}
