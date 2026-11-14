# Financial Operation Tests

- **Purpose:** exercise successful postings and rejection/rollback behavior through the runtime role.
- **Dependencies:** migrations 0001–0004 and reference data. Runs under `ledgerx_runtime`, not the migration owner.
- **Concepts:** caller-owned transactions, idempotent retries, canonical request comparison, PL/pgSQL error handling, double-entry posting, normal-side balances, reversals, and privilege checks.
- **Important statements:** the test deposits, withdraws, transfers, captures, partially refunds, and reverses a separate capture. It then checks final wallet/clearing projections, original transaction state, repeated-key behavior, and direct-DML denial.
- **Why this approach:** all successful test postings run inside a single outer transaction that is rolled back. Expected failures are caught in nested blocks, so they prove the failure path without leaving financial state behind.
- **Alternatives:** seed test transactions permanently or mock the functions. Both can hide isolation issues; real database functions and transactional fixtures are exercised here.
- **Failure cases:** an unexpected success, unexpected SQLSTATE, projection mismatch, unbalanced commit check, or permission leak causes the psql process to exit nonzero.
- **Execute:** `scripts/test-financial.sh`.
- **Verify:** expect the idempotent-retry line and final `financial operations, rollback, idempotency, and runtime privileges: passed` notice.
- **Interview questions:** What work rolls back when a PL/pgSQL function raises? Why is a refund a separate transaction? Why can a runtime role execute a function but not insert ledger lines?
