BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.refund_capture(
  :'run_scope', 'refund-70',
  (SELECT ik.transaction_id FROM ledger.idempotency_keys AS ik
    WHERE ik.scope = :'run_scope' AND ik.idempotency_key = 'capture-100'),
  70.00
);
SELECT pg_sleep(2);
COMMIT;
