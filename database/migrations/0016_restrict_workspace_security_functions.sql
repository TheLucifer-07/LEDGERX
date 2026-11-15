-- Purpose: remove PostgreSQL's default PUBLIC EXECUTE from workspace helpers
-- created by migration 0012, then fix bootstrap locking under forced RLS.

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA ledger FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ledger.current_workspace_id() TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.current_user_id() TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.current_supabase_user_id() TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.legacy_workspace_id() TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.default_workspace_id() TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.has_workspace_permission(uuid, text)
  TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.has_legacy_local_access(uuid)
  TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.register_authenticated_user(uuid)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.set_request_context(uuid, uuid)
  TO ledgerx_runtime, ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.create_workspace(text, text, text, text)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.bootstrap_workspace(uuid, text, text, text, text)
  TO ledgerx_api;
GRANT EXECUTE ON FUNCTION ledger.audit_integrity()
  TO ledgerx_runtime, ledgerx_dashboard, ledgerx_api;

CREATE OR REPLACE FUNCTION ledger.bootstrap_workspace(
  p_supabase_user_id uuid,
  p_workspace_type text,
  p_workspace_name text,
  p_default_currency_code text DEFAULT 'INR',
  p_timezone_name text DEFAULT 'Asia/Kolkata'
)
RETURNS TABLE(
  user_id uuid,
  workspace_id uuid,
  workspace_type text,
  workspace_name text,
  created boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_user_id uuid;
  v_workspace_id uuid;
  v_workspace_type text;
  v_workspace_name text;
  v_created boolean;
BEGIN
  v_user_id := ledger.register_authenticated_user(p_supabase_user_id);

  -- A transaction-scoped advisory lock serializes first-workspace retries
  -- without requiring UPDATE policy on app_users.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_supabase_user_id::text, 739118240067)
  );

  PERFORM set_config('app.workspace_provisioning', 'true', true);
  SELECT w.workspace_id, w.workspace_type, w.workspace_name
    INTO v_workspace_id, v_workspace_type, v_workspace_name
    FROM ledger.workspace_memberships AS wm
    JOIN ledger.workspaces AS w ON w.workspace_id = wm.workspace_id
   WHERE wm.user_id = v_user_id
     AND wm.role = 'owner'
     AND wm.status = 'active'
     AND w.status = 'active'
     AND w.workspace_type IN ('student', 'personal', 'family', 'business')
   ORDER BY wm.created_at, wm.workspace_id
   LIMIT 1;
  v_created := NOT FOUND;
  PERFORM set_config('app.workspace_provisioning', 'false', true);

  IF v_created THEN
    v_workspace_id := ledger.create_workspace(
      p_workspace_type,
      p_workspace_name,
      p_default_currency_code,
      p_timezone_name
    );
    SELECT w.workspace_type, w.workspace_name
      INTO v_workspace_type, v_workspace_name
      FROM ledger.workspaces AS w
     WHERE w.workspace_id = v_workspace_id;
  END IF;

  RETURN QUERY SELECT
    v_user_id, v_workspace_id, v_workspace_type, v_workspace_name, v_created;
END
$function$;

REVOKE ALL ON FUNCTION ledger.bootstrap_workspace(uuid, text, text, text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.bootstrap_workspace(uuid, text, text, text, text)
  TO ledgerx_api;

COMMENT ON FUNCTION ledger.bootstrap_workspace(uuid, text, text, text, text) IS
  'Creates or returns one owned starter workspace; serializes retries with a transaction advisory lock and must only receive a JWT-verified Supabase subject.';
