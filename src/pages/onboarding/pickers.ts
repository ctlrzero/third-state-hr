import { supabase } from '../../lib/supabase'

// Company-scoped pick lists for onboarding forms (RLS limits every query).

export interface Option {
  id: string
  name: string
}

export interface Pickers {
  locations: Option[]
  positions: Option[]
  managers: Option[]
}

export async function loadPickers(entityId: string): Promise<Pickers> {
  const [loc, pos, mgr] = await Promise.all([
    supabase.from('locations').select('id, name').eq('entity_id', entityId).eq('is_active', true).order('name'),
    supabase.from('positions').select('id, title').eq('entity_id', entityId).order('title'),
    supabase.from('employees').select('id, full_name').eq('entity_id', entityId).eq('employment_status', 'active').order('full_name'),
  ])
  return {
    locations: (loc.data ?? []).map((l) => ({ id: l.id as string, name: l.name as string })),
    positions: (pos.data ?? []).map((p) => ({ id: p.id as string, name: p.title as string })),
    managers: (mgr.data ?? []).map((m) => ({ id: m.id as string, name: m.full_name as string })),
  }
}

export const EMPLOYMENT_TYPES = [
  { value: 'full_time', label: 'Full time' },
  { value: 'part_time', label: 'Part time' },
  { value: 'on_call', label: 'On call' },
  { value: 'seasonal', label: 'Seasonal' },
]
