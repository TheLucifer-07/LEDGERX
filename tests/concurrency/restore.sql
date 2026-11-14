BEGIN;
SET LOCAL ROLE ledgerx_runtime;

SELECT EXISTS (
  SELECT 1 FROM ledger.idempotency_keys
   WHERE scope = :'run_scope' AND idempotency_key = 'same-key-transfer'
) AS has_transfer \gset restore_
\if :restore_has_transfer
SELECT ledger.transfer(
  :'run_scope', 'restore-transfer-balances',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1002-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  10.00, 'USD', 'restore-same-key-transfer'
);
\endif

SELECT EXISTS (
  SELECT 1 FROM ledger.idempotency_keys
   WHERE scope = :'run_scope' AND idempotency_key = 'capture-100'
) AS has_capture \gset refund_restore_
\if :refund_restore_has_capture
SELECT t.amount - COALESCE(
         sum(r.amount) FILTER (WHERE refund_tx.status = 'posted'), 0
       ) AS remaining_amount,
       t.amount - COALESCE(
         sum(r.amount) FILTER (WHERE refund_tx.status = 'posted'), 0
       ) > 0 AS has_remainder
  FROM ledger.transactions AS t
  LEFT JOIN ledger.refunds AS r ON r.original_transaction_id = t.transaction_id
  LEFT JOIN ledger.transactions AS refund_tx
    ON refund_tx.transaction_id = r.refund_transaction_id
 WHERE t.transaction_id = (
   SELECT transaction_id FROM ledger.idempotency_keys
    WHERE scope = :'run_scope' AND idempotency_key = 'capture-100'
 )
 GROUP BY t.amount \gset refund_restore_
\if :refund_restore_has_remainder
SELECT ledger.refund_capture(
  :'run_scope', 'refund-remainder',
  (SELECT ik.transaction_id FROM ledger.idempotency_keys AS ik
    WHERE ik.scope = :'run_scope' AND ik.idempotency_key = 'capture-100'),
  :'refund_restore_remaining_amount'::numeric
);
\endif
\endif
COMMIT;
