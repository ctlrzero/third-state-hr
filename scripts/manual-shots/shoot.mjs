// Screenshot runner for the Admin/Manager and Employee manuals.
// Usage: node scripts/manual-shots/shoot.mjs [filter]   (app served at http://localhost:4173)
import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import { installMock } from './mock.mjs'
import { ID, personas } from './fixtures.mjs'

const require = createRequire(import.meta.url)
let chromium
try {
  ;({ chromium } = require('playwright'))
} catch {
  ;({ chromium } = require('/home/claude/.npm-global/lib/node_modules/playwright'))
}

const BASE = process.env.BASE_URL ?? 'http://localhost:4173'
const OUT = process.env.OUT_DIR ?? '/home/claude/manual/shots'
const filter = process.argv[2] ?? ''

const DESKTOP = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 }
const MOBILE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true }

const BAD_TEXT = [/\bundefined\b/, /\bNaN\b/, /not available/i, /something went wrong/i, /could not find/i, /Checking your session/, /Network error/i, /Invalid Date/]

async function settle(page) {
  await page.waitForLoadState('networkidle').catch(() => {})
  await page
    .waitForFunction(() => !document.querySelector('.animate-pulse, .animate-spin') && !/Loading…|Checking…/.test(document.body.innerText), null, { timeout: 8000 })
    .catch(() => console.warn('  ! still loading after 8s'))
  await page.evaluate(() => document.fonts.ready)
  await page.waitForTimeout(250)
}

async function check(page, name) {
  const text = await page.evaluate(() => document.body.innerText)
  const problems = BAD_TEXT.filter((re) => re.test(text)).map(String)
  const alerts = await page.locator('[role=alert]').count()
  if (alerts) problems.push(`${alerts} role=alert`)
  if (problems.length) console.warn(`  ! ${name}: ${problems.join(', ')}`)
}

const A = (f) => path.join(OUT, 'admin', f)
const E = (f) => path.join(OUT, 'employee', f)
const ADMIN_TIME = '2026-09-26T10:15:00+04:00'
const STAFF_TIME = '2026-09-26T08:52:00+04:00'

const selectByLabel = async (page, label, optionLabel) => page.getByLabel(label, { exact: true }).selectOption({ label: optionLabel })

const SHOTS = [
  // ---------------- Admin / Manager ----------------
  { out: A('01-sign-in.png'), persona: null, device: DESKTOP, url: '/sign-in' },
  { out: A('02-owner-dashboard.png'), persona: 'owner', device: DESKTOP, url: '/', fullPage: true },
  {
    out: A('03-entity-switcher.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/',
    run: async (page) => {
      await page.getByLabel('Active entity').focus()
      // Callout for the manual: outline the switcher (annotation only, not app UI)
      await page.addStyleTag({ content: "select[aria-label='Active entity']{outline:3px solid #e11d48 !important;outline-offset:4px}" })
    },
    outline: true,
  },
  { out: A('04-people-directory.png'), persona: 'owner', device: DESKTOP, url: '/employees' },
  { out: A('05-employee-profile.png'), persona: 'owner', device: DESKTOP, url: `/employees/${ID.maria}` },
  {
    out: A('06-employee-activate-blocked.png'),
    persona: 'owner',
    device: DESKTOP,
    url: `/employees/${ID.noura}`,
    run: async (page) => {
      await page.getByRole('button', { name: 'Activate', exact: true }).click()
      await page.getByRole('alertdialog').waitFor()
    },
  },
  {
    out: A('07-bulk-import.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/admin?tab=import',
    fullPage: true,
    run: async (page) => {
      const csv = [
        'full_name,email,gender,employment_type,join_date,branch,position',
        'Layla Haddad,layla.haddad@thirdstate.ae,female,full_time,2026-10-11,Expo City CRC Concession,Barista',
        'Carlos Reyes,carlos.reyes@thirdstate.ae,male,part_time,2026-10-11,Corporate Concession,Barista',
        'Aigerim Sadykova,aigerim.s@thirdstate.ae,female,full_time,2026-10-18,Expo City CRC Concession,Senior Barista',
      ].join('\n')
      await page.getByLabel('Or paste CSV').fill(csv)
    },
  },
  { out: A('08-admin-branches.png'), persona: 'owner', device: DESKTOP, url: '/admin?tab=entities' },
  { out: A('09-admin-users-access.png'), persona: 'owner', device: DESKTOP, url: '/admin?tab=users' },
  {
    out: A('10-grant-access.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/admin?tab=users',
    run: async (page) => {
      await page.getByRole('button', { name: 'Grant access' }).click()
      const dlg = page.getByRole('dialog')
      await dlg.getByLabel('Email').fill('noura.khalil@thirdstate.ae')
      await dlg.getByLabel('Role').selectOption('staff')
      await dlg.getByLabel('Linked employee').selectOption(ID.noura)
    },
  },
  {
    out: A('11-schedules.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/schedules',
    fullPage: true,
    clipHeight: 1500,
    run: async (page) => {
      await page.locator('select:has(option[value="all"])').first().selectOption({ label: 'Expo City CRC Concession' })
      await page.locator('#schedules-branch-1').selectOption({ label: 'Expo City CRC Concession' })
    },
  },
  {
    out: A('12-attendance-exceptions.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/attendance',
    run: async (page) => {
      await page.getByLabel('Branch').selectOption({ label: 'Expo City CRC Concession' })
      await settle(page)
      await page.getByRole('tab', { name: /Exceptions/ }).click()
    },
  },
  {
    out: A('13-attendance-correction.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/attendance',
    run: async (page) => {
      await page.getByLabel('Branch').selectOption({ label: 'Expo City CRC Concession' })
      await settle(page)
      await page.getByRole('tab', { name: /Exceptions/ }).click()
      await page.getByRole('button', { name: 'Correct' }).first().click()
      const dlg = page.getByRole('dialog')
      await dlg.getByLabel(/New clock-out/).fill('2026-09-23T20:04')
      await dlg.getByLabel(/Reason/).fill('Forgot to clock out after closing. Confirmed with the closing checklist signed at 20:04.')
    },
  },
  { out: A('14-leave-approvals.png'), persona: 'manager', device: DESKTOP, url: '/leave' },
  {
    out: A('15-documents-review.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/documents',
    run: async (page) => {
      await page.getByLabel('Review status').selectOption('pending_review')
      await page.getByRole('button', { name: 'Review' }).first().click()
    },
  },
  { out: A('16-payroll-list.png'), persona: 'owner', device: DESKTOP, url: '/payroll' },
  {
    out: A('17-payroll-run.png'),
    persona: 'owner',
    device: DESKTOP,
    url: '/payroll',
    fullPage: true,
    run: async (page) => {
      await page.getByRole('button', { name: 'Open' }).first().click()
    },
  },
  { out: A('18-workflows.png'), persona: 'owner', device: DESKTOP, url: '/workflows', fullPage: true },
  {
    out: A('19-workflow-builder.png'),
    persona: 'owner',
    device: { ...DESKTOP, viewport: { width: 1440, height: 1320 } },
    url: '/workflows',
    run: async (page) => {
      await page.getByRole('button', { name: 'New rule' }).first().click()
      const dlg = page.getByRole('dialog')
      await dlg.getByLabel(/Rule name/).fill('Late clock-in alert (10+ minutes)')
      await dlg.getByText('Attendance', { exact: true }).click()
      await dlg.getByLabel('Add a condition').check()
      await dlg.getByLabel('Operator').selectOption('gte')
      await dlg.getByLabel('Value').fill('10')
      await dlg.getByLabel('Who').selectOption('location_manager')
      await dlg.getByLabel(/Notification message/).fill('A team member clocked in 10 or more minutes late. Check Attendance.')
    },
  },
  { out: A('20-reports-audit.png'), persona: 'owner', device: DESKTOP, url: '/reports', fullPage: true },
  { out: A('21-notifications.png'), persona: 'owner', device: DESKTOP, url: '/notifications' },
  { out: A('22-manager-home.png'), persona: 'manager', device: DESKTOP, url: '/' },

  // ---------------- Employee (mobile) ----------------
  { out: E('01-sign-in.png'), persona: null, device: MOBILE, url: '/sign-in', time: STAFF_TIME },
  { out: E('02-home.png'), persona: 'staff', device: MOBILE, url: '/', time: STAFF_TIME, fullPage: true },
  { out: E('03-clock-before.png'), persona: 'staff', device: MOBILE, url: '/clock', time: STAFF_TIME },
  {
    out: E('04-clock-after.png'),
    persona: 'staff',
    device: MOBILE,
    url: '/clock',
    time: STAFF_TIME,
    run: async (page) => {
      await page.getByRole('button', { name: 'Clock in' }).click()
      await page.getByText(/Clocked in at/).waitFor()
    },
  },
  { out: E('05-schedule.png'), persona: 'staff', device: MOBILE, url: '/schedules', time: STAFF_TIME },
  { out: E('06-leave.png'), persona: 'staff', device: MOBILE, url: '/leave', time: STAFF_TIME },
  {
    out: E('07-leave-request.png'),
    persona: 'staff',
    device: MOBILE,
    url: '/leave',
    time: STAFF_TIME,
    run: async (page) => {
      await page.getByRole('button', { name: 'Request leave' }).click()
      await page.getByLabel('Leave type').selectOption({ label: 'Annual Leave' })
      await page.getByLabel('Start date').fill('2026-11-22')
      await page.getByLabel('End date').fill('2026-11-24')
      await page.getByLabel('Reason (optional)').fill("Brother's wedding in Cebu")
    },
  },
  { out: E('08-documents.png'), persona: 'staff', device: MOBILE, url: '/documents', time: STAFF_TIME, fullPage: true },
  {
    out: E('09-document-renewal.png'),
    persona: 'staff',
    device: MOBILE,
    url: '/documents',
    time: STAFF_TIME,
    run: async (page) => {
      const visa = page.locator('li', { hasText: 'Visa' }).first()
      await visa.getByRole('button', { name: 'Upload renewal' }).click()
      await page.getByLabel(/New expiry date/).fill('2028-10-13')
      await page.getByLabel('File', { exact: true }).setInputFiles({ name: 'visa-renewal-2026.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n%sample\n') })
      await page.getByLabel(/Notes/).fill('New residence visa issued 25 Sep 2026')
    },
  },
  { out: E('10-payslips.png'), persona: 'staff', device: MOBILE, url: '/payroll', time: STAFF_TIME },
  {
    out: E('11-payslip-detail.png'),
    persona: 'staff',
    device: MOBILE,
    url: '/payroll',
    time: STAFF_TIME,
    run: async (page) => {
      await page.getByRole('button', { name: /01 Aug 2026/ }).click()
      await page.getByRole('dialog').getByText('Net pay').first().waitFor()
    },
  },
  { out: E('12-profile.png'), persona: 'staff', device: MOBILE, url: '/me', time: STAFF_TIME, fullPage: true },
  { out: E('13-notifications.png'), persona: 'staff', device: MOBILE, url: '/notifications', time: STAFF_TIME },
  {
    out: E('14-more-menu.png'),
    persona: 'staff',
    device: MOBILE,
    url: '/',
    time: STAFF_TIME,
    run: async (page) => {
      await page.getByRole('button', { name: 'More' }).click()
      await page.getByRole('dialog', { name: 'More destinations' }).waitFor()
    },
  },
]

const browser = await chromium.launch()
let failures = 0
for (let shot of SHOTS) {
  if (filter && !shot.out.includes(filter)) continue
  const name = path.relative(OUT, shot.out)
  console.log(`> ${name}`)
  const ctx = await browser.newContext({ ...shot.device, timezoneId: 'Asia/Dubai', locale: 'en-GB', colorScheme: 'light', reducedMotion: 'reduce' })
  const page = await ctx.newPage()
  page.on('pageerror', (e) => console.warn(`  ! pageerror: ${e.message}`))
  page.on('console', (m) => m.type() === 'error' && console.warn(`  ! console: ${m.text()}`))
  const time = shot.time ?? ADMIN_TIME
  await page.clock.setFixedTime(new Date(time))
  const state = await installMock(page, shot.persona ? personas[shot.persona] : null, { nowIso: time })
  try {
    await page.goto(BASE + shot.url)
    await settle(page)
    if (shot.run) {
      await shot.run(page)
      await settle(page)
    }
    // Blur any focused text field so no caret shows (keep focus for the switcher shot)
    if (!shot.out.includes('03-entity-switcher')) await page.evaluate(() => (document.activeElement instanceof HTMLInputElement || document.activeElement instanceof HTMLTextAreaElement) && document.activeElement.blur())
    await check(page, name)
    fs.mkdirSync(path.dirname(shot.out), { recursive: true })
    if (shot.fullPage && shot.device.isMobile) {
      // Grow the viewport to the content height so the fixed bottom nav sits at the real bottom.
      const h = await page.evaluate(() => document.documentElement.scrollHeight)
      await page.setViewportSize({ width: shot.device.viewport.width, height: Math.max(h, shot.device.viewport.height) })
      await settle(page)
      shot = { ...shot, fullPage: false }
    }
    const clip = shot.clipHeight ? { x: 0, y: 0, width: shot.device.viewport.width, height: Math.min(shot.clipHeight, await page.evaluate(() => document.documentElement.scrollHeight)) } : shot.clip
    await page.screenshot({ path: shot.out, fullPage: Boolean(shot.fullPage), clip, animations: 'disabled' })
  } catch (e) {
    failures++
    console.error(`  x ${name}: ${e.message.split('\n')[0]}`)
  }
  if (state.unhandled.length) console.warn(`  ! unhandled: ${[...new Set(state.unhandled)].join(' | ')}`)
  await ctx.close()
}
await browser.close()
console.log(failures ? `${failures} failure(s)` : 'done')
process.exit(failures ? 1 : 0)
