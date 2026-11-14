BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.transfer(
  :'run_scope', 'restore-transfer-balances',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1002-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  10.00, 'USD', 'restore-same-key-transfer'
);
SELECT ledger.refund_capture(
  :'run_scope', 'refund-remainder',
  (SELECT ik.transaction_id FROM ledger.idempotency_keys AS ik
    WHERE ik.scope = :'run_scope' AND ik.idempotency_key = 'capture-100'),
  (
    SELECT t.amount - COALESCE(sum(r.amount), 0)
      FROM ledger.transactions AS t
      LEFT JOIN ledger.refunds AS r
        ON r.original_transaction_id = t.transaction_id
     WHERE t.transaction_id = (
       SELECT ik.transaction_id FROM ledger.idempotency_keys AS ik
        WHERE ik.scope = :'run_scope' AND ik.idempotency_key = 'capture-100'
     )
     GROUP BY t.transaction_id, t.amount
  )
);
COMMIT;
