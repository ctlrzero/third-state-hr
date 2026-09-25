#!/usr/bin/env node
// Negative-access tests against the real Supabase API (PostgREST + GoTrue).
//
//   npm run test:access
//
// Logs in as the UAT personas (uat.*@example.com, UAT Entity A/B only) and
// asserts that RLS / RPC guards deny what they must. Reads VITE_SUPABASE_URL
// and VITE_SUPABASE_ANON_KEY from the environment or ./.env. The UAT password
// defaults to the TS-HR test password; override with UAT_PASSWORD.
//
// The only write it performs is a temporary revoke + re-grant of
// uat.employee.b (restored in a finally block).
import { createClient } from '@supabase/supabase-js'
import { readFileSync, existsSync } from 'node:fs'

if (existsSync('.env')) {
  for (const line of readFileSync('.env', 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/)
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^['"]|['"]$/g, '')
  }
}
const URL = process.env.VITE_SUPABASE_URL
const KEY = process.env.VITE_SUPABASE_ANON_KEY
const PASSWORD = process.env.UAT_PASSWORD ?? 'TSHR-uat-2026!'
if (!URL || !KEY) {
  console.error('VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY missing')
  process.exit(2)
}

const EA = 'a0000000-0000-4000-8000-000000000001'
const EB = 'a0000000-0000-4000-8000-000000000002'
const LOC_A2 = 'a0000000-0000-4000-8000-000000000012'
const EMP = {
  a: 'a0000000-0000-4000-8000-000000000031',
  b: 'a0000000-0000-4000-8000-000000000032',
  c: 'a0000000-0000-4000-8000-000000000033',
  lmA: 'a0000000-0000-4000-8000-000000000034',
}
const FIXTURE = {
  pendingLeaveA: 'a0000000-0000-4000-8000-000000000101',
  renewalDocA: 'a0000000-0000-4000-8000-000000000112',
  draftRunA: 'a0000000-0000-4000-8000-000000000202',
}

const results = []
const record = (name, pass, detail = '') => {
  results.push({ name, pass, detail })
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`)
}

const newClient = () =>
  createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } })

async function login(persona) {
  const client = newClient()
  const email = `uat.${persona}@example.com`
  const { data, error } = await client.auth.signInWithPassword({ email, password: PASSWORD })
  if (error) throw new Error(`login ${email}: ${error.message}`)
  return { client, user: data.user }
}

// Denied = error, or zero rows. rowFilter(q) narrows the query.
async function expectNoRows(name, client, table, rowFilter = (q) => q) {
  const { data, error } = await rowFilter(client.from(table).select('*'))
  if (error) return record(name, true, `denied: ${error.code ?? ''} ${error.message}`)
  return record(name, (data ?? []).length === 0, `${(data ?? []).length} row(s)`)
}

async function expectRpcDenied(name, client, fn, args = {}) {
  const { data, error } = await client.rpc(fn, args)
  if (error) return record(name, true, `denied: ${error.code ?? ''} ${error.message}`)
  const empty = data == null || (Array.isArray(data) && data.length === 0)
  return record(name, empty, empty ? 'empty result' : `returned data: ${JSON.stringify(data).slice(0, 120)}`)
}

async function expectOnlyOwn(name, client, table, ownEmployeeId) {
  const { data, error } = await client.from(table).select('employee_id')
  if (error) return record(name, true, `denied: ${error.message}`)
  const foreign = (data ?? []).filter((r) => r.employee_id !== ownEmployeeId)
  return record(name, foreign.length === 0, `${data.length} row(s), ${foreign.length} foreign`)
}

async function main() {
  // ---------------------------------------------------------------- logins
  const personas = ['owner', 'entityadmin.a', 'entityadmin.b', 'locationmanager.a', 'locationmanager.b',
    'employee.a', 'employee.b', 'employee.c']
  const S = {}
  for (const p of personas) {
    try {
      S[p] = await login(p)
      record(`login ${p}`, true)
    } catch (e) {
      record(`login ${p}`, false, e.message)
    }
  }
  if (Object.keys(S).length !== personas.length) return

  // ------------------------------------- location manager: no pay/identity
  const lm = S['locationmanager.a'].client
  await expectNoRows('LM: employee_compensation', lm, 'employee_compensation')
  await expectOnlyOwn('LM: payslips (no other employees)', lm, 'payslips', EMP.lmA)
  await expectNoRows('LM: payroll_runs', lm, 'payroll_runs')
  await expectNoRows('LM: employee_identity_documents', lm, 'employee_identity_documents')
  await expectNoRows('LM: offers', lm, 'offers')
  await expectNoRows('LM: payslip_deductions (others)', lm, 'payslip_deductions', (q) => q.neq('employee_id', EMP.lmA))
  await expectNoRows('LM: timesheet_entries', lm, 'timesheet_entries', (q) => q.neq('employee_id', EMP.lmA))
  await expectRpcDenied('LM: run_payroll_calculation', lm, 'run_payroll_calculation', { p_payroll_run_id: FIXTURE.draftRunA })
  await expectRpcDenied('LM: get_wps_export_readiness', lm, 'get_wps_export_readiness', { p_payroll_run_id: FIXTURE.draftRunA })
  await expectRpcDenied('LM: record_timesheet_entry', lm, 'record_timesheet_entry', {
    p_payroll_run_id: FIXTURE.draftRunA, p_employee_id: EMP.a, p_regular_hours: 1, p_overtime_hours: 0,
    p_holiday_hours: 0, p_notes: 'access test' })
  await expectRpcDenied('LM: record_payslip_deduction', lm, 'record_payslip_deduction', {
    p_payroll_run_id: FIXTURE.draftRunA, p_employee_id: EMP.a, p_deduction_type: 'other', p_amount: 1, p_notes: 'x' })
  await expectRpcDenied('LM: create_payroll_revision', lm, 'create_payroll_revision', { p_source_run_id: FIXTURE.draftRunA })
  await expectRpcDenied('LM: get_owner_dashboard_kpis', lm, 'get_owner_dashboard_kpis', { p_entity_id: null })

  // ------------------------------------------------ staff: only own rows
  const sa = S['employee.a'].client
  await expectNoRows('staff A: other employees', sa, 'employees', (q) => q.neq('id', EMP.a))
  for (const t of ['leave_requests', 'attendance_records', 'payslips', 'employee_documents', 'leave_balances']) {
    await expectNoRows(`staff A: other employees' ${t}`, sa, t, (q) => q.neq('employee_id', EMP.a))
  }
  await expectNoRows('staff A: employee B by id', sa, 'employees', (q) => q.eq('id', EMP.b))
  await expectNoRows('staff A: unpublished shifts', sa, 'shifts', (q) => q.eq('is_published', false))
  await expectNoRows('staff A: employee_compensation', sa, 'employee_compensation')
  await expectNoRows('staff A: employee_identity_documents', sa, 'employee_identity_documents')
  await expectNoRows('staff A: payroll_runs draft', sa, 'payroll_runs', (q) => q.eq('status', 'draft'))
  {
    const { data } = await sa.from('payslips').select('payroll_run_id, payroll_runs(status)')
    const unpublished = (data ?? []).filter((r) => r.payroll_runs && !['approved', 'paid'].includes(r.payroll_runs.status))
    record('staff A: no draft payslips visible', unpublished.length === 0, `${(data ?? []).length} visible`)
  }
  await expectRpcDenied('staff A: approve own leave', sa, 'approve_leave_request', {
    p_request_id: FIXTURE.pendingLeaveA, p_action: 'approve', p_override: false, p_override_reason: null })
  await expectRpcDenied('staff A: approve own document', sa, 'approve_document', { p_document_id: FIXTURE.renewalDocA })
  await expectRpcDenied('staff A: correct own attendance', sa, 'correct_attendance_record', {
    p_record_id: '00000000-0000-0000-0000-000000000000', p_new_clock_in_at: null, p_new_clock_out_at: null, p_reason: 'x' })
  await expectRpcDenied('staff A: get_employee_completeness(B)', sa, 'get_employee_completeness', { p_employee_id: EMP.b })
  await expectRpcDenied('staff A: admin_list_user_access', sa, 'admin_list_user_access', { p_entity_id: null })

  // --------------------------------------------------- entity isolation
  const iso = async (label, client, otherEntity) => {
    await expectNoRows(`${label}: employees`, client, 'employees', (q) => q.eq('entity_id', otherEntity))
    await expectNoRows(`${label}: shifts`, client, 'shifts', (q) => q.eq('entity_id', otherEntity))
    await expectNoRows(`${label}: payroll_runs`, client, 'payroll_runs', (q) => q.eq('entity_id', otherEntity))
    await expectNoRows(`${label}: leave_requests`, client, 'leave_requests',
      (q) => q.in('employee_id', otherEntity === EB ? [EMP.c] : [EMP.a, EMP.b, EMP.lmA]))
    await expectNoRows(`${label}: attendance_records`, client, 'attendance_records', (q) => q.eq('entity_id', otherEntity))
    await expectNoRows(`${label}: locations`, client, 'locations', (q) => q.eq('entity_id', otherEntity))
  }
  await iso('entityadmin A -> B', S['entityadmin.a'].client, EB)
  await iso('entityadmin B -> A', S['entityadmin.b'].client, EA)
  await iso('locationmanager A -> B', S['locationmanager.a'].client, EB)
  await iso('locationmanager B -> A', S['locationmanager.b'].client, EA)
  await iso('employee C -> A', S['employee.c'].client, EA)
  await iso('employee A -> B', S['employee.a'].client, EB)
  const eaA = S['entityadmin.a'].client
  await expectRpcDenied('entityadmin A: get_workflow_rules(B)', eaA, 'get_workflow_rules', { p_module: null, p_entity_id: EB })
  await expectRpcDenied('entityadmin A: admin_list_user_access(B)', eaA, 'admin_list_user_access', { p_entity_id: EB })
  await expectRpcDenied('entityadmin A: get_owner_dashboard_kpis(B)', eaA, 'get_owner_dashboard_kpis', { p_entity_id: EB })
  await expectRpcDenied('entityadmin A: get_entity_dependency_summary(B)', eaA, 'get_entity_dependency_summary',
    { p_entity_id: EB, p_location_id: null })
  await expectRpcDenied('entityadmin A: admin_upsert_entity', eaA, 'admin_upsert_entity', {
    p_id: EB, p_name: 'x', p_code: null, p_trade_license_no: null, p_emirate: null, p_default_currency: null,
    p_payroll_day: null, p_is_active: true })

  // ------------------------------------------ revoked profile sees nothing
  let revoked = false
  try {
    const { error } = await eaA.rpc('admin_revoke_access', { p_user_id: S['employee.b'].user.id, p_grant_id: null,
      p_reason: 'automated access test (restored immediately)' })
    revoked = !error
    record('setup: revoke employee B', revoked, error?.message ?? '')
    if (revoked) {
      const sb = S['employee.b'].client   // same JWT, now inactive profile
      for (const t of ['employees', 'shifts', 'leave_requests', 'attendance_records', 'payslips', 'employee_documents',
        'leave_balances', 'notifications']) {
        await expectNoRows(`revoked B: ${t}`, sb, t)
      }
      await expectRpcDenied('revoked B: get_my_payslips', sb, 'get_my_payslips')
      await expectRpcDenied('revoked B: clock_in', sb, 'clock_in')
      await expectRpcDenied('revoked B: get_my_attendance', sb, 'get_my_attendance',
        { p_period_start: '2020-01-01', p_period_end: '2030-12-31' })
    }
  } finally {
    if (revoked) {
      const { error } = await eaA.rpc('admin_grant_access', { p_email: 'uat.employee.b@example.com', p_role: 'staff',
        p_entity_id: EA, p_location_id: LOC_A2, p_employee_id: EMP.b })
      record('teardown: restore employee B', !error, error?.message ?? '')
    }
  }

  // ------------------------------------------------------ anon sees nothing
  const anon = newClient()
  for (const t of ['employees', 'profiles', 'shifts', 'leave_requests', 'attendance_records', 'payslips',
    'payroll_runs', 'employee_compensation', 'employee_identity_documents', 'employee_documents', 'entities',
    'locations', 'audit_log', 'notifications', 'workflow_rules', 'access_grants', 'offers']) {
    await expectNoRows(`anon: ${t}`, anon, t)
  }
  for (const [fn, args] of [
    ['get_my_clock_status', {}], ['clock_in', {}], ['get_my_payslips', {}],
    ['get_owner_dashboard_kpis', { p_entity_id: null }], ['get_workflow_rules', { p_module: null, p_entity_id: null }],
    ['admin_list_user_access', { p_entity_id: null }], ['workflow_trigger_catalog', {}],
  ]) {
    await expectRpcDenied(`anon: rpc ${fn}`, anon, fn, args)
  }
}

main()
  .catch((e) => record('harness', false, e.message))
  .finally(() => {
    const failed = results.filter((r) => !r.pass)
    console.log(`\n${results.length - failed.length}/${results.length} passed`)
    process.exit(failed.length ? 1 : 0)
  })
