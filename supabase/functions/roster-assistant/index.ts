// roster-assistant — P2-4 "Why this roster".
//
// POST { entity_id, period_start, period_end, location_ids|null } with the caller's user JWT (verify_jwt on).
//
// Runs as the caller: it re-runs the read-only propose_auto_schedule preview (so the summary always matches
// what the database would create, and access is checked there), summarises it, and stores the result with
// log_roster_summary. It never creates or changes shifts — the manager still presses Create drafts and
// Publish week.
//
// With ANTHROPIC_API_KEY set, Claude writes a short plain-English explanation (headline + up to 5 points).
// Without it, a rule-based summary is returned (ai:false). Prompts contain names, branches, shift times and
// hours — never pay.
//
// Response: 200 { suggestion_id, ai, model, headline, points: string[] }
import { createClient } from 'npm:@supabase/supabase-js@2'
import { aiConfig, aiText, firstJson, type AiConfig } from '../_shared/ai.ts'

const ALLOWED_ORIGINS = new Set(['https://hr.thirdstate.ae', 'http://localhost:5173'])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

interface PlanShift {
  shift_date: string
  location: string
  employee_id: string
  employee: string
  start_time: string
  end_time: string
  break_minutes: number
  cross_branch: boolean
  home_location: string | null
}
interface PlanGap {
  shift_date: string
  location: string
  role: string | null
  start_time: string
  end_time: string
}
interface Plan {
  period_start: string
  period_end: string
  shifts: PlanShift[]
  unfilled: PlanGap[]
  warnings: string[]
  summary: { planned: number; cross_branch: number; unfilled: number; planned_hours: number }
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

const toMin = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5))
function shiftHours(s: PlanShift): number {
  let m = toMin(s.end_time) - toMin(s.start_time)
  if (m <= 0) m += 1440
  return Math.max(0, m - (s.break_minutes ?? 0)) / 60
}
const round1 = (n: number) => Math.round(n * 10) / 10

function facts(plan: Plan) {
  const people = new Map<string, { name: string; shifts: number; hours: number; days: Set<string>; moved: Set<string> }>()
  for (const s of plan.shifts) {
    const p = people.get(s.employee_id) ?? { name: s.employee, shifts: 0, hours: 0, days: new Set(), moved: new Set() }
    p.shifts += 1
    p.hours += shiftHours(s)
    p.days.add(s.shift_date)
    if (s.cross_branch) p.moved.add(`${s.location} (from ${s.home_location ?? 'another branch'})`)
    people.set(s.employee_id, p)
  }
  const perPerson = [...people.values()]
    .map((p) => ({ name: p.name, shifts: p.shifts, hours: round1(p.hours), days: p.days.size, moved_to: [...p.moved] }))
    .sort((a, b) => b.hours - a.hours)
  const gaps = plan.unfilled.map((g) => `${g.shift_date} ${g.start_time.slice(0, 5)}–${g.end_time.slice(0, 5)} at ${g.location}${g.role ? ` (${g.role})` : ''}`)
  return { period: `${plan.period_start} to ${plan.period_end}`, totals: plan.summary, per_person: perPerson, unfilled: gaps, warnings: plan.warnings }
}

function ruleBased(f: ReturnType<typeof facts>): { headline: string; points: string[] } {
  const t = f.totals
  const headline =
    t.unfilled > 0
      ? `${t.planned} shifts planned; ${t.unfilled} still need someone.`
      : `${t.planned} shifts planned and every opening hour is covered.`
  const points: string[] = []
  if (f.per_person.length) {
    const top = f.per_person[0]
    const low = f.per_person[f.per_person.length - 1]
    points.push(`${f.per_person.length} people work ${t.planned_hours} hours in total.`)
    if (f.per_person.length > 1) points.push(`Most hours: ${top.name} (${top.hours} h). Fewest: ${low.name} (${low.hours} h).`)
  }
  const moved = f.per_person.filter((p) => p.moved_to.length)
  if (moved.length) points.push(`Working at another branch: ${moved.map((p) => `${p.name} → ${p.moved_to.join(', ')}`).join('; ')}.`)
  if (f.unfilled.length) points.push(`Still open: ${f.unfilled.slice(0, 4).join('; ')}${f.unfilled.length > 4 ? ` and ${f.unfilled.length - 4} more` : ''}.`)
  if (f.warnings.length) points.push(f.warnings[0])
  return { headline, points: points.slice(0, 5) }
}

async function askAi(cfg: AiConfig, f: ReturnType<typeof facts>): Promise<{ headline: string; points: string[] } | null> {
  const system =
    'You explain an automatically planned café staff roster to a busy branch manager in the UAE. Use only the facts ' +
    'given. Write a one-sentence headline (max 20 words), then at most 5 short bullet points (max 25 words each) in ' +
    'plain English: whether every hour is covered and which gaps remain, whether hours are shared fairly (name the ' +
    'most and least), who is working at another branch, and anything the manager should check before publishing. ' +
    'No jargon, no emojis, no advice about pay. Reply with JSON only: {"headline":"...","points":["..."]}'
  const text = await aiText(cfg, system, JSON.stringify(f), 700)
  if (!text) return null
  const parsed = firstJson<{ headline?: unknown; points?: unknown }>(text)
  if (!parsed) return null
  {
    const headline = String(parsed.headline ?? '').trim().slice(0, 200)
    const points = (Array.isArray(parsed.points) ? parsed.points : []).map((p) => String(p).trim().slice(0, 240)).filter(Boolean).slice(0, 5)
    return headline ? { headline, points } : null
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) })
  if (req.method !== 'POST') return json(req, 405, { error: 'method_not_allowed', message: 'Use POST' })
  const auth = req.headers.get('Authorization') ?? ''
  if (!auth.startsWith('Bearer ')) return json(req, 401, { error: 'unauthorized', message: 'Sign in again' })

  let body: { entity_id?: string; period_start?: string; period_end?: string; location_ids?: unknown } = {}
  try {
    body = await req.json()
  } catch {
    /* validated below */
  }
  const entityId = String(body.entity_id ?? '')
  const start = String(body.period_start ?? '')
  const end = String(body.period_end ?? '')
  const locationIds = Array.isArray(body.location_ids) ? body.location_ids.map(String).filter((x) => UUID_RE.test(x)) : null
  if (!UUID_RE.test(entityId) || !DATE_RE.test(start) || !DATE_RE.test(end)) {
    return json(req, 400, { error: 'bad_request', message: 'entity_id, period_start and period_end are required' })
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data, error } = await supabase.rpc('propose_auto_schedule', {
    p_entity_id: entityId,
    p_period_start: start,
    p_period_end: end,
    p_location_ids: locationIds && locationIds.length ? locationIds : null,
  })
  if (error) return json(req, error.code === '42501' ? 403 : 400, { error: 'plan_failed', message: error.message })
  const f = facts(data as Plan)

  const cfg = aiConfig('ROSTER_ASSISTANT_MODEL')
  let result: { headline: string; points: string[] } | null = null
  let ai = false
  if (cfg) {
    try {
      result = await askAi(cfg, f)
      ai = !!result
    } catch (e) {
      console.error('roster-assistant ai failed', (e as Error).message)
    }
  }
  if (!result) result = ruleBased(f)

  const { data: suggestionId, error: logError } = await supabase.rpc('log_roster_summary', {
    p_entity_id: entityId,
    p_inputs: f,
    p_output: { ai, ...result },
    p_model: ai && cfg ? `${cfg.provider}:${cfg.model}` : 'rules',
  })
  if (logError) return json(req, 400, { error: 'log_failed', message: logError.message })

  return json(req, 200, { suggestion_id: suggestionId, ai, model: ai && cfg ? `${cfg.provider}:${cfg.model}` : null, ...result })
})
