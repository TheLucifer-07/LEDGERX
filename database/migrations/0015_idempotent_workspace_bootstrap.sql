-- Purpose: provide an idempotent, function-only first-workspace onboarding
-- path for a Supabase-authenticated user without granting direct table writes.

CREATE POLICY workspace_memberships_bootstrap_owner_select
  ON ledger.workspace_memberships
  FOR SELECT
  USING (
    current_setting('app.workspace_provisioning', true) = 'true'
    AND user_id = ledger.current_user_id()
  );

CREATE FUNCTION ledger.bootstrap_workspace(
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

  -- Serialize retries for a just-registered user so concurrent first requests
  -- cannot create two starter workspaces.
  PERFORM 1
    FROM ledger.app_users AS u
   WHERE u.user_id = v_user_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'could not lock the authenticated LedgerX user'
      USING ERRCODE = '40001';
  END IF;

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
  'Creates or returns a user-owned starter workspace; callable only after the API verifies the Supabase subject, and only through this controlled function.';
