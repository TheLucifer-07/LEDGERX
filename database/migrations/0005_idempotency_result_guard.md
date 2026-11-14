# Migration 0005: Final Idempotency Result Guard

- **Purpose:** ensure each committed idempotency key points to a completed transaction.
- **Dependencies:** migration 0004 financial operations.
- **Concepts:** deferred constraint-trigger row images and final-state reads.
- **Important statements:** the trigger re-queries `idempotency_keys` by primary key at constraint-check time, then confirms its transaction is posted or reversed. It does not trust `NEW.transaction_id` captured by the original INSERT event.
- **Why this approach:** an idempotency row is first inserted with a NULL result to claim a key, then updated after transaction creation. A deferred trigger can run later while still receiving the original event's `NEW` values; re-reading sees the final transaction state.
- **Alternatives:** make the key transaction id known before claiming it, or omit the deferred check. The former complicates concurrent arbitration; the latter allows incomplete committed keys.
- **Failure cases:** a committed key without a completed transaction raises a check violation and aborts the transaction.
- **Execute:** `scripts/setup.sh` applies this migration after 0004.
- **Verify:** `scripts/test-financial.sh` commits its deferred checks successfully and tests that no failed request leaves a key.
- **Interview questions:** What row image does a deferred trigger receive? Why is a final-state query appropriate here? How does the unique key still serialize concurrent requests?
