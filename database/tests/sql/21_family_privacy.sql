-- Family workspace: a member's private records are invisible to every other member, including owners/admins.
BEGIN;
SELECT plan(33);

CREATE TEMP TABLE f AS SELECT t.mk_user('alice') AS alice, t.mk_user('bob') AS bob, t.mk_user('carol') AS carol, t.mk_user('stranger') AS stranger;
ALTER TABLE f ADD ws uuid, ADD cash uuid, ADD groceries uuid, ADD wallet uuid, ADD spend uuid, ADD inc uuid, ADD e1 uuid, ADD pkey text;
UPDATE f SET ws = t.mk_ws(alice, 'family');
SELECT t.add_member(ws, bob, 'member'), t.add_member(ws, carol, 'admin') FROM f;
UPDATE f SET cash = t.acct(ws,'1000'), groceries = t.acct(ws,'5010'),
  wallet = t.mk_account(bob, ws, 'P1', 'asset', 'INR', true), spend = t.mk_account(bob, ws, 'P2', 'expense', 'INR', true), inc = t.mk_account(bob, ws, 'P3', 'income', 'INR', true),
  pkey = 'private-probe-key-1';
UPDATE f SET e1 = t.entry_id(t.post(bob, ws, t.lines(t.dr(wallet,'500'), t.cr(inc,'500')), pkey, 'standard', 'secret income'));
SELECT is(t.replayed(t.post(bob, ws, t.lines(t.dr(spend,'120'), t.cr(wallet,'120')), NULL, 'standard', 'secret spend')), false, 'bob posts a second private entry') FROM f;

-- the owner of the private records sees them
SELECT is(t.visible(bob, ws, 'lx.accounts', 'owner_user_id IS NOT NULL'), 3, 'bob sees his 3 private accounts') FROM f;
SELECT is(t.visible(bob, ws, 'lx.journal_entries'), 2, 'bob sees his private entries') FROM f;
SELECT is(t.visible(bob, ws, 'lx.journal_lines'), 4, 'bob sees his private lines') FROM f;

-- nobody else does: not the workspace OWNER (alice), not an ADMIN (carol)
SELECT is(t.visible(who, ws, 'lx.accounts', 'owner_user_id IS NOT NULL'), 0, label || ': no private accounts')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(who, ws, 'lx.journal_entries'), 0, label || ': no private entries')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(who, ws, 'lx.journal_lines'), 0, label || ': no private lines')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(who, ws, 'lx.account_balances'), 0, label || ': no private balances')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(who, ws, 'lx.v_account_balances', $w$code LIKE 'P%'$w$), 0, label || ': private accounts absent from balance view')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(who, ws, 'lx.v_monthly_cashflow'), 0, label || ': private activity absent from cash-flow report')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(who, ws, 'lx.v_category_spend'), 0, label || ': private spend absent from category report')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(who, ws, 'lx.audit_events', $w$action LIKE 'journal.%'$w$), 0, label || ': private postings absent from the audit trail')
  FROM f, LATERAL (VALUES (alice, 'owner'), (carol, 'admin')) AS v(who, label);
SELECT is(t.visible(alice, ws, 'lx.accounts', format('id = %L', wallet)), 0, 'a private account cannot be fetched by id') FROM f;
SELECT is(t.run_as(alice, ws, 'SELECT * FROM lx.verify_account_balances()')->'rows', '[]'::jsonb, 'integrity verification never reveals private accounts') FROM f;

-- nobody else can write to or reverse them
SELECT is(t.code(t.post(alice, ws, t.lines(t.dr(wallet,'1'), t.cr(inc,'1')))), 'LX422', 'owner cannot post into a member''s private account') FROM f;
SELECT is(t.code(t.reverse(alice, ws, e1)), 'LX404', 'owner cannot reverse a member''s private entry') FROM f;

-- shared records are shared; private and shared never mix
SELECT is(t.replayed(t.post(alice, ws, t.lines(t.dr(groceries,'800'), t.cr(cash,'800')), NULL, 'standard', 'groceries')), false, 'alice posts a shared entry') FROM f;
SELECT is(t.visible(bob, ws, 'lx.journal_entries', $w$description = 'groceries'$w$), 1, 'a shared entry is visible to every member') FROM f;
SELECT is(t.run_as(bob, ws, format('SELECT balance::text AS b FROM lx.v_account_balances WHERE account_id = %L', groceries))->'rows'->0->>'b', '800.000000', 'shared balances are visible') FROM f;
SELECT matches(t.post(bob, ws, t.lines(t.dr(cash,'5'), t.cr(inc,'5')))->>'error', 'cannot be mixed', 'a private/shared mixed entry is rejected') FROM f;
SELECT t.post(bob, ws, t.lines(t.dr(spend,'999'), t.cr(wallet,'999'))) IS NOT NULL FROM f;
SELECT is(t.run_as(alice, ws, 'SELECT expense::text AS e FROM lx.v_monthly_cashflow')->'rows'->0->>'e', '800.000000', 'private spend never leaks into shared aggregates') FROM f;

-- an idempotency key cannot be used to probe another member's private entry
SELECT is(t.code(t.post(alice, ws, t.lines(t.dr(wallet,'500'), t.cr(inc,'500')), pkey)), 'LX409', 'idempotency keys cannot probe private entries') FROM f;

-- directory visibility
SELECT is(t.visible(bob, ws, 'lx.users'), 3, 'members see co-members') FROM f;
SELECT is(t.visible(stranger, NULL, 'lx.users'), 1, 'a stranger sees only himself') FROM f;
SELECT is(t.visible(bob, ws, 'lx.audit_events'), 0, 'plain members do not see the audit trail') FROM f;

SELECT * FROM finish();
ROLLBACK;
