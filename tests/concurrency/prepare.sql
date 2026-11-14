BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.deposit(
  'concurrency-fixture', 'wallet-1001',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  100.00, 'USD', 'concurrency-test-funding'
);
SELECT ledger.deposit(
  'concurrency-fixture', 'wallet-1002',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1002-USD'),
  100.00, 'USD', 'concurrency-test-funding'
);
SELECT ledger.deposit(
  'concurrency-fixture', 'wallet-1003',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-FUND-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1003-USD'),
  100.00, 'USD', 'concurrency-test-funding'
);
COMMIT;
