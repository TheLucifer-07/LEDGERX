# Settlement and Reconciliation Tests

- **Purpose:** validate idempotent import, separate external evidence, exact and exceptional matching, versioned results, and batch-close safeguards.
- **Dependencies:** migrations 0001–0007 and reference data including USD and JPY funding/wallet/merchant accounts.
- **Concepts:** same-payload retries, unique-reference conflicts, one-to-one match constraints, versioned snapshots, currency/type-aware comparison, and immutable source evidence.
- **Important statements:** the fixture creates USD captures for exact, amount, type, and missing-external cases plus a JPY capture matched against a USD statement row. A fabricated unknown reference covers missing-internal. A second exact reference tests duplicate external links. A separate clean batch exercises close success.
- **Why this approach:** all fixtures are inside one rolled-back transaction; tests use real SQL operations and reconciliation functions without retaining fabricated settlement history.
- **Alternatives:** mutate transaction rows to simulate discrepancies. The test instead imports separate external evidence so it exercises the intended comparison boundary.
- **Failure cases:** mismatched duplicate payload, duplicate link, incomplete batch, late import, or close with exceptions must raise. Any unexpected status count fails the test.
- **Execute:** `scripts/test-settlement.sh`.
- **Verify:** expect `settlement import, one-to-one matching, versioned reconciliation, and close safeguards: passed` and exit status 0.
- **Interview questions:** How does the model distinguish internal ledger facts from external statement evidence? How are duplicate imports handled? Why are reconciliation runs append-only versions?
