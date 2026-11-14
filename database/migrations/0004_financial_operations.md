# Migration 0004: Financial Operations

- **Purpose:** expose focused, idempotent PL/pgSQL-backed deposit, withdrawal, transfer, capture, refund, and reversal functions.
- **Dependencies:** migrations 0001–0003 and reference currency/account rows. Functions run as `ledgerx_owner` through `SECURITY DEFINER`.
- **Concepts:** canonical payload fingerprints, unique-index arbitration, caller-owned transactions, `READ COMMITTED`, ordered `FOR UPDATE`, normal-side projections, refund caps, and compensating journals.
- **Important statements:** `post_financial_operation` claims `(scope, key)`, compares a SHA-256 digest on retry, locks original compensation targets then sorted accounts, reads projection after lock acquisition, appends all lines, updates lifecycle state, and returns the original or new transaction id. Public wrappers prevent callers from choosing arbitrary line sides.
- **Why this approach:** a unique constraint resolves concurrent identical requests; account locks serialize spending and parent transaction locks serialize refund/reversal decisions. Every write remains in the caller's transaction so any exception rolls back all effects.
- **Alternatives:** application-side idempotency or balances were rejected because callers can race or bypass checks. The SQL API owns the financial protocol.
- **Failure cases:** invalid amount precision, status, account kind, currency, insufficient funds, key mismatch, over-refund, and invalid compensation raise errors. Deferred journal validation runs at commit; callers must commit explicitly to receive final success.
- **Execute:** apply with `scripts/setup.sh`; invoke a function as `BEGIN; SELECT ledger.deposit(...); COMMIT;`.
- **Verify:** use `tests/financial_operations.sql` and the independent-session scripts under `tests/concurrency/`.
- **Interview questions:** How does `INSERT ... ON CONFLICT DO NOTHING` handle two same-key requests? Why read the balance in a statement after `FOR UPDATE`? Why must a refund lock the original capture?
