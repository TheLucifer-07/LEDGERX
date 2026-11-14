BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.withdraw(
  :'run_scope', 'withdraw-a',
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1003-USD'),
  (SELECT account_id FROM ledger.accounts WHERE account_code = 'SYS-PAYOUT-USD'),
  75.00, 'USD', 'concurrent-withdrawal-a'
);
SELECT pg_sleep(2);
COMMIT;
