
-- Per explicit user direction: the dblink/autonomous-transaction approach to logging
-- blocked payroll writes is permanently abandoned. No audit_logger role, password, or
-- Vault secret was ever created (that step was blocked before execution). Remove the
-- extension itself so no dependency on it remains anywhere in the schema.
drop extension if exists dblink;
