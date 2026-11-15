-- Purpose: let the idempotent bootstrap function see only workspaces already
-- owned by its authenticated app user while the selected workspace is blank.

CREATE POLICY workspaces_bootstrap_owner_select
  ON ledger.workspaces
  FOR SELECT
  USING (
    current_setting('app.workspace_provisioning', true) = 'true'
    AND EXISTS (
      SELECT 1
        FROM ledger.workspace_memberships AS wm
       WHERE wm.workspace_id = workspaces.workspace_id
         AND wm.user_id = ledger.current_user_id()
         AND wm.role = 'owner'
         AND wm.status = 'active'
    )
  );
