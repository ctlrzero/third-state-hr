// invite-user — sends (or re-sends) the Supabase invitation email for an
// email address that already has an access grant.
//
// POST { email } with the caller's user JWT in Authorization (verify_jwt on).
//
// Authorisation (all server-side; nothing from the body is trusted except email):
//   * caller has an ACTIVE profile with role owner, or role entity_admin and
//     the grant's entity_id equals the caller's entity_id;
//   * the email has a pending access_grants row (the normal case) or an
//     applied one whose invite has not been accepted yet (re-send). No grant →
//     409 "Grant access first". The role/scope itself is only ever set by
//     admin_grant_access(); this function never changes access.
//
// The on_auth_user_created trigger applies the pending grant when the invite
// creates the auth user, so the invitee lands in the right workspace.
//
// Responses: 200 {status:'invited'|'already_registered', message}
//            4xx/5xx {error, message}
//
// Uses SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (injected by Supabase) and
// optional SITE_URL (default https://hr.thirdstate.ae). Keys are never logged.
import { createClient } from 'npm:@supabase/supabase-js@2'

const SITE_URL = (Deno.env.get('SITE_URL') ?? 'https://hr.thirdstate.ae').replace(/\/+$/, '')
const ALLOWED_ORIGINS = new Set(['https://hr.thirdstate.ae', 'http://localhost:5173', SITE_URL])
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/

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
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json' },
  })
}

function fail(req: Request, status: number, error: string, message: string): Response {
  return json(req, status, { error, message })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(req) })
  if (req.method !== 'POST') return fail(req, 405, 'method_not_allowed', 'Use POST.')

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) return fail(req, 500, 'misconfigured', 'The invite service is not configured.')

  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim()
  if (!jwt) return fail(req, 401, 'unauthenticated', 'Sign in again and retry.')

  let email = ''
  try {
    const body = await req.json()
    email = String(body?.email ?? '').trim().toLowerCase()
  } catch {
    return fail(req, 400, 'bad_request', 'Send a JSON body with an email address.')
  }
  if (!EMAIL_RE.test(email)) return fail(req, 400, 'invalid_email', 'Enter a valid email address.')

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  })

  // 1. Who is calling?
  const { data: userData, error: userError } = await admin.auth.getUser(jwt)
  const caller = userData?.user
  if (userError || !caller) return fail(req, 401, 'unauthenticated', 'Your session has expired. Sign in again and retry.')

  const { data: profile, error: profileError } = await admin
    .from('profiles')
    .select('role, entity_id, is_active')
    .eq('id', caller.id)
    .maybeSingle()
  if (profileError) return fail(req, 500, 'lookup_failed', 'Could not check your access. Please try again.')
  if (!profile || profile.is_active !== true || !['owner', 'entity_admin'].includes(profile.role)) {
    return fail(req, 403, 'forbidden', 'Only an owner or entity admin can send invitations.')
  }

  // 2. There must be a grant for this email: pending, else the latest applied
  //    one (re-send to someone who has not accepted yet).
  const { data: grants, error: grantError } = await admin
    .from('access_grants')
    .select('id, entity_id, location_id, employee_id, status, granted_at')
    .eq('email', email) // stored lower(btrim()) by a CHECK constraint
    .in('status', ['pending', 'applied'])
    .order('granted_at', { ascending: false })
  if (grantError) return fail(req, 500, 'lookup_failed', 'Could not look up the access grant. Please try again.')
  const grant = grants?.find((g) => g.status === 'pending') ?? grants?.[0]
  if (!grant) {
    return fail(req, 409, 'no_pending_grant', 'Grant access first: there is no pending access grant for this email.')
  }

  // 3. Scope: entity admins only for grants in their own entity.
  if (profile.role !== 'owner' && (!profile.entity_id || grant.entity_id !== profile.entity_id)) {
    return fail(req, 403, 'forbidden', 'You can only invite people to your own entity.')
  }

  // 4. Send. GoTrue re-sends to an invited-but-unconfirmed user and refuses a
  //    confirmed one (email_exists) — that person already has a login.
  const { error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: `${SITE_URL}/set-password`,
  })
  if (inviteError) {
    const code = (inviteError as { code?: string }).code ?? ''
    const status = (inviteError as { status?: number }).status ?? 0
    const msg = inviteError.message ?? ''
    if (code === 'email_exists' || code === 'user_already_exists' || /already (been )?registered|already exists/i.test(msg)) {
      return json(req, 200, {
        status: 'already_registered',
        message: 'This person already has a login — their access has been applied. They can sign in (or use "Forgot password?").',
      })
    }
    if (status === 429 || /rate limit|over_email_send_rate_limit|security purposes/i.test(`${code} ${msg}`)) {
      return fail(req, 429, 'rate_limited', 'Too many emails have been sent recently. Wait a few minutes and try again.')
    }
    console.error('invite-user: invite failed', { code, status })
    return fail(req, 502, 'invite_failed', 'The invitation email could not be sent. Please try again later.')
  }

  // 5. Audit (best-effort: the email has already gone out).
  const { error: auditError } = await admin.from('audit_log').insert({
    table_name: 'access_grants',
    record_id: grant.id,
    changed_by: caller.id,
    action: 'user_invited',
    new_value: { email },
    entity_id: grant.entity_id,
    location_id: grant.location_id,
    employee_id: grant.employee_id,
  })
  if (auditError) console.error('invite-user: audit insert failed', { code: auditError.code })

  return json(req, 200, { status: 'invited', message: `Invitation email sent to ${email}.` })
})
