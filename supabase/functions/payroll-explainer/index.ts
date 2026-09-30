// payroll-explainer — P2-3 "What changed since last month".
//
// POST { period_id } with the caller's user JWT (verify_jwt on).
//
// Runs as the caller: get_payroll_changes (needs payroll view_pay) returns each person's pay lines this month
// vs the previous regular month. With ANTHROPIC_API_KEY set, Claude writes a short month summary and one
// plain sentence per person whose pay changed. Pay amounts ARE sent — the owner approved this on 2026-09-30.
// Without a key, rule-based sentences are returned (ai:false). Stored with log_payroll_explanation.
// Read-only: it never changes payroll.
//
// Response: 200 { suggestion_id, ai, model, summary: string[], people: [{employee_id, name, sentence}] }
import { createClient } from 'npm:@supabase/supabase-js@2'

const MODEL = Deno.env.get('PAYROLL_EXPLAINER_MODEL') ?? 'claude-sonnet-5-5'
const ALLOWED_ORIGINS = new Set(['https://hr.thirdstate.ae', 'http://localhost:5173'])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

interface Change {
  kind: string
  code: string
  label: string
  now: number
  prev: number
  change: number
  explanation: string | null
}
interface Person {
  employee_id: string
  name: string
  net_now: number
  net_prev: number | null
  net_change: number
  new_this_month: boolean
  changes: Change[]
}
interface Changes {
  label: string
  previous_label: string | null
  currency: string
  employees: Person[]
  left_since_last_month: { employee_id: string; name: string; net_prev: number }[]
  totals: { net_now: number; net_prev: number }
}
interface Sentence {
  employee_id: string
  name: string
  sentence: string
}

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin') ?? ''
  return {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.has(origin) ? origin : 'https://hr.thirdstate.ae',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  }
}
function json(req: Request, status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders(req), 'Content-Type': 'application/json' } })
}

const money = (n: number, cur: string) => `${cur} ${Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
const signed = (n: number, cur: string) => `${n >= 0 ? '+' : '−'}${money(Math.abs(n), cur)}`

function ruleBased(c: Changes): { summary: string[]; people: Sentence[] } {
  const cur = c.currency
  const diff = Number(c.totals.net_now) - Number(c.totals.net_prev)
  const summary: string[] = []
  if (c.previous_label) {
    summary.push(`Total net pay ${money(c.totals.net_now, cur)}, ${signed(diff, cur)} compared with ${c.previous_label}.`)
  } else {
    summary.push(`Total net pay ${money(c.totals.net_now, cur)}. There is no earlier month to compare with.`)
  }
  const joiners = c.employees.filter((p) => p.new_this_month)
  if (joiners.length) summary.push(`New this month: ${joiners.map((p) => p.name).join(', ')}.`)
  if (c.left_since_last_month.length) summary.push(`Paid last month but not this month: ${c.left_since_last_month.map((p) => p.name).join(', ')}.`)
  const people = c.employees
    .filter((p) => p.new_this_month || Number(p.net_change) !== 0)
    .map((p) => {
      if (p.new_this_month) return { employee_id: p.employee_id, name: p.name, sentence: `First payroll here: net ${money(p.net_now, cur)}.` }
      const top = p.changes.slice(0, 3).map((ch) => `${ch.label} ${signed(Number(ch.change), cur)}`)
      return {
        employee_id: p.employee_id,
        name: p.name,
        sentence: `Net ${signed(Number(p.net_change), cur)} (${money(p.net_prev ?? 0, cur)} → ${money(p.net_now, cur)})${top.length ? `: ${top.join(', ')}` : ''}.`,
      }
    })
  return { summary, people }
}

async function askClaude(apiKey: string, c: Changes): Promise<{ summary: string[]; people: Sentence[] } | null> {
  const changed = c.employees.filter((p) => p.new_this_month || Number(p.net_change) !== 0).slice(0, 60)
  const facts = {
    month: c.label,
    compared_with: c.previous_label,
    currency: c.currency,
    totals: c.totals,
    left_since_last_month: c.left_since_last_month.map((p) => p.name),
    people: changed.map((p) => ({
      id: p.employee_id,
      name: p.name,
      new_this_month: p.new_this_month,
      net_prev: p.net_prev,
      net_now: p.net_now,
      line_changes: p.changes.slice(0, 8).map((ch) => ({ line: ch.label, kind: ch.kind, before: ch.prev, now: ch.now, note: ch.explanation })),
    })),
  }
  const system =
    'You explain a café payroll in the UAE to its owner, who is not a payroll specialist. Use only the facts given; ' +
    'never invent reasons. Deductions are shown as positive amounts that reduce net pay. Write (1) a month summary of ' +
    'at most 4 short points (total change, main reasons, anyone new or missing), and (2) for each person listed, one ' +
    'plain sentence (max 30 words) saying why their net pay changed, with the amounts and currency. Short part-month ' +
    'or prorated months, overtime, deductions and corrections are the usual reasons — use the line notes. No advice, no ' +
    'emojis. Reply with JSON only: {"summary":["..."],"people":[{"id":"...","sentence":"..."}]}'
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: MODEL, max_tokens: 2000, system, messages: [{ role: 'user', content: JSON.stringify(facts) }] }),
  })
  if (!res.ok) {
    console.error('anthropic error', res.status)
    return null
  }
  const body = (await res.json()) as { content?: { type: string; text?: string }[] }
  const text = (body.content ?? []).filter((x) => x.type === 'text').map((x) => x.text ?? '').join('')
  const match = text.match(/\{[\s\S]*\}/)
  if (!match) return null
  try {
    const parsed = JSON.parse(match[0]) as { summary?: unknown; people?: { id?: string; sentence?: string }[] }
    const byId = new Map(changed.map((p) => [p.employee_id, p]))
    const people: Sentence[] = []
    for (const s of parsed.people ?? []) {
      const p = s.id ? byId.get(s.id) : undefined
      if (!p || !s.sentence) continue
      people.push({ employee_id: p.employee_id, name: p.name, sentence: String(s.sentence).trim().slice(0, 300) })
    }
    const summary = (Array.isArray(parsed.summary) ? parsed.summary : []).map((x) => String(x).trim().slice(0, 240)).filter(Boolean).slice(0, 4)
    return summary.length ? { summary, people } : null
  } catch {
    return null
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) })
  if (req.method !== 'POST') return json(req, 405, { error: 'method_not_allowed', message: 'Use POST' })
  const auth = req.headers.get('Authorization') ?? ''
  if (!auth.startsWith('Bearer ')) return json(req, 401, { error: 'unauthorized', message: 'Sign in again' })

  let periodId = ''
  try {
    periodId = String(((await req.json()) as { period_id?: string }).period_id ?? '')
  } catch {
    /* validated below */
  }
  if (!UUID_RE.test(periodId)) return json(req, 400, { error: 'bad_request', message: 'period_id is required' })

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data, error } = await supabase.rpc('get_payroll_changes', { p_period_id: periodId })
  if (error) return json(req, error.code === '42501' ? 403 : 400, { error: 'changes_failed', message: error.message })
  const c = data as Changes

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY')
  let result: { summary: string[]; people: Sentence[] } | null = null
  let ai = false
  if (apiKey) {
    try {
      result = await askClaude(apiKey, c)
      ai = !!result
    } catch (e) {
      console.error('payroll-explainer ai failed', (e as Error).message)
    }
  }
  if (!result) result = ruleBased(c)

  const { data: suggestionId, error: logError } = await supabase.rpc('log_payroll_explanation', {
    p_period_id: periodId,
    p_inputs: c,
    p_output: { ai, ...result },
    p_model: ai ? MODEL : 'rules',
  })
  if (logError) return json(req, 400, { error: 'log_failed', message: logError.message })

  return json(req, 200, { suggestion_id: suggestionId, ai, model: ai ? MODEL : null, ...result })
})
