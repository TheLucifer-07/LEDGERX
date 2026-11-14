BEGIN;
SET LOCAL ROLE ledgerx_runtime;
SELECT ledger.refund_capture(
  :'run_scope', 'refund-50',
  (SELECT ik.transaction_id FROM ledger.idempotency_keys AS ik
    WHERE ik.scope = :'run_scope' AND ik.idempotency_key = 'capture-100'),
  50.00
);
COMMIT;
