import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../auth/AuthContext'
import { StatusBadge } from '../components/StatusBadge'
import { EmptyState } from '../components/EmptyState'
import type { Employee, EmployeeStatus, Location } from '../types/db'

const STATUS_FILTERS: { value: EmployeeStatus | 'all'; label: string }[] = [
  { value: 'all', label: 'All statuses' },
  { value: 'active', label: 'Active' },
  { value: 'pre_boarding', label: 'Pending activation' },
  { value: 'candidate', label: 'Draft' },
  { value: 'inactive', label: 'Inactive' },
]

// UX-04 Employee directory and profile workspace.
// This screen never requests salary, allowance, bank or payroll fields —
// those live behind employee_compensation / employee_identity_documents,
// which carry their own owner/entity_admin-only RLS policies. A café manager
// can see this exact same component and API response with nothing to hide,
// because the query itself never asks for restricted columns.
export default function EmployeeDirectory() {
  const { activeEntityId } = useAuth()
  const [employees, setEmployees] = useState<Employee[]>([])
  const [locations, setLocations] = useState<Pick<Location, 'id' | 'name'>[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<EmployeeStatus | 'all'>('all')
  const [locationFilter, setLocationFilter] = useState<string>('all')

  useEffect(() => {
    if (!activeEntityId) return
    let cancelled = false
    setLoading(true)
    setError(null)

    async function load() {
      const [employeesRes, locationsRes] = await Promise.all([
        supabase
          .from('employees')
          .select(
            'id, entity_id, home_location_id, position_id, full_name, preferred_name, photo_url, email, phone, employment_type, employment_status, join_date, created_at, updated_at, locations(id, name), positions(id, title, department)'
          )
          .eq('entity_id', activeEntityId)
          .order('full_name', { ascending: true }),
        supabase.from('locations').select('id, name').eq('entity_id', activeEntityId),
      ])

      if (cancelled) return

      if (employeesRes.error) {
        setError(employeesRes.error.message)
      } else {
        setEmployees((employeesRes.data ?? []) as unknown as Employee[])
      }
      setLocations(locationsRes.data ?? [])
      setLoading(false)
    }

    load()
    return () => {
      cancelled = true
    }
  }, [activeEntityId])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return employees.filter((emp) => {
      if (statusFilter !== 'all' && emp.employment_status !== statusFilter) return false
      if (locationFilter !== 'all' && emp.home_location_id !== locationFilter) return false
      if (q && !emp.full_name.toLowerCase().includes(q) && !(emp.email ?? '').toLowerCase().includes(q)) {
        return false
      }
      return true
    })
  }, [employees, search, statusFilter, locationFilter])

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-muted">Third State Café</p>
          <h1 className="text-[34px] font-normal leading-[51px] tracking-[-1.19px] text-ink">People</h1>
          <p className="text-xs text-muted">
            {loading ? 'Loading…' : `${filtered.length} of ${employees.length} employees`}
          </p>
        </div>
      </div>

      <div className="flex flex-wrap gap-2">
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search by name or email"
          className="w-full flex-1 rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20 sm:w-64 sm:flex-none"
        />
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value as EmployeeStatus | 'all')}
          className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          {STATUS_FILTERS.map((f) => (
            <option key={f.value} value={f.value}>
              {f.label}
            </option>
          ))}
        </select>
        <select
          value={locationFilter}
          onChange={(e) => setLocationFilter(e.target.value)}
          className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-brand-blue focus:outline-none focus:ring-2 focus:ring-brand-blue/20"
        >
          <option value="all">All branches</option>
          {locations.map((loc) => (
            <option key={loc.id} value={loc.id}>
              {loc.name}
            </option>
          ))}
        </select>
      </div>

      {error && (
        <p className="rounded-lg bg-brand-risk-soft px-3 py-2 text-sm text-brand-risk-text">{error}</p>
      )}

      {loading ? (
        <div className="space-y-2">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="h-16 animate-pulse rounded-xl bg-surface md:h-12" />
          ))}
        </div>
      ) : filtered.length === 0 ? (
        <EmptyState
          title={employees.length === 0 ? 'No employees in this entity yet' : 'No employees match your filters'}
          description={
            employees.length === 0
              ? 'Once employees are added to this entity, they will appear here.'
              : 'Try clearing the search or filter to see the full directory.'
          }
        />
      ) : (
        <>
          {/* Desktop table */}
          <div className="hidden overflow-hidden rounded-[14px] border border-border bg-surface shadow-card md:block">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-surface-alt text-xs uppercase tracking-wide text-muted">
                <tr>
                  <th className="px-4 py-3 font-medium">Name</th>
                  <th className="px-4 py-3 font-medium">Role</th>
                  <th className="px-4 py-3 font-medium">Branch</th>
                  <th className="px-4 py-3 font-medium">Employment</th>
                  <th className="px-4 py-3 font-medium">Status</th>
                  <th className="px-4 py-3 font-medium">Joined</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {filtered.map((emp) => (
                  <tr key={emp.id} className="hover:bg-surface-alt/60">
                    <td className="px-4 py-3">
                      <Link to={`/employees/${emp.id}`} className="font-medium text-ink hover:text-brand-blue">
                        {emp.preferred_name || emp.full_name}
                      </Link>
                      {emp.email && <p className="text-xs text-muted">{emp.email}</p>}
                    </td>
                    <td className="px-4 py-3 text-muted">{emp.positions?.title ?? '—'}</td>
                    <td className="px-4 py-3 text-muted">{emp.locations?.name ?? '—'}</td>
                    <td className="px-4 py-3 text-muted capitalize">
                      {emp.employment_type?.replace('_', ' ') ?? '—'}
                    </td>
                    <td className="px-4 py-3">
                      <StatusBadge status={emp.employment_status ?? 'candidate'} />
                    </td>
                    <td className="px-4 py-3 text-muted">{emp.join_date ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Mobile record cards */}
          <ul className="space-y-3 md:hidden">
            {filtered.map((emp) => (
              <li key={emp.id}>
                <Link
                  to={`/employees/${emp.id}`}
                  className="block rounded-[14px] border border-border bg-surface shadow-card p-4"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="truncate font-medium text-ink">{emp.preferred_name || emp.full_name}</p>
                      <p className="text-sm text-muted">{emp.positions?.title ?? 'No role set'}</p>
                    </div>
                    <StatusBadge status={emp.employment_status ?? 'candidate'} />
                  </div>
                  <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
                    <div>
                      <dt className="text-muted">Branch</dt>
                      <dd className="text-ink">{emp.locations?.name ?? '—'}</dd>
                    </div>
                    <div>
                      <dt className="text-muted">Joined</dt>
                      <dd className="text-ink">{emp.join_date ?? '—'}</dd>
                    </div>
                  </dl>
                </Link>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  )
}
