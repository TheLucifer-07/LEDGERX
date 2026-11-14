BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.deposit(
  :'run_scope', 'restore-withdrawn-wallet',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1003-USD'),
  75.00, 'USD', 'restore-concurrency-test-wallet'
);
COMMIT;
