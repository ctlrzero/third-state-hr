-- The Admin > Policies screen reads data_retention_policies directly (PostgREST select),
-- but authenticated had no table SELECT privilege, so every read failed with 42501
-- (for owner and entity_admin alike). Grant SELECT only; RLS (data_retention_policies_select:
-- owner all entities, entity_admin own entity, nobody else) scopes the rows. Writes stay
-- RPC-only (propose_/approve_data_retention_policy); anon gets nothing.
grant select on table public.data_retention_policies to authenticated;
revoke all on table public.data_retention_policies from anon;
