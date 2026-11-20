-- Immutability of the ledger and audit trail; write-path privileges; commit-time balance check.
BEGIN;
SELECT plan(14);

CREATE TEMP TABLE fx AS SELECT t.mk_user('alice') AS u;
ALTER TABLE fx ADD ws uuid, ADD cash uuid, ADD salary uuid, ADD e1 uuid, ADD bad_entry uuid;
UPDATE fx SET ws = t.mk_ws(u);
UPDATE fx SET cash = t.acct(ws,'1000'), salary = t.acct(ws,'4000');
UPDATE fx SET e1 = t.entry_id(t.post(u, ws, t.lines(t.dr(cash,'5'), t.cr(salary,'5'))));

-- even the table OWNER cannot rewrite history
SELECT is(t.code(t.exec_role('ledgerx_migrator', $q$UPDATE lx.journal_entries SET description = 'tampered'$q$)), 'LX423', 'owner cannot UPDATE journal_entries');
SELECT is(t.code(t.exec_role('ledgerx_migrator', $q$DELETE FROM lx.journal_entries$q$)), 'LX423', 'owner cannot DELETE journal_entries');
SELECT is(t.code(t.exec_role('ledgerx_migrator', $q$UPDATE lx.journal_lines SET debit = 9999 WHERE debit > 0$q$)), 'LX423', 'owner cannot UPDATE journal_lines');
SELECT is(t.code(t.exec_role('ledgerx_migrator', $q$DELETE FROM lx.journal_lines$q$)), 'LX423', 'owner cannot DELETE journal_lines');
-- TRUNCATE protection needs a committed transaction (pending trigger events block TRUNCATE): see tests/multisession.
SELECT is(t.code(t.exec_role('ledgerx_migrator', $q$UPDATE lx.audit_events SET action = 'x'$q$)), 'LX423', 'audit events are append-only');

-- the runtime role has no direct write path at all
SELECT is(t.code(t.exec_role('ledgerx_runtime', format($q$INSERT INTO lx.journal_entries (workspace_id, entry_date, description, created_by) VALUES (%L,'2026-01-01','x',%L)$q$, ws, u))), '42501', 'runtime cannot INSERT entries directly') FROM fx;
SELECT is(t.code(t.exec_role('ledgerx_runtime', $q$UPDATE lx.journal_lines SET memo = 'x'$q$)), '42501', 'runtime cannot UPDATE lines');
SELECT is(t.code(t.exec_role('ledgerx_runtime', $q$DELETE FROM lx.journal_lines$q$)), '42501', 'runtime cannot DELETE lines');
SELECT is(t.code(t.exec_role('ledgerx_runtime', format($q$INSERT INTO lx.account_balances (workspace_id, account_id, currency) VALUES (%L,%L,'INR')$q$, ws, cash))), '42501', 'runtime cannot write the balance projection') FROM fx;

-- account identity is immutable; accounts cannot be deleted; renaming is allowed
SELECT is(t.code(t.exec_role('ledgerx_migrator', format($q$UPDATE lx.accounts SET currency = 'USD' WHERE id = %L$q$, cash))), 'LX423', 'account currency is immutable') FROM fx;
SELECT is(t.code(t.exec_role('ledgerx_migrator', format($q$UPDATE lx.accounts SET class = 'income' WHERE id = %L$q$, cash))), 'LX423', 'account class is immutable') FROM fx;
SELECT is(t.code(t.exec_role('ledgerx_migrator', format($q$DELETE FROM lx.accounts WHERE id = %L$q$, cash))), 'LX423', 'accounts cannot be deleted') FROM fx;
SELECT is(t.exec_role('ledgerx_migrator', format($q$UPDATE lx.accounts SET name = 'Wallet' WHERE id = %L$q$, cash))->>'ok', 'true', 'renaming an account is allowed') FROM fx;

-- commit-time balance check (deferred constraint trigger). SET CONSTRAINTS ... IMMEDIATE forces the
-- check that COMMIT would run. A real COMMIT is exercised in tests/multisession.
UPDATE fx SET bad_entry = gen_random_uuid();
INSERT INTO lx.journal_entries (id, workspace_id, entry_date, description, created_by) SELECT bad_entry, ws, '2026-11-01', 'direct unbalanced', u FROM fx;
INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit, credit)
  SELECT ws, bad_entry, 1, cash, 'INR', 10, 0 FROM fx UNION ALL SELECT ws, bad_entry, 2, salary, 'INR', 0, 9 FROM fx;
SELECT throws_ok('SET CONSTRAINTS ALL IMMEDIATE', 'LX422', NULL, 'deferred trigger rejects a directly inserted unbalanced entry');

SELECT * FROM finish();
ROLLBACK;
