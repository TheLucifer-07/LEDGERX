-- 007_rls_and_grants.sql : fail-closed row-level security + least-privilege grants.
-- The runtime role (ledgerx_runtime) does NOT own these tables and has no BYPASSRLS.
-- It can read through RLS and can WRITE ONLY through the SECURITY DEFINER API functions.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledgerx_runtime') THEN
    RAISE EXCEPTION 'role ledgerx_runtime is missing: run database/bootstrap first';
  END IF;
END $$;

GRANT USAGE ON SCHEMA lx TO ledgerx_runtime;
-- Belt and braces: nothing is executable by PUBLIC; only the grants below open the API.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA lx FROM PUBLIC;

ALTER TABLE lx.users             ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.workspaces        ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.workspace_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.invitations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.accounts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.journal_entries   ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.journal_lines     ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.account_balances  ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.audit_events      ENABLE ROW LEVEL SECURITY;
ALTER TABLE lx.idempotency_keys  ENABLE ROW LEVEL SECURITY;   -- no policy + no grant => unreadable

CREATE POLICY users_select ON lx.users FOR SELECT TO ledgerx_runtime
  USING (id = lx.ctx_user() OR lx.shares_workspace(id));

CREATE POLICY workspaces_select ON lx.workspaces FOR SELECT TO ledgerx_runtime
  USING (lx.is_member_of(id));

CREATE POLICY members_select ON lx.workspace_members FOR SELECT TO ledgerx_runtime
  USING (user_id = lx.ctx_user() OR lx.has_ws_access(workspace_id));

CREATE POLICY invitations_select ON lx.invitations FOR SELECT TO ledgerx_runtime
  USING (lx.has_ws_access(workspace_id) AND lx.ctx_role() IN ('owner','admin'));

CREATE POLICY accounts_select ON lx.accounts FOR SELECT TO ledgerx_runtime
  USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(owner_user_id));

CREATE POLICY entries_select ON lx.journal_entries FOR SELECT TO ledgerx_runtime
  USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(private_owner_id));

CREATE POLICY lines_select ON lx.journal_lines FOR SELECT TO ledgerx_runtime
  USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(private_owner_id));

CREATE POLICY balances_select ON lx.account_balances FOR SELECT TO ledgerx_runtime
  USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(private_owner_id));

CREATE POLICY audit_select ON lx.audit_events FOR SELECT TO ledgerx_runtime
  USING (lx.has_ws_access(workspace_id) AND lx.ctx_role() IN ('owner','admin')
         AND lx.can_see_private(private_owner_id));

-- Table privileges: SELECT only (no INSERT/UPDATE/DELETE/TRUNCATE anywhere).
GRANT SELECT ON lx.currencies, lx.workspaces, lx.workspace_members, lx.accounts,
                lx.journal_entries, lx.journal_lines, lx.account_balances, lx.audit_events
  TO ledgerx_runtime;
GRANT SELECT (id, workspace_id, email, role, invited_by, expires_at, accepted_at, revoked_at, created_at)
  ON lx.invitations TO ledgerx_runtime;  -- never token_hash
GRANT SELECT (id, email, display_name, created_at) ON lx.users TO ledgerx_runtime;  -- never auth_user_id

-- Functions evaluated inside policies:
GRANT EXECUTE ON FUNCTION lx.ctx_user(), lx.ctx_workspace(), lx.ctx_role(), lx.is_member_of(uuid),
  lx.has_ws_access(uuid), lx.can_see_private(uuid), lx.shares_workspace(uuid) TO ledgerx_runtime;

-- Public API (write path):
GRANT EXECUTE ON FUNCTION
  lx.resolve_user(uuid), lx.provision_user(uuid, text, text), lx.schema_version(),
  lx.set_context(uuid, uuid), lx.create_workspace(text, text, char), 
  lx.create_account(text, text, text, text, char, boolean, uuid),
  lx.create_invitation(text, text),
  lx.post_journal_entry(text, date, text, jsonb, text, jsonb),
  lx.reverse_journal_entry(uuid, text, text, date),
  lx.verify_account_balances(), lx.rebuild_account_balances()
  TO ledgerx_runtime;
