-- Purpose: keep the local legacy-only dashboard readable without granting its
-- role access to membership rows used by authenticated workspace checks.

CREATE OR REPLACE FUNCTION ledger.has_workspace_permission(
  p_workspace_id uuid,
  p_permission text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  -- The local analytics login is authorized by a separate legacy-only RLS
  -- predicate. It must never impersonate a mapped application user by setting
  -- custom GUC values, so skip membership lookup for this role entirely.
  IF session_user = 'ledgerx_dashboard' THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
      FROM ledger.workspace_memberships AS wm
      JOIN ledger.workspace_role_permissions AS rp ON rp.role = wm.role
     WHERE wm.workspace_id = p_workspace_id
       AND wm.user_id = ledger.current_user_id()
       AND wm.status = 'active'
       AND rp.permission = p_permission
  );
END
$function$;

COMMENT ON FUNCTION ledger.has_workspace_permission(uuid, text) IS
  'Checks active role permissions under RLS; local dashboard login always returns false and uses only its legacy-reader policy.';
