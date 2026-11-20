-- 010_rls_optimisation.sql : evaluate the tenant context ONCE PER QUERY instead of once per row.
--
-- Diagnosis (docs/evidence/rls-diagnosis.txt, benchmarks/before): the policies called
-- lx.has_ws_access(workspace_id) per row. A SECURITY DEFINER function cannot be inlined, is not
-- leakproof, and hides the workspace_id predicate from the planner, so every tenant-scoped query
-- became a sequential scan (231,432 function calls for one aggregate; 3.8 s on 240k lines vs 6 ms
-- when the filter is index-driven). The inlined ctx_user() helper also ran a regex per row.
--
-- Fix: the per-session facts (current workspace, user, "is the caller an active member of the
-- current workspace?") do not depend on the row, so they are wrapped in scalar sub-selects. The
-- planner turns each into an InitPlan (evaluated once) and  workspace_id = (InitPlan).col1  becomes an
-- index condition.
--
-- Security equivalence (proved by database/tests/sql/50_rls_policy_equivalence.sql, which compares
-- what every context can see under the old and new predicates):
--   has_ws_access(w)  ==  w = ctx_workspace() AND is_member_of(w)  ==  w = (SELECT ctx_workspace())
--                                                                     AND (SELECT ctx_has_access())
-- NULL semantics are unchanged: a missing context makes every comparison NULL => no rows (fail closed).

CREATE FUNCTION lx.ctx_has_access() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT lx.has_ws_access(lx.ctx_workspace())
$$;

-- Workspaces the caller is an active member of (same condition as lx.is_member_of, as a set).
CREATE FUNCTION lx.my_workspace_ids() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(array_agg(m.workspace_id), ARRAY[]::uuid[])
    FROM lx.workspace_members m JOIN lx.users u ON u.id = m.user_id
   WHERE m.user_id = lx.ctx_user() AND m.status = 'active' AND u.deleted_at IS NULL
$$;

-- Active members of the current workspace, visible only if the caller is one of them
-- (same condition as lx.shares_workspace, as a set).
CREATE FUNCTION lx.ctx_coworker_ids() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(array_agg(m.user_id), ARRAY[]::uuid[])
    FROM lx.workspace_members m
   WHERE lx.ctx_has_access() AND m.workspace_id = lx.ctx_workspace() AND m.status = 'active'
$$;

GRANT EXECUTE ON FUNCTION lx.ctx_has_access(), lx.my_workspace_ids(), lx.ctx_coworker_ids() TO ledgerx_runtime;

ALTER POLICY users_select ON lx.users
  USING (id = (SELECT lx.ctx_user()) OR id = ANY ((SELECT lx.ctx_coworker_ids())::uuid[]));

ALTER POLICY workspaces_select ON lx.workspaces
  USING (id = ANY ((SELECT lx.my_workspace_ids())::uuid[]));

ALTER POLICY members_select ON lx.workspace_members
  USING (user_id = (SELECT lx.ctx_user())
         OR (workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access())));

ALTER POLICY invitations_select ON lx.invitations
  USING (workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access())
         AND (SELECT lx.ctx_role()) IN ('owner','admin'));

ALTER POLICY accounts_select ON lx.accounts
  USING (workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access())
         AND (owner_user_id IS NULL OR owner_user_id = (SELECT lx.ctx_user())));

ALTER POLICY entries_select ON lx.journal_entries
  USING (workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access())
         AND (private_owner_id IS NULL OR private_owner_id = (SELECT lx.ctx_user())));

ALTER POLICY lines_select ON lx.journal_lines
  USING (workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access())
         AND (private_owner_id IS NULL OR private_owner_id = (SELECT lx.ctx_user())));

ALTER POLICY balances_select ON lx.account_balances
  USING (workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access())
         AND (private_owner_id IS NULL OR private_owner_id = (SELECT lx.ctx_user())));

ALTER POLICY audit_select ON lx.audit_events
  USING (workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access())
         AND (SELECT lx.ctx_role()) IN ('owner','admin')
         AND (private_owner_id IS NULL OR private_owner_id = (SELECT lx.ctx_user())));
