\set ON_ERROR_STOP on
BEGIN;

DO $api_role_privilege_assertions$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
     WHERE rolname = 'ledgerx_api'
       AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcanlogin
  ) THEN
    RAISE EXCEPTION 'ledgerx_api must be NOLOGIN, NOSUPERUSER, and NOBYPASSRLS';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_db_role_setting AS role_setting
      CROSS JOIN LATERAL unnest(role_setting.setconfig) AS config_value
     WHERE role_setting.setrole = (
       SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'ledgerx_api'
     )
       AND config_value = 'default_transaction_read_only=on'
  ) THEN
    RAISE EXCEPTION 'ledgerx_api must default to read-only transactions';
  END IF;

  IF NOT has_table_privilege('ledgerx_api', 'ledger.accounts', 'SELECT')
     OR has_table_privilege('ledgerx_api', 'ledger.accounts', 'INSERT')
     OR has_table_privilege('ledgerx_api', 'ledger.transactions', 'UPDATE')
     OR has_table_privilege('ledgerx_api', 'ledger.ledger_entries', 'DELETE') THEN
    RAISE EXCEPTION 'ledgerx_api table privileges exceed its read-only surface';
  END IF;

  IF NOT has_function_privilege(
       'ledgerx_api', 'ledger.set_request_context(uuid,uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'ledgerx_api cannot establish verified workspace context';
  END IF;

  IF NOT has_function_privilege(
       'ledgerx_api', 'ledger.bootstrap_workspace(uuid,text,text,text,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'ledgerx_api cannot call the controlled onboarding function';
  END IF;
  IF has_function_privilege(
       'ledgerx_api', 'ledger.audit_integrity()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'ledgerx_api must not call the cross-workspace SECURITY DEFINER auditor';
  END IF;
  IF has_function_privilege(
       'ledgerx_api', 'ledger.create_workspace(text,text,text,text)', 'EXECUTE'
     ) OR has_function_privilege(
       'ledgerx_api', 'ledger.register_authenticated_user(uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'ledgerx_api must use the combined controlled bootstrap function';
  END IF;

  IF has_function_privilege(
       'ledgerx_api', 'ledger.deposit(text,text,bigint,bigint,numeric,text,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'ledgerx_api must not execute financial posting functions';
  END IF;
END
$api_role_privilege_assertions$;

ROLLBACK;
\echo 'Workspace API role privilege assertions passed.'
