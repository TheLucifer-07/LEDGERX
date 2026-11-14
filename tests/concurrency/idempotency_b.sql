BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.transfer(
  :'run_scope', 'same-key-transfer',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1002-USD'),
  10.00, 'USD', 'concurrent-same-key'
);
COMMIT;
