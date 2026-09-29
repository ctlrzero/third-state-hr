import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabase'

export function useWorkPatternWarnings(employeeId: string, shiftDate: string, excludeShiftId?: string) {
  const [warnings, setWarnings] = useState<string[]>([])
  useEffect(() => {
    if (!employeeId || !shiftDate) {
      setWarnings([])
      return
    }
    let live = true
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc('check_shift_work_pattern', {
        p_employee_id: employeeId,
        p_shift_date: shiftDate,
        p_exclude_shift_id: excludeShiftId ?? null,
      })
      if (!live) return
      setWarnings(error ? [] : (((data as { warnings: { message: string }[] })?.warnings ?? []).map((w) => w.message)))
    }, 150)
    return () => {
      live = false
      window.clearTimeout(t)
    }
  }, [employeeId, shiftDate, excludeShiftId])
  return warnings
}
