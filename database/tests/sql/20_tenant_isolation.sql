-- Fail-closed tenant context, workspace isolation, in-workspace roles, invitations, runtime-role limits.
BEGIN;
SELECT plan(55);

CREATE TEMP TABLE fx AS SELECT t.mk_user('alice') AS a, t.mk_user('bob') AS b;
ALTER TABLE fx ADD ws_a uuid, ADD ws_a2 uuid, ADD ws_b uuid, ADD a_cash uuid, ADD a_sal uuid, ADD a2_cash uuid, ADD b_cash uuid, ADD b_sal uuid;
UPDATE fx SET ws_a = t.mk_ws(a, 'personal'), ws_a2 = t.mk_ws(a, 'personal'), ws_b = t.mk_ws(b, 'business');
UPDATE fx SET a_cash = t.acct(ws_a,'1000'), a_sal = t.acct(ws_a,'4000'), a2_cash = t.acct(ws_a2,'1000'), b_cash = t.acct(ws_b,'1000'), b_sal = t.acct(ws_b,'4000');
DO $$ DECLARE r fx; BEGIN SELECT * INTO r FROM fx; PERFORM t.post(r.a, r.ws_a, t.lines(t.dr(r.a_cash,'10'), t.cr(r.a_sal,'10'))); END $$;

-- 1. no context => nothing visible, nothing callable ------------------------------------------------
SELECT is(t.visible(NULL, NULL, rel), 0, rel || ' is empty without tenant context')
  FROM unnest(ARRAY['lx.workspaces','lx.workspace_members','lx.accounts','lx.journal_entries','lx.journal_lines','lx.account_balances',
                    'lx.audit_events','lx.users','lx.invitations','lx.v_account_balances','lx.v_monthly_cashflow','lx.v_category_spend']) AS rel;
SELECT is(t.code(t.run_as(NULL, NULL, $q$SELECT lx.create_workspace('personal','x','INR')$q$)), 'LX401', 'create_workspace refuses without context');
SELECT is(t.code(t.run_as(NULL, NULL, $q$SELECT * FROM lx.post_journal_entry('abcdefgh','2026-01-01','x','[]')$q$)), 'LX401', 'posting refuses without context');

-- 2. set_context validates membership in the database ---------------------------------------------------
SELECT is(t.code(t.exec_role('ledgerx_runtime', format('SELECT lx.set_context(%L, %L)', b, ws_a))), 'LX403', 'set_context refuses a non-member') FROM fx;
SELECT is(t.code(t.exec_role('ledgerx_runtime', format('SELECT lx.set_context(%L, NULL)', gen_random_uuid()))), 'LX401', 'set_context refuses an unknown user');

-- 3. a forged raw setting grants nothing --------------------------------------------------------------------
SELECT is(t.run_forged(b::text, ws_a::text, 'SELECT count(*)::int AS n FROM lx.accounts')->'rows'->0->>'n', '0', 'forged setting: no accounts for a non-member') FROM fx;
SELECT is(t.run_forged(b::text, ws_a::text, 'SELECT count(*)::int AS n FROM lx.workspaces WHERE id = ' || quote_literal(ws_a))->'rows'->0->>'n', '0', 'forged setting: workspace not visible') FROM fx;
SELECT is(t.code(t.run_forged(b::text, ws_a::text, $q$SELECT * FROM lx.post_journal_entry('abcdefgh','2026-01-01','x','[]')$q$)), 'LX403', 'forged setting: posting refused') FROM fx;
SELECT is(t.run_forged('not-a-uuid', '', 'SELECT count(*)::int AS n FROM lx.workspaces')->'rows'->0->>'n', '0', 'malformed setting is treated as no context');

-- 4. isolation between workspaces / users --------------------------------------------------------------------
SELECT is(t.visible(b, ws_b, 'lx.journal_entries'), 0, 'bob cannot see alice''s entries') FROM fx;
SELECT is(t.visible(a, ws_a, 'lx.journal_entries'), 1, 'alice sees her entry') FROM fx;
SELECT is(t.visible(b, ws_b, 'lx.accounts', format('workspace_id <> %L', ws_b)), 0, 'bob''s accounts are only from his workspace') FROM fx;
SELECT is(t.visible(b, NULL, 'lx.workspaces'), 1, 'user-level context lists only my workspaces (bob)') FROM fx;
SELECT is(t.visible(a, NULL, 'lx.workspaces'), 2, 'user-level context lists only my workspaces (alice)') FROM fx;
SELECT is(t.visible(b, ws_b, 'lx.users'), 1, 'bob cannot see unrelated users') FROM fx;
SELECT is(t.visible(b, ws_b, 'lx.accounts', format('id = %L', a_cash)), 0, 'a foreign account id is invisible') FROM fx;
SELECT is(t.code(t.post(b, ws_b, t.lines(t.dr(a_cash,'5'), t.cr(a_sal,'5')))), 'LX422', 'cannot post against another workspace''s accounts') FROM fx;
SELECT is(t.code(t.post(b, ws_b, t.lines(t.dr(b_cash,'5'), t.cr(a_sal,'5')))), 'LX422', 'cannot mix in a foreign account') FROM fx;
SELECT throws_ok(format($f$INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit)
                           VALUES (%L, (SELECT id FROM lx.journal_entries WHERE workspace_id = %L LIMIT 1), 9, %L, 'INR', 1)$f$, ws_a, ws_a, a2_cash),
                 '23503', NULL, 'composite FK makes cross-workspace references impossible at the schema level') FROM fx;

-- 5. runtime role posture ------------------------------------------------------------------------------------
SELECT is((SELECT rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = 'ledgerx_runtime'), false, 'runtime role: no superuser/BYPASSRLS/CREATEROLE/CREATEDB');
SELECT is((SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'lx' AND pg_get_userbyid(c.relowner) = 'ledgerx_runtime'), 0, 'runtime role owns no lx objects');
SELECT is((SELECT array_agg(relname ORDER BY relname)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'lx' AND relkind = 'r' AND NOT relrowsecurity), '{currencies,schema_migrations}', 'every lx table except the reference/migration tables has RLS enabled');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'SELECT 1 FROM lx.idempotency_keys')), '42501', 'runtime cannot read idempotency_keys');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'SELECT auth_user_id FROM lx.users')), '42501', 'runtime cannot read users.auth_user_id');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'SELECT token_hash FROM lx.invitations')), '42501', 'runtime cannot read invitations.token_hash');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'SELECT 1 FROM lx.schema_migrations')), '42501', 'runtime cannot read schema_migrations');
SELECT is(t.code(t.exec_role('ledgerx_runtime', $q$INSERT INTO lx.workspaces (type, name, base_currency) VALUES ('personal','x','INR')$q$)), '42501', 'runtime cannot insert workspaces directly');
SELECT is(t.code(t.exec_role('ledgerx_runtime', $q$INSERT INTO lx.workspace_members (workspace_id, user_id, role) VALUES (gen_random_uuid(), gen_random_uuid(), 'owner')$q$)), '42501', 'runtime cannot grant itself membership');
SELECT is(t.code(t.exec_role('ledgerx_runtime', $q$SELECT lx._claim_idempotency(gen_random_uuid(), gen_random_uuid(), 'k', 'post', '\x00')$q$)), '42501', 'internal helper _claim_idempotency is not callable');
SELECT is(t.code(t.exec_role('ledgerx_runtime', $q$SELECT lx._require_ws(ARRAY['owner'], false)$q$)), '42501', 'internal helper _require_ws is not callable');

-- 6. roles inside a workspace ------------------------------------------------------------------------------------
CREATE TEMP TABLE rl AS SELECT t.mk_user('owner') AS o, t.mk_user('viewer') AS v, t.mk_user('member') AS m;
ALTER TABLE rl ADD ws uuid, ADD cash uuid, ADD sal uuid;
UPDATE rl SET ws = t.mk_ws(o, 'business');
SELECT t.add_member(ws, v, 'viewer'), t.add_member(ws, m, 'member') FROM rl;
UPDATE rl SET cash = t.acct(ws,'1000'), sal = t.acct(ws,'4000');
SELECT cmp_ok(t.visible(v, ws, 'lx.accounts'), '>', 0, 'viewer can read') FROM rl;
SELECT is(t.code(t.post(v, ws, t.lines(t.dr(cash,'5'), t.cr(sal,'5')))), 'LX403', 'viewer cannot post') FROM rl;
SELECT is(t.code(t.run_as(m, ws, $q$SELECT lx.create_account('7777','x','asset',NULL,'INR')$q$)), 'LX403', 'member cannot create shared accounts') FROM rl;
SELECT is(t.replayed(t.post(m, ws, t.lines(t.dr(cash,'5'), t.cr(sal,'5')))), false, 'member can post') FROM rl;
SELECT is(t.code(t.run_as(m, ws, $q$SELECT lx.create_account('7777','Mine','asset',NULL,'INR', true)$q$)), NULL, 'member can create a private account') FROM rl;
SELECT is(t.code(t.run_as(m, ws, 'SELECT * FROM lx.verify_account_balances()')), 'LX403', 'members cannot run integrity verification') FROM rl;

-- 7. demo workspaces are read-only; suspended members are locked out ----------------------------------------------------
CREATE TEMP TABLE dm AS SELECT t.mk_user('demo-owner') AS u, gen_random_uuid() AS ws;
INSERT INTO lx.workspaces (id, type, name, base_currency) SELECT ws, 'demo', 'Demo', 'INR' FROM dm;
INSERT INTO lx.workspace_members (workspace_id, user_id, role) SELECT ws, u, 'owner' FROM dm;
SELECT lx.seed_chart(ws, 'personal', 'INR') FROM dm;
SELECT is(t.code(t.run_as(u, ws, $q$SELECT lx.create_account('9','x','asset',NULL,'INR')$q$)), 'LX403', 'demo workspace: account creation refused') FROM dm;
SELECT is(t.code(t.post(u, ws, t.lines(t.dr(t.acct(ws,'1000'),'5'), t.cr(t.acct(ws,'4000'),'5')))), 'LX403', 'demo workspace: posting refused') FROM dm;
UPDATE lx.workspace_members SET status = 'suspended' WHERE workspace_id = (SELECT ws FROM rl) AND user_id = (SELECT m FROM rl);
SELECT is(t.code(t.exec_role('ledgerx_runtime', format('SELECT lx.set_context(%L, %L)', m, ws))), 'LX403', 'a suspended member is locked out') FROM rl;

-- 8. invitations ---------------------------------------------------------------------------------------------------------
CREATE TEMP TABLE fam AS SELECT t.mk_user('head') AS o, t.mk_user('kid') AS m;
ALTER TABLE fam ADD ws uuid, ADD pws uuid, ADD inv jsonb;
UPDATE fam SET ws = t.mk_ws(o, 'family'), pws = t.mk_ws(o, 'personal');
SELECT t.add_member(ws, m, 'member') FROM fam;
UPDATE fam SET inv = t.run_as(o, ws, $q$SELECT * FROM lx.create_invitation('Kid@Example.test','member')$q$)->'rows'->0;
SELECT is(length(inv->>'token'), 64, 'invitation token has 256 bits of entropy (64 hex chars)') FROM fam;
SELECT isnt((SELECT encode(token_hash, 'hex') FROM lx.invitations WHERE id = (inv->>'invitation_id')::uuid), inv->>'token', 'only a hash of the token is stored') FROM fam;
SELECT is(t.code(t.run_as(m, ws, $q$SELECT * FROM lx.create_invitation('x@example.test','member')$q$)), 'LX403', 'members cannot invite') FROM fam;
SELECT is(t.code(t.run_as(o, pws, $q$SELECT * FROM lx.create_invitation('x@example.test','member')$q$)), 'LX422', 'personal workspaces cannot invite') FROM fam;
SELECT is(t.visible(m, ws, 'lx.invitations'), 0, 'members cannot see invitations') FROM fam;

SELECT * FROM finish();
ROLLBACK;
