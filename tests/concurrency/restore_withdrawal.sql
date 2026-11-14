BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT COALESCE(sum(t.amount), 0) AS amount,
       COALESCE(sum(t.amount), 0) > 0 AS has_withdrawal
  FROM ledger.idempotency_keys AS ik
  JOIN ledger.transactions AS t USING (transaction_id)
 WHERE ik.scope = :'run_scope'
   AND ik.idempotency_key IN ('withdraw-a', 'withdraw-b')
   AND t.status = 'posted' \gset withdrawal_restore_
\if :withdrawal_restore_has_withdrawal
SELECT ledger.deposit(
  :'run_scope', 'restore-withdrawn-wallet',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1003-USD'),
  :'withdrawal_restore_amount'::numeric, 'USD', 'restore-concurrency-test-wallet'
);
\endif
COMMIT;
