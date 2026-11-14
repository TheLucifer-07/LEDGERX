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

ROLLBACK;
