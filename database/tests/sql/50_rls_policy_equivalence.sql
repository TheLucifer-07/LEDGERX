-- Proof that the RLS optimisation (migration 010) preserved every security guarantee.
-- For a generated multi-tenant dataset (4 workspaces incl. a family workspace with private records),
-- we compute, for EVERY relevant context, a fingerprint of exactly which rows each protected relation
-- exposes — under the current (optimised) policies and under the ORIGINAL per-row policies — and require
-- identical results. Contexts include: every member, no context, and members probing foreign workspaces.
-- A negative control (a deliberately leaky policy) proves this test can actually detect a difference.
BEGIN;
SELECT plan(13);

SELECT bench.generate(4, 400, 'equiv');
CREATE TEMP TABLE ctxs AS
  SELECT m.user_id AS u, m.workspace_id AS ws FROM lx.workspace_members m
  UNION ALL SELECT NULL, NULL                                                           -- no context
  UNION ALL SELECT u1.user_id, w2.workspace_id                                          -- member of one workspace probing another
    FROM (SELECT DISTINCT ON (workspace_id) user_id, workspace_id FROM lx.workspace_members ORDER BY workspace_id) u1
    JOIN (SELECT DISTINCT workspace_id FROM lx.workspace_members) w2 ON w2.workspace_id <> u1.workspace_id
  UNION ALL SELECT u1.user_id, NULL FROM (SELECT DISTINCT user_id FROM lx.workspace_members) u1;      -- user-level context
SELECT cmp_ok((SELECT count(*)::int FROM ctxs), '>=', 20, 'a meaningful number of contexts is compared');

CREATE TEMP TABLE rels (rel text PRIMARY KEY, pk text);
INSERT INTO rels VALUES ('lx.users','id'), ('lx.workspaces','id'), ('lx.workspace_members','user_id::text || workspace_id::text'),
  ('lx.invitations','id'), ('lx.accounts','id'), ('lx.journal_entries','id'), ('lx.journal_lines','id'),
  ('lx.account_balances','account_id'), ('lx.audit_events','id');

-- fingerprint(context, relation) -> md5 of the visible primary keys, or of the error
CREATE FUNCTION pg_temp.sig() RETURNS TABLE (rel text, sig text) LANGUAGE sql AS $$
  SELECT r.rel, md5(string_agg(coalesce(
           t.run_as(c.u, c.ws, format('SELECT coalesce(string_agg((%s)::text, '','' ORDER BY %s::text), '''') AS h FROM %s', r.pk, r.pk, r.rel))::text, 'x'),
         '|' ORDER BY c.u, c.ws))
    FROM rels r CROSS JOIN ctxs c GROUP BY r.rel
$$;
CREATE TEMP TABLE sig_new AS SELECT * FROM pg_temp.sig();

-- negative control: a policy that leaks must change the fingerprint
ALTER POLICY accounts_select ON lx.accounts USING (true);
CREATE TEMP TABLE sig_leaky AS SELECT * FROM pg_temp.sig() WHERE rel = 'lx.accounts';
SELECT isnt((SELECT sig FROM sig_leaky), (SELECT sig FROM sig_new WHERE rel = 'lx.accounts'), 'negative control: the comparison detects a leaky policy');

-- restore the ORIGINAL (pre-optimisation) predicates exactly as written in migration 007
ALTER POLICY users_select ON lx.users USING (id = lx.ctx_user() OR lx.shares_workspace(id));
ALTER POLICY workspaces_select ON lx.workspaces USING (lx.is_member_of(id));
ALTER POLICY members_select ON lx.workspace_members USING (user_id = lx.ctx_user() OR lx.has_ws_access(workspace_id));
ALTER POLICY invitations_select ON lx.invitations USING (lx.has_ws_access(workspace_id) AND lx.ctx_role() IN ('owner','admin'));
ALTER POLICY accounts_select ON lx.accounts USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(owner_user_id));
ALTER POLICY entries_select ON lx.journal_entries USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(private_owner_id));
ALTER POLICY lines_select ON lx.journal_lines USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(private_owner_id));
ALTER POLICY balances_select ON lx.account_balances USING (lx.has_ws_access(workspace_id) AND lx.can_see_private(private_owner_id));
ALTER POLICY audit_select ON lx.audit_events USING (lx.has_ws_access(workspace_id) AND lx.ctx_role() IN ('owner','admin') AND lx.can_see_private(private_owner_id));
CREATE TEMP TABLE sig_old AS SELECT * FROM pg_temp.sig();

SELECT is((SELECT sig FROM sig_new n WHERE n.rel = r.rel), (SELECT sig FROM sig_old o WHERE o.rel = r.rel), 'identical visibility under old and new policies: ' || r.rel)
  FROM rels r ORDER BY r.rel;
-- the compared data is not trivially empty: at least the shared/private rows exist
SELECT cmp_ok((SELECT count(*)::int FROM lx.journal_lines WHERE private_owner_id IS NOT NULL), '>', 0, 'dataset contains private rows (the interesting case)');
SELECT cmp_ok((SELECT count(DISTINCT sig)::int FROM sig_new), '>', 5, 'fingerprints are non-degenerate');

SELECT * FROM finish();
ROLLBACK;
