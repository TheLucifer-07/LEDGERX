-- Purpose: add a dedicated read-only API role for verified workspace requests.
-- This is separate from ledgerx_dashboard, whose local legacy-only policy must
-- remain unavailable to authenticated application traffic.

DO $create_api_role$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledgerx_api'
  ) THEN
    CREATE ROLE ledgerx_api NOLOGIN;
  END IF;
END
$create_api_role$;

ALTER ROLE ledgerx_api
  WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
       INHERIT CONNECTION LIMIT 10;
ALTER ROLE ledgerx_api SET default_transaction_read_only = on;
ALTER ROLE ledgerx_api SET search_path = pg_catalog, ledger;

DO $database_connect$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO ledgerx_api', current_database());
END
$database_connect$;

GRANT USAGE ON SCHEMA ledger TO ledgerx_api;
REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM ledgerx_api;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ledger FROM ledgerx_api;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM ledgerx_api;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA ledger FROM ledgerx_api;

-- Match the approved dashboard read surface while allowing RLS to return rows
-- from a verified user's active workspace. No direct table writes are granted.
GRANT SELECT ON
  ledger.currencies,
  ledger.customers,
  ledger.accounts,
  ledger.account_balances,
  ledger.transactions,
  ledger.ledger_entries,
  ledger.refunds,
  ledger.settlement_batches,
  ledger.settlement_items,
  ledger.settlement_matches,
  ledger.reconciliation_runs,
  ledger.reconciliation_results,
  ledger.v_daily_transaction_volume,
  ledger.v_monthly_transaction_summary,
  ledger.v_monthly_transaction_rank,
  ledger.v_account_activity,
  ledger.v_refund_analysis,
  ledger.v_refund_history,
  ledger.v_settlement_batch_summary,
  ledger.v_reconciliation_exceptions,
  ledger.v_unsettled_transactions
TO ledgerx_api;

GRANT EXECUTE ON FUNCTION ledger.current_workspace_id() TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.current_user_id() TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.current_supabase_user_id() TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.legacy_workspace_id() TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.default_workspace_id() TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.has_workspace_permission(uuid, text) TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.has_legacy_local_access(uuid) TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.set_request_context(uuid, uuid) TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.audit_integrity() TO ledgerx_api;

COMMENT ON ROLE ledgerx_api IS
  'Restricted read-only API role for JWT-verified, membership-checked workspace requests; must not be a table owner or bypass RLS.';
