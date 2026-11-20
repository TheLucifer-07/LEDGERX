-- Reversals, transfers vs income/expense, projection drift/rebuild, audit trail.
BEGIN;
SELECT plan(26);

CREATE TEMP TABLE fx AS SELECT t.mk_user('alice') AS u;
ALTER TABLE fx ADD ws uuid, ADD cash uuid, ADD bank uuid, ADD salary uuid, ADD food uuid, ADD income_e uuid, ADD spend_e uuid, ADD rev_e uuid, ADD rev_key text;
UPDATE fx SET ws = t.mk_ws(u);
UPDATE fx SET cash = t.acct(ws,'1000'), bank = t.acct(ws,'1100'), salary = t.acct(ws,'4000'), food = t.acct(ws,'5010'), rev_key = 'reverse-key-00001';
UPDATE fx SET income_e = t.entry_id(t.post(u, ws, t.lines(t.dr(cash,'1000'), t.cr(salary,'1000'))));
UPDATE fx SET spend_e  = t.entry_id(t.post(u, ws, t.lines(t.dr(food,'300'), t.cr(cash,'300'))));
SELECT is(t.balance(cash), 700.00, 'before reversal: cash = 1000 - 300') FROM fx;
UPDATE fx SET rev_e = t.entry_id(t.reverse(u, ws, spend_e, rev_key, 'entered twice'));

-- reversals --------------------------------------------------------------------------------------
SELECT is(t.balance(cash), 1000.00, 'reversal restores the cash balance') FROM fx;
SELECT is(t.balance(food), 0.00, 'reversal zeroes the expense') FROM fx;
SELECT is((SELECT count(*)::int FROM lx.journal_entries WHERE workspace_id = ws), 3, 'original and reversal both remain in the ledger') FROM fx;
SELECT results_eq(format($q$SELECT kind, reverses_entry_id FROM lx.journal_entries WHERE id = %L$q$, rev_e),
                  format($q$VALUES ('reversal'::text, %L::uuid)$q$, spend_e), 'the reversal points at the original') FROM fx;
SELECT is((SELECT expense FROM lx.v_monthly_cashflow WHERE workspace_id = ws), 0.00, 'reports: expense is compensated') FROM fx;
SELECT is((SELECT net FROM lx.v_monthly_cashflow WHERE workspace_id = ws), 1000.00, 'reports: net reflects the reversal') FROM fx;
SELECT is(t.entry_id(t.reverse(u, ws, spend_e, rev_key, 'entered twice')), rev_e, 'reversal is idempotent: replay returns the same entry') FROM fx;
SELECT is(t.replayed(t.reverse(u, ws, spend_e, rev_key, 'entered twice')), true, 'reversal replay is flagged') FROM fx;
SELECT is(t.code(t.reverse(u, ws, spend_e)), 'LX409', 'an entry can only be reversed once') FROM fx;
SELECT is(t.code(t.reverse(u, ws, rev_e)), 'LX422', 'a reversal cannot be reversed') FROM fx;
SELECT is(t.code(t.reverse(u, ws, gen_random_uuid())), 'LX404', 'unknown entry is not found') FROM fx;
SELECT is(t.code(t.reverse(u, ws, income_e, NULL, '')), 'LX422', 'a reason is required') FROM fx;

-- transfers --------------------------------------------------------------------------------------
CREATE TEMP TABLE fx2 AS SELECT t.mk_user('bob') AS u;
ALTER TABLE fx2 ADD ws uuid, ADD cash uuid, ADD bank uuid, ADD salary uuid, ADD food uuid;
UPDATE fx2 SET ws = t.mk_ws(u);
UPDATE fx2 SET cash = t.acct(ws,'1000'), bank = t.acct(ws,'1100'), salary = t.acct(ws,'4000'), food = t.acct(ws,'5010');
DO $$ DECLARE r fx2; BEGIN SELECT * INTO r FROM fx2;
  PERFORM t.post(r.u, r.ws, t.lines(t.dr(r.cash,'1000'), t.cr(r.salary,'1000')));
  PERFORM t.post(r.u, r.ws, t.lines(t.dr(r.food,'200'), t.cr(r.cash,'200')));
  PERFORM t.post(r.u, r.ws, t.lines(t.dr(r.bank,'500'), t.cr(r.cash,'500')), NULL, 'transfer');
END $$;
SELECT is((SELECT income FROM lx.v_monthly_cashflow WHERE workspace_id = ws), 1000.00, 'a transfer is not income') FROM fx2;
SELECT is((SELECT expense FROM lx.v_monthly_cashflow WHERE workspace_id = ws), 200.00, 'a transfer is not spending') FROM fx2;
SELECT is(t.balance(bank), 500.00, 'transfer credits the destination account') FROM fx2;
SELECT is(t.balance(cash), 300.00, 'transfer debits the source account') FROM fx2;
SELECT is(t.code(t.post(u, ws, t.lines(t.dr(cash,'5'), t.cr(salary,'5')), NULL, 'transfer')), 'LX422', 'a transfer cannot touch income/expense accounts') FROM fx2;

-- projection drift and rebuild ---------------------------------------------------------------------
SELECT is(t.run_as(u, ws, 'SELECT * FROM lx.verify_account_balances()')->'rows', '[]'::jsonb, 'verification: projection matches the ledger') FROM fx2;
SELECT is(t.code(t.exec_role('ledgerx_migrator', format($q$UPDATE lx.account_balances SET debit_total = debit_total + 1 WHERE account_id = %L$q$, cash))), NULL, 'simulate corruption of the projection') FROM fx2;
SELECT is(jsonb_array_length(t.run_as(u, ws, 'SELECT * FROM lx.verify_account_balances()')->'rows'), 1, 'verification detects exactly the corrupted account') FROM fx2;
SELECT is(t.run_as(u, ws, 'SELECT * FROM lx.verify_account_balances()')->'rows'->0->>'account_id', cash::text, 'and identifies it') FROM fx2;
SELECT is(t.code(t.run_as(u, ws, 'SELECT lx.rebuild_account_balances()')), NULL, 'rebuild runs') FROM fx2;
SELECT is(t.run_as(u, ws, 'SELECT * FROM lx.verify_account_balances()')->'rows', '[]'::jsonb, 'after rebuild the projection matches the ledger again') FROM fx2;
SELECT is(t.balance(cash), 300.00, 'and the balance is correct') FROM fx2;

-- audit trail --------------------------------------------------------------------------------------
SELECT bag_eq(format($q$SELECT DISTINCT action FROM lx.audit_events WHERE workspace_id = %L$q$, ws),
              $q$VALUES ('workspace.created'), ('journal.posted'), ('journal.reversed')$q$, 'audit trail records creation, postings and reversals') FROM fx;

SELECT * FROM finish();
ROLLBACK;
