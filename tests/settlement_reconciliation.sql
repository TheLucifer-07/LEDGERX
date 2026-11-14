\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE ledgerx_runtime;

SELECT ledger.deposit(
  'settlement-tests', 'fund-usd',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  100.00, 'USD', 'settlement-test-funding'
);
SELECT ledger.deposit(
  'settlement-tests', 'fund-jpy',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-JPY'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-JPY'),
  1000, 'JPY', 'settlement-test-funding'
);

SELECT ledger.capture(
  'settlement-tests', 'capture-good',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  40.00, 'USD', 'settlement-good'
) AS txid \gset capture_good_
SELECT transaction_ref AS ref FROM ledger.transactions
 WHERE transaction_id = :capture_good_txid \gset capture_good_

SELECT ledger.capture(
  'settlement-tests', 'capture-amount-mismatch',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  20.00, 'USD', 'settlement-amount-mismatch'
) AS txid \gset capture_amount_
SELECT transaction_ref AS ref FROM ledger.transactions
 WHERE transaction_id = :capture_amount_txid \gset capture_amount_

SELECT ledger.capture(
  'settlement-tests', 'capture-type-mismatch',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  7.00, 'USD', 'settlement-type-mismatch'
) AS txid \gset capture_type_
SELECT transaction_ref AS ref FROM ledger.transactions
 WHERE transaction_id = :capture_type_txid \gset capture_type_

SELECT ledger.capture(
  'settlement-tests', 'capture-missing-external',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  5.00, 'USD', 'settlement-missing-external'
) AS txid \gset capture_unsettled_
SELECT transaction_ref AS ref FROM ledger.transactions
 WHERE transaction_id = :capture_unsettled_txid \gset capture_unsettled_

SELECT ledger.capture(
  'settlement-tests', 'capture-jpy',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-JPY'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-JPY'),
  1000, 'JPY', 'settlement-currency-mismatch'
) AS txid \gset capture_jpy_
SELECT transaction_ref AS ref FROM ledger.transactions
 WHERE transaction_id = :capture_jpy_txid \gset capture_jpy_

SELECT ledger.create_settlement_batch(
  'SETTLEMENT-TEST-USD', 'fictional-acquirer', current_date,
  transaction_timestamp(), transaction_timestamp() + interval '1 hour', 'USD'
) AS batch_id \gset usd_batch_
SELECT ledger.create_settlement_batch(
  'SETTLEMENT-TEST-USD', 'fictional-acquirer', current_date,
  transaction_timestamp(), transaction_timestamp() + interval '1 hour', 'USD'
) AS batch_id \gset usd_batch_retry_
SELECT (:'usd_batch_batch_id'::bigint = :'usd_batch_retry_batch_id'::bigint)
  AS batch_retry_same \gset
\if :batch_retry_same
  \echo Duplicate batch creation returned its original batch.
\else
  \echo Duplicate batch creation returned a different batch.
  \quit 1
\endif

SELECT ledger.import_settlement_item(
  :usd_batch_batch_id, 'EXT-GOOD', 40.00, 'capture', 'USD',
  transaction_timestamp(), :'capture_good_ref'
) AS item_id \gset good_item_
SELECT ledger.import_settlement_item(
  :usd_batch_batch_id, 'EXT-GOOD', 40.00, 'capture', 'USD',
  transaction_timestamp(), :'capture_good_ref'
) AS item_id \gset good_item_retry_
SELECT (:'good_item_item_id'::bigint = :'good_item_retry_item_id'::bigint)
  AS item_retry_same \gset
\if :item_retry_same
  \echo Duplicate statement import returned its original row.
\else
  \echo Duplicate statement import returned a different row.
  \quit 1
\endif

SELECT ledger.import_settlement_item(
  :usd_batch_batch_id, 'EXT-AMOUNT', 19.00, 'capture', 'USD',
  transaction_timestamp(), :'capture_amount_ref'
);
SELECT ledger.import_settlement_item(
  :usd_batch_batch_id, 'EXT-TYPE', 7.00, 'refund', 'USD',
  transaction_timestamp(), :'capture_type_ref'
);
SELECT ledger.import_settlement_item(
  :usd_batch_batch_id, 'EXT-CURRENCY', 1000, 'capture', 'USD',
  transaction_timestamp(), :'capture_jpy_ref'
);
SELECT ledger.import_settlement_item(
  :usd_batch_batch_id, 'EXT-MISSING-INTERNAL', 8.00, 'capture', 'USD',
  transaction_timestamp(), 'txn_missing_external_reference'
);
SELECT ledger.import_settlement_item(
  :usd_batch_batch_id, 'EXT-DUPLICATE-REFERENCE', 40.00, 'capture', 'USD',
  transaction_timestamp(), :'capture_good_ref'
);

DO $test$
BEGIN
  BEGIN
    PERFORM ledger.import_settlement_item(
      (SELECT settlement_batch_id FROM ledger.settlement_batches
        WHERE external_batch_ref = 'SETTLEMENT-TEST-USD'),
      'EXT-GOOD', 41.00, 'capture', 'USD', transaction_timestamp(),
      (SELECT internal_reference FROM ledger.settlement_items
        WHERE external_ref = 'EXT-GOOD')
    );
    RAISE EXCEPTION 'statement reference payload reuse was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END
$test$;

SELECT ledger.complete_settlement_import(:usd_batch_batch_id);
SELECT ledger.reconcile_settlement_batch(:usd_batch_batch_id) AS run_id \gset usd_run1_
SELECT ledger.reconcile_settlement_batch(:usd_batch_batch_id) AS run_id \gset usd_run2_

SET LOCAL ROLE ledgerx_owner;
DO $test$
DECLARE
  v_run1 bigint;
  v_run2 bigint;
  v_matched bigint;
  v_amount_mismatch bigint;
  v_currency_mismatch bigint;
  v_type_mismatch bigint;
  v_missing_internal bigint;
  v_missing_external bigint;
  v_result_count bigint;
BEGIN
  SELECT reconciliation_run_id INTO v_run1 FROM ledger.reconciliation_runs
   WHERE settlement_batch_id = (
     SELECT settlement_batch_id FROM ledger.settlement_batches
      WHERE external_batch_ref = 'SETTLEMENT-TEST-USD'
   ) AND run_number = 1;
  SELECT reconciliation_run_id INTO v_run2 FROM ledger.reconciliation_runs
   WHERE settlement_batch_id = (
     SELECT settlement_batch_id FROM ledger.settlement_batches
      WHERE external_batch_ref = 'SETTLEMENT-TEST-USD'
   ) AND run_number = 2;
  SELECT count(*) INTO v_matched FROM ledger.reconciliation_results
   WHERE reconciliation_run_id = v_run1 AND result_type = 'matched';
  SELECT count(*) INTO v_amount_mismatch FROM ledger.reconciliation_results
   WHERE reconciliation_run_id = v_run1 AND result_type = 'amount_mismatch';
  SELECT count(*) INTO v_currency_mismatch FROM ledger.reconciliation_results
   WHERE reconciliation_run_id = v_run1 AND result_type = 'currency_mismatch';
  SELECT count(*) INTO v_type_mismatch FROM ledger.reconciliation_results
   WHERE reconciliation_run_id = v_run1 AND result_type = 'transaction_type_mismatch';
  SELECT count(*) INTO v_missing_internal FROM ledger.reconciliation_results
   WHERE reconciliation_run_id = v_run1 AND result_type = 'missing_internal';
  SELECT count(*) INTO v_missing_external FROM ledger.reconciliation_results
   WHERE reconciliation_run_id = v_run1 AND result_type = 'missing_external';
  SELECT count(*) INTO v_result_count FROM ledger.reconciliation_results
   WHERE reconciliation_run_id = v_run1;
  IF (v_matched, v_amount_mismatch, v_currency_mismatch, v_type_mismatch,
      v_missing_internal, v_missing_external) IS DISTINCT FROM (1, 1, 1, 1, 2, 1) THEN
    RAISE EXCEPTION 'unexpected reconciliation counts: matched %, amount %, currency %, type %, missing internal %, missing external %',
      v_matched, v_amount_mismatch, v_currency_mismatch, v_type_mismatch,
      v_missing_internal, v_missing_external;
  END IF;
  IF (SELECT count(*) FROM ledger.reconciliation_results
       WHERE reconciliation_run_id = v_run2) <> v_result_count THEN
    RAISE EXCEPTION 'versioned reconciliation did not preserve the same classification count';
  END IF;

  BEGIN
    PERFORM ledger.close_settlement_batch(
      (SELECT settlement_batch_id FROM ledger.settlement_batches
        WHERE external_batch_ref = 'SETTLEMENT-TEST-USD')
    );
    RAISE EXCEPTION 'batch with exceptions was closed';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO ledger.settlement_matches (settlement_item_id, transaction_id)
    SELECT si.settlement_item_id, t.transaction_id
      FROM ledger.settlement_items AS si
      JOIN ledger.transactions AS t ON t.transaction_ref = si.internal_reference
     WHERE si.external_ref = 'EXT-GOOD';
    RAISE EXCEPTION 'duplicate one-to-one settlement match was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END
$test$;

SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.create_settlement_batch(
  'SETTLEMENT-TEST-CLEAN', 'fictional-acquirer', current_date,
  transaction_timestamp(), transaction_timestamp() + interval '1 hour', 'USD'
) AS batch_id \gset clean_batch_
SELECT ledger.import_settlement_item(
  :clean_batch_batch_id, 'EXT-CLEAN', 5.00, 'capture', 'USD',
  transaction_timestamp(), :'capture_unsettled_ref'
);
SELECT ledger.complete_settlement_import(:clean_batch_batch_id);
SELECT ledger.reconcile_settlement_batch(:clean_batch_batch_id);
SELECT ledger.close_settlement_batch(:clean_batch_batch_id);

DO $test$
BEGIN
  BEGIN
    PERFORM ledger.import_settlement_item(
      (SELECT settlement_batch_id FROM ledger.settlement_batches
        WHERE external_batch_ref = 'SETTLEMENT-TEST-CLEAN'),
      'EXT-AFTER-CLOSE', 1.00, 'capture', 'USD', transaction_timestamp(), NULL
    );
    RAISE EXCEPTION 'statement row was imported after batch close';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  RAISE NOTICE 'settlement import, one-to-one matching, versioned reconciliation, and close safeguards: passed';
END
$test$;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
