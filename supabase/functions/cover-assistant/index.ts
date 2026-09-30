// cover-assistant — P2-1 absence cover.
//
// POST { shift_id } with the caller's user JWT in Authorization (verify_jwt on).
//
// Runs entirely as the caller: it reads cover candidates through suggest_shift_cover (which enforces who may
// find cover for that branch) and stores the result through log_ai_suggestion. It never uses the service
// role and never changes a shift — the manager reviews the draft and sends it with send_shift_offer.
//
// With ANTHROPIC_API_KEY set, Claude ranks the best three candidates (from the eligible list only) and drafts
// a short offer message. Without it, the rule-based order and a plain template are returned (ai:false).
// Prompts contain names, positions, the shift and this week's hours — never pay.
//
// Response: 200 { suggestion_id, ai, model, message, ranking: [{employee_id, name, reason}], candidates, not_eligible }
import { createClient } from 'npm:@supabase/supabase-js@2'
import { aiConfig, aiText, firstJson, type AiConfig } from '../_shared/ai.ts'

const ALLOWED_ORIGINS = new Set(['https://hr.thirdstate.ae', 'http://localhost:5173'])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

interface Candidate {
  employee_id: string
  name: string
  home_location: string | null
  position: string | null
  home_branch: boolean
  hours_this_week: number
  days_this_week: number
}
interface CoverData {
  shift: { id: string; shift_date: string; start_time: string; end_time: string; location: string | null; position: string | null; employee_id: string | null }
  candidates: Candidate[]
  not_eligible: { employee_id: string; name: string; reason: string }[]
}
interface Ranked {
  employee_id: string
  name: string
  reason: string
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

const hhmm = (t: string) => t.slice(0, 5)
function dayLabel(iso: string): string {
  const d = new Date(iso + 'T00:00:00Z')
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
  return `${days[d.getUTCDay()]} ${d.getUTCDate()} ${months[d.getUTCMonth()]}`
}

function ruleBased(data: CoverData): { ranking: Ranked[]; message: string } {
  const s = data.shift
  const ranking = data.candidates.slice(0, 3).map((c) => ({
    employee_id: c.employee_id,
    name: c.name,
    reason: `${c.home_branch ? 'Works at this branch' : `Based at ${c.home_location ?? 'another branch'}`} · ${c.hours_this_week} h on ${c.days_this_week} day${c.days_this_week === 1 ? '' : 's'} this week`,
  }))
  const message =
    `Hi, can you cover a shift on ${dayLabel(s.shift_date)}, ${hhmm(s.start_time)}–${hhmm(s.end_time)}` +
    `${s.location ? ` at ${s.location}` : ''}? Please accept or decline in the HR app. Thank you!`
  return { ranking, message }
}

async function askAi(cfg: AiConfig, data: CoverData, absentName: string | null): Promise<{ ranking: Ranked[]; message: string } | null> {
  const s = data.shift
  const pool = data.candidates.slice(0, 12)
  const facts = {
    shift: {
      day: dayLabel(s.shift_date),
      time: `${hhmm(s.start_time)}–${hhmm(s.end_time)}`,
      branch: s.location,
      position: s.position,
      usually_worked_by: absentName,
    },
    eligible_candidates: pool.map((c) => ({
      id: c.employee_id,
      name: c.name,
      position: c.position,
      works_at_this_branch: c.home_branch,
      home_branch: c.home_location,
      hours_already_this_week: c.hours_this_week,
      days_already_this_week: c.days_this_week,
    })),
  }
  const system =
    'You help a café manager in the UAE find cover for a shift. Everyone listed is already eligible under the ' +
    'scheduling rules (not on leave, available, within weekly limits). Rank at most three people, preferring the ' +
    'same position, the same branch, and fewer hours already this week so work is shared fairly. Give each a short ' +
    'factual reason (max 15 words) using only the facts provided. Then write one friendly, professional message ' +
    '(max 280 characters, plain English, no emojis) the manager can send asking them to cover; include the day, ' +
    'time and branch and ask them to accept or decline in the HR app. Do not mention other people or anyone\'s ' +
    'absence reason. Reply with JSON only: {"ranking":[{"id":"...","reason":"..."}],"message":"..."}'
  const text = await aiText(cfg, system, JSON.stringify(facts), 600)
  if (!text) return null
  const parsed = firstJson<{ ranking?: { id?: string; reason?: string }[]; message?: string }>(text)
  if (!parsed) return null
  // Keep only people from the eligible list; the model can't add anyone.
  const byId = new Map(pool.map((c) => [c.employee_id, c]))
  const seen = new Set<string>()
  const ranking: Ranked[] = []
  for (const r of parsed.ranking ?? []) {
    const c = r.id ? byId.get(r.id) : undefined
    if (!c || seen.has(c.employee_id) || ranking.length >= 3) continue
    seen.add(c.employee_id)
    ranking.push({ employee_id: c.employee_id, name: c.name, reason: String(r.reason ?? '').slice(0, 160) })
  }
  const message = String(parsed.message ?? '').trim().slice(0, 600)
  if (!ranking.length || !message) return null
  return { ranking, message }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) })
  if (req.method !== 'POST') return json(req, 405, { error: 'method_not_allowed', message: 'Use POST' })

  const auth = req.headers.get('Authorization') ?? ''
  if (!auth.startsWith('Bearer ')) return json(req, 401, { error: 'unauthorized', message: 'Sign in again' })

  let shiftId = ''
  try {
    shiftId = String(((await req.json()) as { shift_id?: string }).shift_id ?? '')
  } catch {
    /* fall through */
  }
  if (!UUID_RE.test(shiftId)) return json(req, 400, { error: 'bad_request', message: 'shift_id is required' })

  // Caller's own session: every read and write below is checked by the database as that user.
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: cover, error: coverError } = await supabase.rpc('suggest_shift_cover', { p_shift_id: shiftId })
  if (coverError) return json(req, coverError.code === '42501' ? 403 : 400, { error: 'cover_failed', message: coverError.message })
  const data = cover as CoverData

  let absentName: string | null = null
  if (data.shift.employee_id) {
    // RLS decides whether the caller may see this name (a supervisor may not); null is fine.
    const { data: emp } = await supabase.from('employees').select('full_name, preferred_name').eq('id', data.shift.employee_id).maybeSingle()
    const row = emp as { full_name: string; preferred_name: string | null } | null
    absentName = row ? (row.preferred_name ?? row.full_name) : null
  }

  const cfg = aiConfig('COVER_ASSISTANT_MODEL')
  let result: { ranking: Ranked[]; message: string } | null = null
  let ai = false
  if (cfg && data.candidates.length) {
    try {
      result = await askAi(cfg, data, absentName)
      ai = !!result
    } catch (e) {
      console.error('cover-assistant ai failed', (e as Error).message)
    }
  }
  if (!result) result = ruleBased(data)

  const { data: suggestionId, error: logError } = await supabase.rpc('log_ai_suggestion', {
    p_kind: 'cover_offer',
    p_shift_id: shiftId,
    p_inputs: { shift: data.shift, candidates: data.candidates.slice(0, 12), absent: absentName },
    p_output: { ai, ranking: result.ranking, message: result.message },
    p_model: ai && cfg ? `${cfg.provider}:${cfg.model}` : 'rules',
  })
  if (logError) return json(req, 400, { error: 'log_failed', message: logError.message })

  return json(req, 200, {
    suggestion_id: suggestionId,
    ai,
    model: ai && cfg ? `${cfg.provider}:${cfg.model}` : null,
    message: result.message,
    ranking: result.ranking,
    candidates: data.candidates,
    not_eligible: data.not_eligible,
  })
})
