// CSV parsing + client-side validation for bulk employee import. The server
// (bulk_import_employees) re-validates everything and is all-or-nothing;
// this preview just catches obvious problems before the round trip and maps
// human-friendly branch/position names to the ids the RPC expects.

export const IMPORT_COLUMNS = ['full_name', 'email', 'gender', 'employment_type', 'join_date', 'branch', 'position'] as const
export type ImportColumn = (typeof IMPORT_COLUMNS)[number]

export const EMPLOYMENT_TYPES = ['full_time', 'part_time', 'on_call', 'seasonal'] as const

export const CSV_TEMPLATE =
  'full_name,email,gender,employment_type,join_date,branch,position\n' +
  'Aisha Rahman,aisha.r@example.com,female,full_time,2026-10-01,Marina,Barista\n'

/** RFC-4180-ish parser: quoted fields, escaped quotes (""), CRLF/LF, commas in quotes. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let inQuotes = false
  const src = text.replace(/^﻿/, '')
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (inQuotes) {
      if (c === '"') {
        if (src[i + 1] === '"') {
          field += '"'
          i++
        } else {
          inQuotes = false
        }
      } else {
        field += c
      }
      continue
    }
    if (c === '"') inQuotes = true
    else if (c === ',') {
      row.push(field)
      field = ''
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++
      row.push(field)
      rows.push(row)
      row = []
      field = ''
    } else field += c
  }
  if (field !== '' || row.length > 0) {
    row.push(field)
    rows.push(row)
  }
  return rows.filter((r) => r.some((cell) => cell.trim() !== ''))
}

export interface LookupItem {
  id: string
  name: string
  code?: string | null
}

export interface PreviewRow {
  /** 1-based data row number (header excluded) — matches the server's row_index. */
  rowNumber: number
  values: Record<ImportColumn, string>
  errors: string[]
  payload: Record<string, string | null>
}

export interface ImportPreview {
  headerErrors: string[]
  rows: PreviewRow[]
  validCount: number
  invalidCount: number
}

const HEADER_ALIASES: Record<string, ImportColumn> = {
  full_name: 'full_name',
  name: 'full_name',
  'full name': 'full_name',
  email: 'email',
  gender: 'gender',
  employment_type: 'employment_type',
  'employment type': 'employment_type',
  type: 'employment_type',
  join_date: 'join_date',
  'join date': 'join_date',
  start_date: 'join_date',
  branch: 'branch',
  location: 'branch',
  position: 'position',
  role: 'position',
  job_title: 'position',
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

/** Accepts yyyy-mm-dd or dd/mm/yyyy (UAE style). Returns ISO or null when invalid. */
export function normaliseDate(input: string): string | null {
  const s = input.trim()
  let y: number, m: number, d: number
  let match = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(s)
  if (match) {
    y = +match[1]
    m = +match[2]
    d = +match[3]
  } else {
    match = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s)
    if (!match) return null
    d = +match[1]
    m = +match[2]
    y = +match[3]
  }
  const dt = new Date(Date.UTC(y, m - 1, d))
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null
  return dt.toISOString().slice(0, 10)
}

function resolve(value: string, items: LookupItem[]): LookupItem | undefined {
  const v = value.trim().toLowerCase()
  return items.find((i) => i.name.toLowerCase() === v || (i.code ?? '').toLowerCase() === v || i.id === value.trim())
}

export function buildImportPreview(
  text: string,
  branches: LookupItem[],
  positions: LookupItem[],
  maxRows = 500
): ImportPreview {
  const table = parseCsv(text)
  const headerErrors: string[] = []
  if (table.length === 0) {
    return { headerErrors: ['The file is empty.'], rows: [], validCount: 0, invalidCount: 0 }
  }
  const header = table[0].map((h) => HEADER_ALIASES[h.trim().toLowerCase()] ?? null)
  if (!header.includes('full_name')) headerErrors.push('Missing required column "full_name".')
  const unknown = table[0].filter((_, i) => header[i] === null).map((h) => h.trim()).filter(Boolean)
  if (unknown.length) headerErrors.push(`Ignored unknown column(s): ${unknown.join(', ')}.`)
  const dataRows = table.slice(1)
  if (dataRows.length === 0) headerErrors.push('No data rows found below the header.')
  if (dataRows.length > maxRows) headerErrors.push(`Too many rows (${dataRows.length}). Import at most ${maxRows} at a time.`)

  const emailCounts = new Map<string, number>()
  const rows: PreviewRow[] = dataRows.slice(0, maxRows).map((cells, idx) => {
    const values = Object.fromEntries(IMPORT_COLUMNS.map((c) => [c, ''])) as Record<ImportColumn, string>
    header.forEach((col, i) => {
      if (col) values[col] = (cells[i] ?? '').trim()
    })
    if (values.email) {
      const k = values.email.toLowerCase()
      emailCounts.set(k, (emailCounts.get(k) ?? 0) + 1)
    }
    return { rowNumber: idx + 1, values, errors: [], payload: {} }
  })

  for (const r of rows) {
    const v = r.values
    const payload: Record<string, string | null> = { full_name: v.full_name || null }
    if (!v.full_name) r.errors.push('Full name is required.')

    if (v.email) {
      if (!EMAIL_RE.test(v.email)) r.errors.push(`"${v.email}" is not a valid email.`)
      else if ((emailCounts.get(v.email.toLowerCase()) ?? 0) > 1) r.errors.push('Email appears more than once in this file.')
      payload.email = v.email
    } else payload.email = null

    payload.gender = v.gender ? v.gender.toLowerCase() : null

    if (v.employment_type) {
      const et = v.employment_type.toLowerCase().replace(/[\s-]+/g, '_')
      if (!(EMPLOYMENT_TYPES as readonly string[]).includes(et)) {
        r.errors.push(`Employment type must be one of: ${EMPLOYMENT_TYPES.join(', ')}.`)
      }
      payload.employment_type = et
    } else payload.employment_type = null

    if (v.join_date) {
      const iso = normaliseDate(v.join_date)
      if (!iso) r.errors.push(`Join date "${v.join_date}" is not a valid date (use YYYY-MM-DD or DD/MM/YYYY).`)
      payload.join_date = iso
    } else payload.join_date = null

    if (v.branch) {
      const b = resolve(v.branch, branches)
      if (!b) r.errors.push(`Branch "${v.branch}" was not found in this entity.`)
      payload.home_location_id = b?.id ?? null
    } else payload.home_location_id = null

    if (v.position) {
      const p = resolve(v.position, positions)
      if (!p) r.errors.push(`Position "${v.position}" was not found in this entity.`)
      payload.position_id = p?.id ?? null
    } else payload.position_id = null

    r.payload = payload
  }

  const invalidCount = rows.filter((r) => r.errors.length > 0).length
  return { headerErrors, rows, validCount: rows.length - invalidCount, invalidCount }
}

/** True when there's nothing blocking a commit. Unknown-column warnings don't block. */
export function canCommitPreview(p: ImportPreview): boolean {
  const blocking = p.headerErrors.filter((e) => !e.startsWith('Ignored unknown column'))
  return blocking.length === 0 && p.rows.length > 0 && p.invalidCount === 0
}
