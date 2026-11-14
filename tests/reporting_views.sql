\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE ledgerx_runtime;

SELECT ledger.deposit(
  'report-tests', 'fund-wallet',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-REPORTS-USD'),
  100.00, 'USD', 'report-fixture'
);
SELECT ledger.capture(
  'report-tests', 'capture',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-REPORTS-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  40.00, 'USD', 'report-capture'
) AS txid \gset report_capture_
SELECT transaction_ref AS txn_ref FROM ledger.transactions
 WHERE transaction_id = :report_capture_txid \gset report_capture_
SELECT ledger.transfer(
  'report-tests', 'transfer',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-REPORTS-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1002-USD'),
  10.00, 'USD', 'report-transfer'
);
SELECT ledger.refund_capture('report-tests', 'refund', :report_capture_txid, 5.00)
  AS txid \gset report_refund_
SELECT transaction_ref AS txn_ref FROM ledger.transactions
 WHERE transaction_id = :report_refund_txid \gset report_refund_

SELECT ledger.create_settlement_batch(
  'SETTLEMENT-REPORT-TEST', 'fictional-acquirer', current_date,
  transaction_timestamp(), transaction_timestamp() + interval '1 hour', 'USD'
) AS batch_id \gset report_batch_
SELECT ledger.import_settlement_item(
  :report_batch_batch_id, 'EXT-REPORT', 40.00, 'capture', 'USD',
  transaction_timestamp(), :'report_capture_txn_ref'
);
SELECT ledger.import_settlement_item(
  :report_batch_batch_id, 'EXT-REPORT-REFUND', 5.00, 'refund', 'USD',
  transaction_timestamp(), :'report_refund_txn_ref'
);
SELECT ledger.complete_settlement_import(:report_batch_batch_id);
SELECT ledger.reconcile_settlement_batch(:report_batch_batch_id);
SELECT ledger.close_settlement_batch(:report_batch_batch_id);

SELECT ledger.deposit(
  'report-tests', 'fund-refund-history-wallet',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  5.00, 'USD', 'reversed-refund-history-fixture'
);
SELECT ledger.capture(
  'report-tests', 'capture-with-reversed-refund',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  4.00, 'USD', 'reversed-refund-capture'
) AS txid \gset reversed_refund_capture_
SELECT ledger.refund_capture(
  'report-tests', 'refund-to-reverse', :reversed_refund_capture_txid, 1.00
) AS txid \gset reversed_refund_
SELECT ledger.reverse_transaction(
  'report-tests', 'reverse-report-refund', :reversed_refund_txid
);

SELECT ledger.capture(
  'report-tests', 'unsettled-capture',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-REPORTS-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  1.00, 'USD', 'report-unsettled'
);

SET CONSTRAINTS ALL IMMEDIATE;

DO $test$
DECLARE
  v_account_id bigint;
  v_running_balance numeric(20,4);
  v_refunded numeric(20,4);
  v_remaining numeric(20,4);
  v_expected numeric(20,4);
  v_external numeric(20,4);
  v_exceptions bigint;
  v_historical_count bigint;
  v_reversed_count bigint;
  v_active_count bigint;
  v_reversed_refund_id bigint;
  v_reversed_capture_id bigint;
BEGIN
  SELECT transaction_id INTO v_reversed_refund_id
    FROM ledger.idempotency_keys
   WHERE scope = 'report-tests' AND idempotency_key = 'refund-to-reverse';
  SELECT transaction_id INTO v_reversed_capture_id
    FROM ledger.idempotency_keys
   WHERE scope = 'report-tests' AND idempotency_key = 'capture-with-reversed-refund';
  SELECT account_id INTO v_account_id FROM ledger.accounts
   WHERE account_code = 'WALLET-REPORTS-USD';
  SELECT running_normal_balance INTO v_running_balance
    FROM ledger.v_account_activity
   WHERE account_id = v_account_id
   ORDER BY posted_at DESC, ledger_entry_id DESC LIMIT 1;
  IF v_running_balance <> 54.00 THEN
    RAISE EXCEPTION 'running account balance expected 54.00, got %', v_running_balance;
  END IF;

  SELECT refunded_amount, remaining_refundable_amount
    INTO v_refunded, v_remaining
    FROM ledger.v_refund_analysis
   WHERE capture_reference = (
     SELECT transaction_ref FROM ledger.transactions
      WHERE request_reference = 'report-capture'
   );
  IF v_refunded <> 5.00 OR v_remaining <> 35.00 THEN
    RAISE EXCEPTION 'refund report mismatch: refunded %, remaining %',
      v_refunded, v_remaining;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM ledger.v_refund_history
     WHERE refund_transaction_id = v_reversed_refund_id
       AND refund_status = 'reversed'
       AND reversal_transaction_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'refund history view omitted its valid compensating reversal';
  END IF;
  SELECT refund_count, refunded_amount, remaining_refundable_amount,
         historical_refund_count, reversed_refund_count
    INTO v_active_count, v_refunded, v_remaining, v_historical_count, v_reversed_count
    FROM ledger.v_refund_analysis
   WHERE capture_transaction_id = v_reversed_capture_id;
  IF v_active_count <> 0 OR v_refunded <> 0 OR v_remaining <> 4.00
     OR v_historical_count <> 1 OR v_reversed_count <> 1 THEN
    RAISE EXCEPTION 'active/history refund reporting mismatch: %, %, %, %, %',
      v_active_count, v_refunded, v_remaining, v_historical_count, v_reversed_count;
  END IF;

  SELECT expected_gross_total, external_gross_total, exception_count
    INTO v_expected, v_external, v_exceptions
    FROM ledger.v_settlement_batch_summary
   WHERE external_batch_ref = 'SETTLEMENT-REPORT-TEST';
  IF v_expected <> 45.00 OR v_external <> 45.00 OR v_exceptions <> 0 THEN
    RAISE EXCEPTION 'settlement summary mismatch: expected %, external %, exceptions %',
      v_expected, v_external, v_exceptions;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ledger.v_daily_transaction_volume
     WHERE currency_code = 'USD' AND transaction_date = current_date
  ) OR NOT EXISTS (
    SELECT 1 FROM ledger.v_monthly_transaction_rank
     WHERE currency_code = 'USD'
       AND month_start = date_trunc('month', current_timestamp AT TIME ZONE 'UTC')::date
  ) THEN
    RAISE EXCEPTION 'date summary or ranking view returned no current-period rows';
  END IF;
  IF EXISTS (
    SELECT 1 FROM ledger.v_reconciliation_exceptions
     WHERE external_batch_ref = 'SETTLEMENT-REPORT-TEST'
  ) THEN
    RAISE EXCEPTION 'clean report fixture produced reconciliation exceptions';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ledger.v_unsettled_transactions
     WHERE transaction_ref = (
       SELECT transaction_ref FROM ledger.transactions
        WHERE request_reference = 'report-unsettled'
     )
  ) THEN
    RAISE EXCEPTION 'unsettled transaction report omitted the unlinked capture';
  END IF;
  RAISE NOTICE 'financial reporting views and running balances: passed';
END
$test$;

ROLLBACK;
