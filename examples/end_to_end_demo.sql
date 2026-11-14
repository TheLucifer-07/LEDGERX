\set ON_ERROR_STOP on

-- Run only against a disposable LedgerX database. Every write below is rolled
-- back at the end, so this walkthrough never edits committed financial history.
BEGIN;
SET LOCAL ROLE ledgerx_runtime;

-- Fund a fictional customer wallet and transfer value to another wallet.
SELECT ledger.deposit(
  'end-to-end-demo', 'fund-wallet',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-DEMO-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-DEMO-USD'),
  250.00, 'USD', 'demo-wallet-funding'
) AS transaction_id \gset demo_funding_

SELECT ledger.transfer(
  'end-to-end-demo', 'wallet-transfer',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-DEMO-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-DEMO-RECIPIENT-USD'),
  60.00, 'USD', 'demo-wallet-transfer'
) AS transaction_id \gset demo_transfer_

-- Capture a merchant payment and issue a partial refund.
SELECT ledger.capture(
  'end-to-end-demo', 'merchant-capture',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-DEMO-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-DEMO-USD'),
  100.00, 'USD', 'demo-primary-capture'
) AS transaction_id \gset demo_capture_
SELECT transaction_ref AS transaction_ref
  FROM ledger.transactions WHERE transaction_id = :demo_capture_transaction_id
  \gset demo_capture_

SELECT ledger.refund_capture(
  'end-to-end-demo', 'partial-refund', :demo_capture_transaction_id, 20.00
) AS transaction_id \gset demo_refund_
SELECT transaction_ref AS transaction_ref
  FROM ledger.transactions WHERE transaction_id = :demo_refund_transaction_id
  \gset demo_refund_

-- A second capture shows a refund reversal followed by a new partial refund.
SELECT ledger.capture(
  'end-to-end-demo', 'second-capture',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-DEMO-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-DEMO-USD'),
  25.00, 'USD', 'demo-refund-reversal-capture'
) AS transaction_id \gset demo_second_capture_
SELECT ledger.refund_capture(
  'end-to-end-demo', 'refund-to-reverse', :demo_second_capture_transaction_id, 5.00
) AS transaction_id \gset demo_reversed_refund_
SELECT ledger.reverse_transaction(
  'end-to-end-demo', 'reverse-partial-refund', :demo_reversed_refund_transaction_id
) AS transaction_id \gset demo_refund_reversal_
SELECT ledger.refund_capture(
  'end-to-end-demo', 'refund-after-reversal', :demo_second_capture_transaction_id, 5.00
) AS transaction_id \gset demo_second_refund_
SELECT transaction_ref AS transaction_ref
  FROM ledger.transactions WHERE transaction_id = :demo_second_capture_transaction_id
  \gset demo_second_capture_
SELECT transaction_ref AS transaction_ref
  FROM ledger.transactions WHERE transaction_id = :demo_second_refund_transaction_id
  \gset demo_second_refund_

-- Import independent external statement evidence and reconcile one-to-one.
SELECT ledger.create_settlement_batch(
  'DEMO-SETTLEMENT-001', 'fictional-demo-acquirer', current_date,
  transaction_timestamp() - interval '1 minute',
  transaction_timestamp() + interval '1 day', 'USD'
) AS batch_id \gset demo_batch_
SELECT ledger.import_settlement_item(
  :demo_batch_batch_id, 'EXT-DEMO-CAPTURE-100', 100.00, 'capture', 'USD',
  transaction_timestamp(), :'demo_capture_transaction_ref'
);
SELECT ledger.import_settlement_item(
  :demo_batch_batch_id, 'EXT-DEMO-REFUND-20', 20.00, 'refund', 'USD',
  transaction_timestamp(), :'demo_refund_transaction_ref'
);
SELECT ledger.import_settlement_item(
  :demo_batch_batch_id, 'EXT-DEMO-CAPTURE-25', 25.00, 'capture', 'USD',
  transaction_timestamp(), :'demo_second_capture_transaction_ref'
);
SELECT ledger.import_settlement_item(
  :demo_batch_batch_id, 'EXT-DEMO-REFUND-5', 5.00, 'refund', 'USD',
  transaction_timestamp(), :'demo_second_refund_transaction_ref'
);
SELECT ledger.complete_settlement_import(:demo_batch_batch_id);
SELECT ledger.reconcile_settlement_batch(:demo_batch_batch_id) AS run_id;
SELECT ledger.close_settlement_batch(:demo_batch_batch_id);
SET CONSTRAINTS ALL IMMEDIATE;

-- Show the reconciliation result, refund history, clean integrity audit,
-- per-account activity, and final normal-side projections.
SELECT result_type, count(*) AS result_count
  FROM ledger.reconciliation_results AS result
  JOIN ledger.reconciliation_runs AS run
    ON run.reconciliation_run_id = result.reconciliation_run_id
 WHERE run.settlement_batch_id = :demo_batch_batch_id
 GROUP BY result_type
 ORDER BY result_type;

SELECT capture_reference, refund_reference, refund_status, amount,
       reversal_reference
  FROM ledger.v_refund_history
 WHERE capture_transaction_id IN (
   :demo_capture_transaction_id, :demo_second_capture_transaction_id
 )
 ORDER BY refund_id;

SELECT finding_type, entity_type, entity_id, details
  FROM ledger.audit_integrity()
 ORDER BY finding_type, entity_id;
SELECT NOT EXISTS (SELECT 1 FROM ledger.audit_integrity()) AS integrity_clean;

SELECT activity.account_code, activity.transaction_type,
       activity.transaction_status, activity.entry_side, activity.amount,
       activity.normalized_delta, activity.running_normal_balance
  FROM ledger.v_account_activity AS activity
 WHERE activity.account_code IN (
   'WALLET-DEMO-USD', 'WALLET-DEMO-RECIPIENT-USD', 'MERCHANT-DEMO-USD'
 )
 ORDER BY activity.account_code, activity.posted_at, activity.ledger_entry_id;

SELECT a.account_code, a.currency_code, a.normal_side, b.posted_balance
  FROM ledger.accounts AS a
  JOIN ledger.account_balances AS b USING (account_id)
 WHERE a.account_code IN (
   'WALLET-DEMO-USD', 'WALLET-DEMO-RECIPIENT-USD', 'MERCHANT-DEMO-USD'
 )
 ORDER BY a.account_code;

ROLLBACK;
\echo 'Demo complete. All demo writes were rolled back.'
