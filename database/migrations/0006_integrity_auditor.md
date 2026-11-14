# Migration 0006: Integrity Auditor and Projection Recovery

- **Purpose:** add independent diagnostics for posted journals, currency consistency, projection parity, wallet balances, refunds, reversals, and transaction lifecycle; add controlled balance rebuild.
- **Dependencies:** migrations 0001–0005 and a populated schema.
- **Concepts:** set-based CTEs, aggregate validation independent of posting triggers, `SECURITY DEFINER`, deterministic row locking, projection reconstruction, and audit history.
- **Important statements:** `audit_integrity()` recomputes expected normalized balances from posted/reversed ledger lines and reports findings without changing data. `rebuild_account_balances()` locks accounts in ascending order, refuses to run when canonical ledger findings exist, recomputes each balance from valid posted journals, and appends an audit record.
- **Why this approach:** triggers prevent known-invalid writes, while an independent scan detects drift or corruption that may arise from operational mistakes or privileged maintenance. Rebuild repairs only the derived projection; it cannot alter ledger history.
- **Alternatives:** rebuild unconditionally or let runtime edit balances. Unconditional rebuild could conceal a corrupt ledger; runtime mutation defeats the security boundary. V1 requires clean ledger findings and exposes rebuild only to the owner role.
- **Failure cases:** any unbalanced journal, currency issue, negative ledger-derived wallet balance, over-refund, invalid state, or reversal inconsistency prevents repair. Projection-only mismatches are repairable.
- **Execute:** `scripts/setup.sh`; audit with `SELECT * FROM ledger.audit_integrity();`; repair as owner using `CALL ledger.rebuild_account_balances();`.
- **Verify:** `scripts/test-integrity.sh` introduces a projection-only inconsistency inside a rolled-back privileged test transaction, sees it reported, rebuilds, and verifies zero findings.
- **Interview questions:** Why does the auditor recompute from ledger entries? Why does rebuild ignore projection mismatch but block ledger findings? What is the lock ordering during rebuild?
