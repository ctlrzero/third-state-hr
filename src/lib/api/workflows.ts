import { callRpc } from './client'
import type { UserRole } from '../../types/db'

export interface WorkflowRule {
  id: string
  entity_id: string
  name: string
  module: string
  trigger_event: string
  condition_field: string | null
  condition_operator: string | null
  condition_value: string | null
  action_type: string
  action_target_role: UserRole | null
  action_message_template: string
  is_active: boolean
  is_starter: boolean
  version_number: number
  created_at: string
  updated_at: string
  activated_at: string | null
  deactivated_at: string | null
}

export interface WorkflowRun {
  id: string
  rule_id: string
  entity_id: string
  source_table: string
  source_record_id: string
  event_type: string
  result: 'matched' | 'skipped' | 'failed'
  details: Record<string, unknown> | null
  ran_at: string
}

export interface CreateWorkflowRuleInput {
  name: string
  module: string
  trigger_event: string
  condition_field: string | null
  condition_operator: string | null
  condition_value: string | null
  action_type: string
  action_target_role: UserRole | null
  action_message_template: string
  /** Owner must pass the target entity; entity_admin may pass null (own). */
  entity_id: string | null
}

/** Owner: p_entity_id null = all entities. Entity admin: null or own. */
export const getWorkflowRules = (module: string | null = null, entityId: string | null = null) =>
  callRpc<WorkflowRule[]>('get_workflow_rules', { p_module: module, p_entity_id: entityId })

export const getWorkflowTriggerCatalog = () => callRpc<Record<string, Record<string, string[]>>>('workflow_trigger_catalog')

export const createWorkflowRule = (i: CreateWorkflowRuleInput) =>
  callRpc<string>('create_workflow_rule', {
    p_name: i.name,
    p_module: i.module,
    p_trigger_event: i.trigger_event,
    p_condition_field: i.condition_field,
    p_condition_operator: i.condition_operator,
    p_condition_value: i.condition_value,
    p_action_type: i.action_type,
    p_action_target_role: i.action_target_role,
    p_action_message_template: i.action_message_template,
    p_entity_id: i.entity_id,
  })

export const activateWorkflowRule = (ruleId: string) => callRpc<null>('activate_workflow_rule', { p_rule_id: ruleId })
export const deactivateWorkflowRule = (ruleId: string) =>
  callRpc<null>('deactivate_workflow_rule', { p_rule_id: ruleId })

/** Evaluates the rule's condition against a sample event. Never creates a production run. */
export const testWorkflowRule = (ruleId: string, sampleEvent: Record<string, unknown>) =>
  callRpc<'matched' | 'skipped' | string>('test_workflow_rule', { p_rule_id: ruleId, p_sample_event: sampleEvent })

export const getWorkflowRuns = (ruleId: string | null, limit = 50, entityId: string | null = null) =>
  callRpc<WorkflowRun[]>('get_workflow_runs', { p_rule_id: ruleId, p_limit: limit, p_entity_id: entityId })
