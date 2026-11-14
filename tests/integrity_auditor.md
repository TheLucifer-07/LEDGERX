# Integrity Auditor Tests

- **Purpose:** prove that the independent auditor finds projection drift and that the privileged rebuild repairs it from posted journal history.
- **Dependencies:** migrations 0001–0006, reference data, and the `WALLET-INTEGRITY-USD` fixture.
- **Concepts:** independent source-of-truth reconstruction, privileged maintenance, negative assertions, and rollback-only test fixtures.
- **Important statements:** the test posts and reverses a small deposit, corrupts only its projection as the database administrator, verifies the auditor reports the affected account, then calls the owner-only rebuild and requires zero findings.
- **Why this approach:** the test-only projection write is in a rolled-back test transaction and is executed with elevated privileges; no production-facing bypass function exists.
- **Alternatives:** weaken triggers to inject a bad ledger row. That would test a protection bypass rather than the required recoverable projection discrepancy and would create unnecessary risk.
- **Failure cases:** any extra integrity finding blocks rebuild; a missing mismatch or remaining finding fails the test.
- **Execute:** `scripts/test-integrity.sh`.
- **Verify:** expect `integrity audit and projection rebuild: passed` and exit status 0.
- **Interview questions:** How can an independently calculated projection detect a stale cache? Why should repair refuse to run when the canonical journal itself is invalid? Why is the repair procedure unavailable to runtime?
