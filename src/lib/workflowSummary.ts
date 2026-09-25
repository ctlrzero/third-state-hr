import type { UserRole } from '../types/db'
import { OPERATORS, ROLE_LABEL, findTrigger, type WorkflowActionType } from './workflowCatalog'

export interface WorkflowDraft {
  module: string
  trigger_event: string
  condition_field: string | null
  condition_operator: string | null
  condition_value: string | null
  action_type: WorkflowActionType | string
  action_target_role: UserRole | null
  action_message_template?: string | null
}

/**
 * Builds the live plain-language sentence shown in the builder, e.g.
 * "When a leave request is submitted and days > 3, notify Entity Admin."
 * Pure so it can be unit-tested and reused in the rules list.
 */
export function buildWorkflowSummary(d: WorkflowDraft): string {
  const trigger = findTrigger(d.module, d.trigger_event)
  const when = trigger
    ? trigger.phrase
    : d.trigger_event
      ? `${d.trigger_event.replace(/_/g, ' ')} happens`
      : 'something happens'

  let condition = ''
  const hasCondition = d.condition_field && d.condition_operator && (d.condition_value ?? '').trim() !== ''
  if (hasCondition) {
    const field = trigger?.fields.find((f) => f.key === d.condition_field)
    const fieldPhrase = field?.phrase ?? d.condition_field!.replace(/_/g, ' ')
    const op = OPERATORS.find((o) => o.value === d.condition_operator)
    const opText = op ? (op.symbol.length <= 1 ? op.symbol : op.label) : d.condition_operator
    const value = d.condition_value!.trim()
    const option = field?.options?.find((o) => o.value === value)
    const shown = field?.kind === 'number' ? value : option ? option.label : `"${value}"`
    condition = ` and ${fieldPhrase} ${opText} ${shown}`
  }

  let action: string
  if (d.action_type === 'notify_employee') {
    action = 'notify the employee'
  } else if (d.action_target_role) {
    action = `notify ${ROLE_LABEL[d.action_target_role] ?? d.action_target_role}`
  } else {
    action = 'notify …'
  }

  return `When ${when}${condition}, ${action}.`
}

export interface DraftValidation {
  ok: boolean
  errors: Partial<Record<'name' | 'trigger' | 'condition' | 'target' | 'message', string>>
}

export function validateWorkflowDraft(d: WorkflowDraft & { name: string }): DraftValidation {
  const errors: DraftValidation['errors'] = {}
  if (!d.name.trim()) errors.name = 'Give the rule a name.'
  if (!findTrigger(d.module, d.trigger_event)) errors.trigger = 'Choose what starts this rule.'
  const anyCond = Boolean(d.condition_field || d.condition_operator || (d.condition_value ?? '').trim())
  const allCond = Boolean(d.condition_field && d.condition_operator && (d.condition_value ?? '').trim())
  if (anyCond && !allCond) errors.condition = 'Complete the condition (field, operator and value) or remove it.'
  if (allCond) {
    const trigger = findTrigger(d.module, d.trigger_event)
    const field = trigger?.fields.find((f) => f.key === d.condition_field)
    const op = OPERATORS.find((o) => o.value === d.condition_operator)
    const value = (d.condition_value ?? '').trim()
    if (!field) {
      errors.condition = 'This field cannot be used with the chosen trigger.'
    } else if (field.kind === 'number' && Number.isNaN(Number(value))) {
      errors.condition = 'Enter a number for this condition.'
    } else if (op?.numericOnly && field.kind !== 'number') {
      errors.condition = `"${op.label}" only works with numbers.`
    } else if (field.options && !field.options.some((o) => o.value === value)) {
      errors.condition = 'Choose one of the listed values.'
    } else if (field.kind === 'date' && !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
      errors.condition = 'Enter the date as YYYY-MM-DD.'
    }
  }
  if (d.action_type === 'notify_role' && !d.action_target_role) errors.target = 'Choose who gets notified.'
  if (d.action_type === 'notify_employee' && d.action_target_role) errors.target = 'Notify-the-employee rules cannot also target a role.'
  if (!(d.action_message_template ?? '').trim()) errors.message = 'Write the notification message.'
  return { ok: Object.keys(errors).length === 0, errors }
}
