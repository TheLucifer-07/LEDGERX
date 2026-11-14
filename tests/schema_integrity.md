# Schema Integrity Tests

- **Purpose:** exercise row constraints, the normal-side projection trigger, immutability guards, and deferred journal balancing before business functions are introduced.
- **Dependencies:** migrations 0001–0003 and `seeds/reference_data.sql`.
- **Concepts:** SQLSTATE-specific exception assertions, nested PL/pgSQL blocks as subtransactions, deferred constraint evaluation, transaction rollback, and projection accounting.
- **Important statements:** invalid inserts are expected to fail with `check_violation` or `foreign_key_violation`. A balanced two-line journal must update a debit-normal funding account and credit-normal wallet by positive one-dollar balances. An unbalanced one-line journal must fail when deferred constraints are forced immediate.
- **Why this approach:** these checks isolate schema-level guarantees from later operation functions. Accepted fixture postings are wrapped in a transaction and rolled back so the test can be repeated without leaving history.
- **Alternatives:** use a third-party test framework. V1 uses `psql` and native SQL assertions to keep the database and shell as the only test runtime.
- **Failure cases:** unexpected acceptance raises an exception; `psql -v ON_ERROR_STOP=1` returns nonzero. A test does not count as passing if the harness exits early.
- **Execute:** `scripts/setup.sh`, then `scripts/test-schema.sh`.
- **Verify:** expect the notices `schema row constraints: passed` and `deferred journal balance constraint: passed`, followed by exit status 0.
- **Interview questions:** How do nested exception blocks provide rollback isolation? Why does a deferred trigger need an explicit `SET CONSTRAINTS` in this test? How does the wallet projection use the credit normal side?
