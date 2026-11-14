BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.capture(
  :'run_scope', 'capture-100',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1003-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'MERCHANT-2001-USD'),
  100.00, 'USD', 'concurrent-refund-cap-test'
);
COMMIT;
