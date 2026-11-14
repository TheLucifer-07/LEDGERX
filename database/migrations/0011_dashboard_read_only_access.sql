-- Purpose: create a dedicated, read-only login for the local analytics adapter.
-- Run as the database administrator: CREATE ROLE is intentionally not run as
-- ledgerx_owner. Existing financial tables and functions are not modified.

DO $migration$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledgerx_dashboard') THEN
    EXECUTE 'CREATE ROLE ledgerx_dashboard NOLOGIN';
  END IF;
END
$migration$;

ALTER ROLE ledgerx_dashboard
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
       INHERIT CONNECTION LIMIT 10;
ALTER ROLE ledgerx_dashboard SET default_transaction_read_only = on;
ALTER ROLE ledgerx_dashboard SET search_path = pg_catalog, ledger;

DO $database_grant$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO ledgerx_dashboard', current_database());
END
$database_grant$;

GRANT USAGE ON SCHEMA ledger TO ledgerx_dashboard;

REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM ledgerx_dashboard;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ledger FROM ledgerx_dashboard;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM ledgerx_dashboard;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA ledger FROM ledgerx_dashboard;

-- These source tables contain only the fields needed by the read-only UI.
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
  ledger.reconciliation_results
TO ledgerx_dashboard;

GRANT SELECT ON
  ledger.v_daily_transaction_volume,
  ledger.v_monthly_transaction_summary,
  ledger.v_monthly_transaction_rank,
  ledger.v_account_activity,
  ledger.v_refund_analysis,
  ledger.v_refund_history,
  ledger.v_settlement_batch_summary,
  ledger.v_reconciliation_exceptions,
  ledger.v_unsettled_transactions
TO ledgerx_dashboard;

GRANT EXECUTE ON FUNCTION ledger.audit_integrity() TO ledgerx_dashboard;

COMMENT ON ROLE ledgerx_dashboard IS
  'Local LedgerX dashboard login; SELECT-only and read-only by default.';
