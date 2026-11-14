BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.transfer(
  :'run_scope', 'reverse-a-to-b',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1002-USD'),
  80.00, 'USD', 'reverse-direction-a'
);
SELECT pg_sleep(2);
COMMIT;
