\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.deposit(
  'integrity-test', 'deposit',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-INTEGRITY-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-INTEGRITY-USD'),
  5.00, 'USD', 'integrity-projection-test'
);
SELECT ledger.reverse_transaction(
  'integrity-test', 'reverse-deposit',
  (SELECT transaction_id FROM ledger.idempotency_keys
    WHERE scope = 'integrity-test' AND idempotency_key = 'deposit')
);
SET CONSTRAINTS ALL IMMEDIATE;

RESET ROLE;
UPDATE ledger.account_balances AS b
   SET posted_balance = b.posted_balance + 7.00
  FROM ledger.accounts AS a
 WHERE a.account_code = 'WALLET-INTEGRITY-USD'
   AND b.account_id = a.account_id;

SET LOCAL ROLE ledgerx_runtime;
DO $test$
DECLARE
  v_finding_count bigint;
BEGIN
  SELECT count(*) INTO v_finding_count
    FROM ledger.audit_integrity() AS finding
   WHERE finding_type = 'projection_mismatch'
     AND entity_id = (
       SELECT account_id::text FROM ledger.accounts
        WHERE account_code = 'WALLET-INTEGRITY-USD'
     );
  IF v_finding_count <> 1 THEN
    RAISE EXCEPTION 'auditor did not find the injected projection mismatch';
  END IF;

  IF has_function_privilege(
      'ledgerx_runtime', 'ledger.rebuild_account_balances()', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'runtime role can execute projection rebuild';
  END IF;
END
$test$;

RESET ROLE;
SET LOCAL ROLE ledgerx_owner;
CALL ledger.rebuild_account_balances();
SET LOCAL ROLE ledgerx_runtime;

DO $test$
DECLARE
  v_finding_count bigint;
  v_balance numeric(20,4);
BEGIN
  SELECT count(*) INTO v_finding_count FROM ledger.audit_integrity();
  IF v_finding_count <> 0 THEN
    RAISE EXCEPTION 'findings remain after rebuild: %', v_finding_count;
  END IF;
  SELECT b.posted_balance INTO v_balance
    FROM ledger.account_balances AS b
    JOIN ledger.accounts AS a USING (account_id)
   WHERE a.account_code = 'WALLET-INTEGRITY-USD';
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'rebuild expected wallet balance 0, got %', v_balance;
  END IF;
  RAISE NOTICE 'integrity audit and projection rebuild: passed';
END
$test$;

RESET ROLE;
SET LOCAL ROLE ledgerx_owner;
INSERT INTO ledger.accounts (
  customer_id, account_code, account_kind, normal_side, currency_code, status
)
VALUES (
  (SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1002'),
  'WALLET-PROJECTION-RECOVERY-TEST', 'customer_wallet', 'credit', 'USD', 'open'
);

DO $test$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM ledger.account_balances AS b
    JOIN ledger.accounts AS a USING (account_id)
    WHERE a.account_code = 'WALLET-PROJECTION-RECOVERY-TEST'
      AND b.posted_balance = 0
  ) THEN
    RAISE EXCEPTION 'new account did not receive a zero balance projection';
  END IF;
END
$test$;

RESET ROLE;
SET LOCAL ROLE ledgerx_runtime;
SET CONSTRAINTS ALL DEFERRED;
SELECT ledger.deposit(
  'integrity-test', 'projection-recovery-deposit',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-INTEGRITY-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-PROJECTION-RECOVERY-TEST'),
  5.00, 'USD', 'projection-recovery-history'
);
SET CONSTRAINTS ALL IMMEDIATE;

RESET ROLE;
DELETE FROM ledger.account_balances AS b
 USING ledger.accounts AS a
 WHERE a.account_code = 'WALLET-PROJECTION-RECOVERY-TEST'
   AND b.account_id = a.account_id;

SET LOCAL ROLE ledgerx_runtime;
DO $test$
DECLARE
  v_account_id text;
  v_finding_count bigint;
BEGIN
  SELECT account_id::text INTO v_account_id FROM ledger.accounts
   WHERE account_code = 'WALLET-PROJECTION-RECOVERY-TEST';
  SELECT count(*) INTO v_finding_count FROM ledger.audit_integrity()
   WHERE finding_type = 'projection_missing' AND entity_id = v_account_id;
  IF v_finding_count <> 1 THEN
    RAISE EXCEPTION 'auditor did not identify the missing account projection';
  END IF;
END
$test$;

RESET ROLE;
SET LOCAL ROLE ledgerx_owner;
CALL ledger.rebuild_account_balances();
SET LOCAL ROLE ledgerx_runtime;
DO $test$
DECLARE
  v_balance numeric(20,4);
  v_entry_count bigint;
  v_entry_amount numeric(20,4);
  v_finding_count bigint;
BEGIN
  SELECT b.posted_balance INTO v_balance
    FROM ledger.account_balances AS b
    JOIN ledger.accounts AS a USING (account_id)
   WHERE a.account_code = 'WALLET-PROJECTION-RECOVERY-TEST';
  SELECT count(*), COALESCE(sum(le.amount), 0) INTO v_entry_count, v_entry_amount
    FROM ledger.ledger_entries AS le
    JOIN ledger.accounts AS a USING (account_id)
   WHERE a.account_code = 'WALLET-PROJECTION-RECOVERY-TEST';
  SELECT count(*) INTO v_finding_count FROM ledger.audit_integrity();
  IF v_balance <> 5.00 OR v_entry_count <> 1 OR v_entry_amount <> 5.00 THEN
    RAISE EXCEPTION 'projection repair changed history or restored the wrong balance: %, %, %',
      v_balance, v_entry_count, v_entry_amount;
  END IF;
  IF v_finding_count <> 0 THEN
    RAISE EXCEPTION 'audit findings remain after missing projection repair: %',
      v_finding_count;
  END IF;
  RAISE NOTICE 'account projection creation, missing-row detection, repair, and reversal audit: passed';
END
$test$;

RESET ROLE;
SET LOCAL ROLE ledgerx_owner;
DO $test$
DECLARE
  v_original_id bigint;
  v_reversal_id bigint;
  v_finding_count bigint;
BEGIN
  SELECT transaction_id INTO v_original_id
    FROM ledger.idempotency_keys
   WHERE scope = 'integrity-test' AND idempotency_key = 'projection-recovery-deposit';

  BEGIN
    SET CONSTRAINTS ALL DEFERRED;
    INSERT INTO ledger.transactions (
      transaction_ref, transaction_type, amount, currency_code,
      source_account_id, destination_account_id, reversal_of_transaction_id
    )
    SELECT 'TEST-BALANCED-WRONG-REVERSAL', 'reversal', original.amount,
           original.currency_code, original.destination_account_id,
           original.source_account_id, original.transaction_id
      FROM ledger.transactions AS original
     WHERE original.transaction_id = v_original_id
    RETURNING transaction_id INTO v_reversal_id;

    INSERT INTO ledger.ledger_entries (
      transaction_id, account_id, entry_side, amount, currency_code
    )
    SELECT v_reversal_id, a.account_id, v.entry_side, 5.00, 'USD'
      FROM (VALUES ('SYS-FUND-INTEGRITY-USD', 'credit'),
                   ('SYS-PAYOUT-USD', 'debit')) AS v(account_code, entry_side)
      JOIN ledger.accounts AS a USING (account_code);

    UPDATE ledger.transactions SET status = 'posted', posted_at = transaction_timestamp()
     WHERE transaction_id = v_reversal_id;
    UPDATE ledger.transactions SET status = 'reversed'
     WHERE transaction_id = v_original_id;
    SET CONSTRAINTS ALL IMMEDIATE;

    SELECT count(*) INTO v_finding_count FROM ledger.audit_integrity()
     WHERE finding_type = 'reversal_journal_mismatch'
       AND entity_id = v_reversal_id::text;
    IF v_finding_count = 0 THEN
      RAISE EXCEPTION 'auditor missed balanced but incorrectly composed reversal';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001',
      MESSAGE = 'rollback test-only malformed reversal';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    NULL;
  END;
END
$test$;

ROLLBACK;
