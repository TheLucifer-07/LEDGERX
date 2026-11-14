\set ON_ERROR_STOP on
BEGIN;
DO $assertions$
BEGIN
  IF NOT pg_catalog.has_database_privilege('ledgerx_dashboard', current_database(), 'CONNECT') THEN
    RAISE EXCEPTION 'dashboard role cannot connect';
  END IF;
  IF NOT pg_catalog.has_schema_privilege('ledgerx_dashboard', 'ledger', 'USAGE') THEN
    RAISE EXCEPTION 'dashboard role cannot use ledger schema';
  END IF;
  IF NOT pg_catalog.has_table_privilege('ledgerx_dashboard', 'ledger.transactions', 'SELECT') THEN
    RAISE EXCEPTION 'dashboard role cannot read transactions';
  END IF;
  IF NOT pg_catalog.has_table_privilege('ledgerx_dashboard', 'ledger.v_account_activity', 'SELECT') THEN
    RAISE EXCEPTION 'dashboard role cannot read account activity view';
  END IF;
  IF pg_catalog.has_table_privilege('ledgerx_dashboard', 'ledger.transactions', 'INSERT')
     OR pg_catalog.has_table_privilege('ledgerx_dashboard', 'ledger.transactions', 'UPDATE')
     OR pg_catalog.has_table_privilege('ledgerx_dashboard', 'ledger.transactions', 'DELETE') THEN
    RAISE EXCEPTION 'dashboard role has transaction mutation privileges';
  END IF;
  IF pg_catalog.has_table_privilege('ledgerx_dashboard', 'ledger.idempotency_keys', 'SELECT') THEN
    RAISE EXCEPTION 'dashboard role can read idempotency keys';
  END IF;
  IF NOT pg_catalog.has_function_privilege(
       'ledgerx_dashboard', 'ledger.audit_integrity()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'dashboard role cannot execute read-only integrity audit';
  END IF;
  IF pg_catalog.has_function_privilege(
       'ledgerx_dashboard', 'ledger.deposit(text,text,bigint,bigint,numeric,text,text)', 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'ledgerx_dashboard', 'ledger.transfer(text,text,bigint,bigint,numeric,text,text)', 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'ledgerx_dashboard', 'ledger.rebuild_account_balances()'::regprocedure, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'dashboard role can execute a financial mutation';
  END IF;
END
$assertions$;
ROLLBACK;
