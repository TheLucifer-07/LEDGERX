-- 002_tenant_context.sql : Transaction-local tenant context, membership checks, audit helper
-- Part of the LedgerX ledger core. Error codes (custom SQLSTATEs, mapped by callers):
--   LX401 no/invalid tenant context  LX403 forbidden  LX404 not found
--   LX409 conflict / idempotency      LX422 validation  LX423 immutable record

-- ================================================================ context helpers
CREATE FUNCTION lx.ctx_user() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_setting('lx.user_id', true) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              THEN current_setting('lx.user_id', true)::uuid END
$$;

CREATE FUNCTION lx.ctx_workspace() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_setting('lx.workspace_id', true) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              THEN current_setting('lx.workspace_id', true)::uuid END
$$;

-- Membership checks always hit the tables: a forged setting for a non-member grants nothing.
CREATE FUNCTION lx.is_member_of(p_ws uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM lx.workspace_members m JOIN lx.users u ON u.id = m.user_id
                 WHERE m.workspace_id = p_ws AND m.user_id = lx.ctx_user()
                   AND m.status = 'active' AND u.deleted_at IS NULL)
$$;

CREATE FUNCTION lx.has_ws_access(p_ws uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  SELECT p_ws IS NOT NULL AND p_ws = lx.ctx_workspace() AND lx.is_member_of(p_ws)
$$;

CREATE FUNCTION lx.ctx_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  SELECT m.role FROM lx.workspace_members m
  WHERE m.workspace_id = lx.ctx_workspace() AND m.user_id = lx.ctx_user() AND m.status = 'active'
$$;

CREATE FUNCTION lx.can_see_private(p_owner uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_owner IS NULL OR p_owner = lx.ctx_user()
$$;

CREATE FUNCTION lx.shares_workspace(p_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  SELECT lx.has_ws_access(lx.ctx_workspace()) AND EXISTS (
    SELECT 1 FROM lx.workspace_members m
    WHERE m.workspace_id = lx.ctx_workspace() AND m.user_id = p_user AND m.status = 'active')
$$;

CREATE FUNCTION lx.resolve_user(p_auth_user_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  SELECT id FROM lx.users WHERE auth_user_id = p_auth_user_id AND deleted_at IS NULL
$$;

CREATE FUNCTION lx.schema_version() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  SELECT max(version) FROM lx.schema_migrations
$$;

-- Called ONLY by trusted backend code after JWT verification. Validates membership in the
-- database and sets transaction-local settings (is_local = true => cleared at COMMIT/ROLLBACK).
CREATE FUNCTION lx.set_context(p_user uuid, p_workspace uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
BEGIN
  PERFORM set_config('lx.user_id', '', true);
  PERFORM set_config('lx.workspace_id', '', true);
  IF p_user IS NULL OR NOT EXISTS (SELECT 1 FROM lx.users WHERE id = p_user AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'invalid user context' USING ERRCODE = 'LX401';
  END IF;
  IF p_workspace IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM lx.workspace_members
       WHERE workspace_id = p_workspace AND user_id = p_user AND status = 'active') THEN
    RAISE EXCEPTION 'not a member of this workspace' USING ERRCODE = 'LX403';
  END IF;
  PERFORM set_config('lx.user_id', p_user::text, true);
  PERFORM set_config('lx.workspace_id', coalesce(p_workspace::text, ''), true);
END $$;

-- Internal: verifies context + role (+ writability). Returns the caller's role.
CREATE FUNCTION lx._require_ws(p_roles text[], p_write boolean) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE v_role text; w record;
BEGIN
  IF lx.ctx_user() IS NULL OR lx.ctx_workspace() IS NULL THEN
    RAISE EXCEPTION 'tenant context is required' USING ERRCODE = 'LX401';
  END IF;
  SELECT m.role INTO v_role FROM lx.workspace_members m JOIN lx.users u ON u.id = m.user_id
   WHERE m.workspace_id = lx.ctx_workspace() AND m.user_id = lx.ctx_user()
     AND m.status = 'active' AND u.deleted_at IS NULL;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not a member of this workspace' USING ERRCODE = 'LX403';
  END IF;
  IF NOT (v_role = ANY (p_roles)) THEN
    RAISE EXCEPTION 'role % may not perform this action', v_role USING ERRCODE = 'LX403';
  END IF;
  IF p_write THEN
    SELECT type, archived_at INTO w FROM lx.workspaces WHERE id = lx.ctx_workspace();
    IF w.type = 'demo' THEN RAISE EXCEPTION 'demo workspaces are read-only' USING ERRCODE = 'LX403'; END IF;
    IF w.archived_at IS NOT NULL THEN RAISE EXCEPTION 'workspace is archived' USING ERRCODE = 'LX403'; END IF;
  END IF;
  RETURN v_role;
END $$;

CREATE FUNCTION lx._audit(p_ws uuid, p_actor uuid, p_action text, p_type text, p_entity uuid,
                          p_private uuid, p_details jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  INSERT INTO lx.audit_events (workspace_id, actor_user_id, action, entity_type, entity_id, private_owner_id, details)
  VALUES (p_ws, p_actor, p_action, p_type, p_entity, p_private, coalesce(p_details, '{}'::jsonb))
$$;
