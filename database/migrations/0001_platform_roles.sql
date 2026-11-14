-- Purpose: establish the owned schema and separate migration/runtime roles.
-- Applied by scripts/migrate.sh as the local database administrator.
CREATE ROLE ledgerx_owner NOLOGIN;
CREATE ROLE ledgerx_runtime NOLOGIN;

CREATE SCHEMA ledger AUTHORIZATION ledgerx_owner;
REVOKE ALL ON SCHEMA ledger FROM PUBLIC;
GRANT USAGE ON SCHEMA ledger TO ledgerx_runtime;

COMMENT ON SCHEMA ledger IS
  'LedgerX financial records and controlled database operations';
