\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE ledgerx_runtime;

SELECT ledger.deposit(
  'tests', 'deposit-001',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  125.00, 'USD', 'test-deposit'
) AS txid \gset deposit_

SELECT ledger.deposit(
  'tests', 'deposit-001',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  125.00, 'USD', 'test-deposit'
) AS txid \gset deposit_retry_

SELECT (:'deposit_txid'::bigint = :'deposit_retry_txid'::bigint) AS retry_same
\gset
\if :retry_same
  \echo Idempotent retry returned the original transaction.
\else
  \echo Idempotent retry returned a different transaction.
  SELECT 1 / 0;
\endif

SELECT ledger.withdraw(
  'tests', 'withdraw-001',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-PAYOUT-FINANCIAL-USD'),
  25.00, 'USD', 'test-withdrawal'
) AS txid \gset withdrawal_

SELECT ledger.transfer(
  'tests', 'transfer-001',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-RECIPIENT-USD'),
  20.00, 'USD', 'test-transfer'
) AS txid \gset transfer_

SELECT ledger.capture(
  'tests', 'capture-001',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-FINANCIAL-USD'),
  30.00, 'USD', 'test-capture-partial-refund'
) AS txid \gset capture_refunded_

SELECT ledger.refund_capture('tests', 'refund-001', :capture_refunded_txid, 12.25)
  AS txid \gset refund_partial_
SELECT ledger.refund_capture('tests', 'refund-002', :capture_refunded_txid, 17.75)
  AS txid \gset refund_remainder_

SELECT ledger.capture(
  'tests', 'capture-refund-reversal',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-FINANCIAL-USD'),
  40.00, 'USD', 'test-refund-reversal'
) AS txid \gset capture_refund_reversal_
SELECT ledger.refund_capture(
  'tests', 'refund-reversible-001', :capture_refund_reversal_txid, 10.00
) AS txid \gset refund_reversible_
SELECT ledger.reverse_transaction(
  'tests', 'reverse-refund-001', :refund_reversible_txid
) AS txid \gset reversal_refund_
SELECT ledger.refund_capture(
  'tests', 'refund-after-reversal-001', :capture_refund_reversal_txid, 25.00
) AS txid \gset refund_after_reversal_
SELECT ledger.refund_capture(
  'tests', 'refund-final-001', :capture_refund_reversal_txid, 15.00
) AS txid \gset refund_final_

SELECT ledger.capture(
  'tests', 'capture-reverse-after-refund-reversal',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-FINANCIAL-USD'),
  8.00, 'USD', 'test-reverse-after-refund-reversal'
) AS txid \gset capture_reverse_after_refund_
SELECT ledger.refund_capture(
  'tests', 'refund-before-capture-reversal', :capture_reverse_after_refund_txid, 3.00
) AS txid \gset refund_before_capture_reversal_
SELECT ledger.reverse_transaction(
  'tests', 'reverse-refund-before-capture', :refund_before_capture_reversal_txid
) AS txid \gset reversal_refund_before_capture_
SELECT ledger.reverse_transaction(
  'tests', 'reverse-capture-after-refund-reversal', :capture_reverse_after_refund_txid
) AS txid \gset reversal_capture_after_refund_

SELECT ledger.capture(
  'tests', 'capture-002',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-FINANCIAL-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-FINANCIAL-USD'),
  5.00, 'USD', 'test-capture-reversal'
) AS txid \gset capture_reversed_
SELECT ledger.reverse_transaction('tests', 'reverse-001', :capture_reversed_txid)
  AS txid \gset reversal_

DO $test$
DECLARE
  v_wallet_id bigint;
  v_other_wallet_id bigint;
  v_payout_id bigint;
  v_merchant_id bigint;
  v_refunded_capture_id bigint;
  v_transfer_id bigint;
  v_reversed_capture_id bigint;
  v_refund_to_reverse_id bigint;
  v_refund_reversal_id bigint;
  v_refund_reversal_capture_id bigint;
  v_capture_after_refund_id bigint;
  v_active_refund_total numeric(20,4);
  v_remaining_refundable numeric(20,4);
  v_historical_refund_count bigint;
  v_reversed_refund_count bigint;
  v_balance numeric(20,4);
  v_count bigint;
BEGIN
  SELECT account_id INTO v_wallet_id FROM ledger.accounts
   WHERE account_code = 'WALLET-FINANCIAL-USD';
  SELECT account_id INTO v_other_wallet_id FROM ledger.accounts
   WHERE account_code = 'WALLET-FINANCIAL-RECIPIENT-USD';
  SELECT account_id INTO v_payout_id FROM ledger.accounts
   WHERE account_code = 'SYS-PAYOUT-FINANCIAL-USD';
  SELECT account_id INTO v_merchant_id FROM ledger.accounts
   WHERE account_code = 'MERCHANT-FINANCIAL-USD';
  SELECT transaction_id INTO v_refunded_capture_id FROM ledger.idempotency_keys
   WHERE scope = 'tests' AND idempotency_key = 'capture-001';
  SELECT transaction_id INTO v_transfer_id FROM ledger.idempotency_keys
   WHERE scope = 'tests' AND idempotency_key = 'transfer-001';
  SELECT transaction_id INTO v_reversed_capture_id FROM ledger.idempotency_keys
   WHERE scope = 'tests' AND idempotency_key = 'capture-002';
  SELECT transaction_id INTO v_refund_to_reverse_id FROM ledger.idempotency_keys
   WHERE scope = 'tests' AND idempotency_key = 'refund-reversible-001';
  SELECT transaction_id INTO v_refund_reversal_id FROM ledger.idempotency_keys
   WHERE scope = 'tests' AND idempotency_key = 'reverse-refund-001';
  SELECT transaction_id INTO v_refund_reversal_capture_id
    FROM ledger.idempotency_keys
   WHERE scope = 'tests' AND idempotency_key = 'capture-refund-reversal';
  SELECT transaction_id INTO v_capture_after_refund_id
    FROM ledger.idempotency_keys
   WHERE scope = 'tests' AND idempotency_key = 'capture-reverse-after-refund-reversal';

  BEGIN
    PERFORM ledger.deposit(
      'tests', 'deposit-001',
      (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-FINANCIAL-USD'),
      v_wallet_id, 126.00, 'USD', 'test-deposit'
    );
    RAISE EXCEPTION 'same key with a different amount was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.withdraw('tests', 'too-much', v_wallet_id, v_payout_id,
                            1000.00, 'USD', NULL);
    RAISE EXCEPTION 'insufficient balance withdrawal was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.transfer('tests', 'self-transfer', v_wallet_id, v_wallet_id,
                            1.00, 'USD', NULL);
    RAISE EXCEPTION 'self-transfer was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.transfer(
      'tests', 'currency-mismatch', v_wallet_id,
      (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-JPY'),
      1.00, 'USD', NULL
    );
    RAISE EXCEPTION 'cross-currency transfer was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.withdraw(
      'tests', 'excess-scale', v_wallet_id, v_payout_id, 1.001, 'USD', NULL
    );
    RAISE EXCEPTION 'excess currency precision was accepted';
  EXCEPTION WHEN numeric_value_out_of_range THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.deposit(
      'tests', 'frozen-account',
      (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-FINANCIAL-USD'),
      (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1003-FROZEN-USD'),
      1.00, 'USD', NULL
    );
    RAISE EXCEPTION 'deposit into frozen account was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.refund_capture('tests', 'refund-over-limit',
                                  v_refunded_capture_id, 0.01);
    RAISE EXCEPTION 'refund above capture total was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.refund_capture('tests', 'refund-transfer', v_transfer_id, 1.00);
    RAISE EXCEPTION 'non-capture refund was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.reverse_transaction('tests', 'reverse-refunded',
                                       v_refunded_capture_id);
    RAISE EXCEPTION 'capture with refunds was reversed';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.reverse_transaction('tests', 'reverse-twice',
                                       v_reversed_capture_id);
    RAISE EXCEPTION 'duplicate reversal was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.reverse_transaction('tests', 'reverse-refund-twice',
                                       v_refund_to_reverse_id);
    RAISE EXCEPTION 'duplicate refund reversal was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM ledger.reverse_transaction('tests', 'reverse-refund-reversal',
                                       v_refund_reversal_id);
    RAISE EXCEPTION 'reversing a reversal was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  SELECT COALESCE(sum(r.amount), 0) INTO v_active_refund_total
    FROM ledger.refunds AS r
    JOIN ledger.transactions AS refund_tx
      ON refund_tx.transaction_id = r.refund_transaction_id
   WHERE r.original_transaction_id = v_refund_reversal_capture_id
     AND refund_tx.status = 'posted';
  IF v_active_refund_total <> 40.00 THEN
    RAISE EXCEPTION 'active refund amount after retry/full refund expected 40, got %',
      v_active_refund_total;
  END IF;

  IF (SELECT status FROM ledger.transactions
       WHERE transaction_id = v_refund_to_reverse_id) <> 'reversed' THEN
    RAISE EXCEPTION 'partial refund reversal did not retain reversed transaction history';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ledger.refunds
     WHERE refund_transaction_id = v_refund_to_reverse_id
  ) THEN
    RAISE EXCEPTION 'reversed refund history row was removed';
  END IF;
  SELECT remaining_refundable_amount, historical_refund_count,
         reversed_refund_count
    INTO v_remaining_refundable, v_historical_refund_count, v_reversed_refund_count
    FROM ledger.v_refund_analysis
   WHERE capture_transaction_id = v_refund_reversal_capture_id;
  IF v_remaining_refundable <> 0 OR v_historical_refund_count <> 3
     OR v_reversed_refund_count <> 1 THEN
    RAISE EXCEPTION 'full-refund history view mismatch: remaining %, history %, reversed %',
      v_remaining_refundable, v_historical_refund_count, v_reversed_refund_count;
  END IF;

  SELECT b.posted_balance INTO v_balance FROM ledger.account_balances AS b
   WHERE b.account_id = v_wallet_id;
  IF v_balance <> 80.00 THEN
    RAISE EXCEPTION 'wallet balance expected 80.00 after compensations, got %', v_balance;
  END IF;
  SELECT b.posted_balance INTO v_balance FROM ledger.account_balances AS b
   WHERE b.account_id = v_other_wallet_id;
  IF v_balance <> 20.00 THEN
    RAISE EXCEPTION 'recipient balance expected 20.00, got %', v_balance;
  END IF;
  SELECT b.posted_balance INTO v_balance FROM ledger.account_balances AS b
   WHERE b.account_id = v_merchant_id;
  IF v_balance <> 0.00 THEN
    RAISE EXCEPTION 'merchant balance expected 0.00, got %', v_balance;
  END IF;
  SELECT b.posted_balance INTO v_balance FROM ledger.account_balances AS b
   WHERE b.account_id = v_payout_id;
  IF v_balance <> -25.00 THEN
    RAISE EXCEPTION 'payout clearing net asset expected -25.00, got %', v_balance;
  END IF;

  SELECT count(*) INTO v_count FROM ledger.transactions
   WHERE transaction_ref = (
     SELECT t.transaction_ref FROM ledger.transactions AS t
     WHERE t.transaction_id = v_reversed_capture_id AND t.status = 'reversed'
   );
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'full reversal did not mark its original capture reversed';
  END IF;

  SELECT count(*) INTO v_count FROM ledger.transactions
   WHERE transaction_id = v_capture_after_refund_id AND status = 'reversed';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'capture with only historical reversed refund was not reversible';
  END IF;

  SELECT count(*) INTO v_count FROM ledger.audit_integrity();
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'integrity auditor found % issues after refund/reversal workflow', v_count;
  END IF;

  BEGIN
    INSERT INTO ledger.ledger_entries (
      transaction_id, account_id, entry_side, amount, currency_code
    ) VALUES (
      (SELECT transaction_id FROM ledger.idempotency_keys
        WHERE scope = 'tests' AND idempotency_key = 'deposit-001'),
      v_wallet_id, 'credit', 1.00, 'USD'
    );
    RAISE EXCEPTION 'runtime role inserted a ledger entry directly';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    UPDATE ledger.account_balances SET posted_balance = 999
     WHERE account_id = v_wallet_id;
    RAISE EXCEPTION 'runtime role changed the balance projection directly';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    INSERT INTO ledger.idempotency_keys (scope, idempotency_key, payload_hash)
    VALUES ('tests', 'privilege-bypass', repeat('a', 64));
    RAISE EXCEPTION 'runtime role wrote idempotency records directly';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  RAISE NOTICE 'financial operations, rollback, idempotency, and runtime privileges: passed';
END
$test$;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
