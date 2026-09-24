import type { ClockState } from './api/attendance'

export interface ClockButtonModel {
  /** Which RPC the big button calls, or null when there is no action. */
  action: 'clock_in' | 'clock_out' | null
  label: string
  /** Visual tone for the button. */
  tone: 'primary' | 'danger' | 'disabled'
  disabled: boolean
  /** One-line explanation shown under the button. */
  helper: string
}

/**
 * Pure mapping from the server-reported clock state (plus whether a save is
 * in flight) to what the single Clock button should look like. Kept free of
 * React so the rules are unit-tested:
 *  - saving always disables the button (double-tap protection)
 *  - clocked_out: done for today, no further action
 *  - no_shift: clock-in is still allowed (the backend records an unmatched
 *    clock-in that a manager reviews), but the helper says so
 */
export function clockButtonModel(state: ClockState | null, saving: boolean): ClockButtonModel {
  if (state === null) {
    return { action: null, label: 'Checking…', tone: 'disabled', disabled: true, helper: 'Loading your status.' }
  }
  let model: ClockButtonModel
  switch (state) {
    case 'not_started':
      model = {
        action: 'clock_in',
        label: 'Clock in',
        tone: 'primary',
        disabled: false,
        helper: 'Tap when you start your shift.',
      }
      break
    case 'no_shift':
      model = {
        action: 'clock_in',
        label: 'Clock in',
        tone: 'primary',
        disabled: false,
        helper: 'No shift is scheduled for you today. Your manager will review this clock-in.',
      }
      break
    case 'clocked_in':
      model = {
        action: 'clock_out',
        label: 'Clock out',
        tone: 'danger',
        disabled: false,
        helper: 'Tap when you finish your shift.',
      }
      break
    case 'clocked_out':
      model = {
        action: null,
        label: 'Shift complete',
        tone: 'disabled',
        disabled: true,
        helper: "You've clocked out for today.",
      }
      break
    default:
      model = { action: null, label: 'Unavailable', tone: 'disabled', disabled: true, helper: '' }
  }
  if (saving && model.action) {
    return {
      ...model,
      label: model.action === 'clock_in' ? 'Clocking in…' : 'Clocking out…',
      disabled: true,
      helper: 'Saving — please wait for confirmation.',
    }
  }
  return model
}

/** Human-readable label for the state pill. */
export const CLOCK_STATE_LABEL: Record<ClockState, string> = {
  not_started: 'Not clocked in',
  clocked_in: 'Clocked in',
  clocked_out: 'Clocked out',
  no_shift: 'No shift today',
}
