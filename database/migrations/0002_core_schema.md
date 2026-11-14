# Migration 0002: Core Schema

- **Purpose:** establish normalized reference, customer, account, transaction, ledger, idempotency, refund, settlement, reconciliation, and audit tables.
- **Dependencies:** migration 0001 created the `ledger` schema and its owner/runtime roles; this migration runs with `SET ROLE ledgerx_owner`.
- **Concepts:** identity keys, foreign keys with `RESTRICT`, row-local checks, exact numeric storage, `jsonb` for allowlisted audit detail, one-to-one uniqueness, and transactional DDL.
- **Important statements:** wallet account kinds are constrained to credit-normal liability behavior; clearing accounts are debit-normal assets. `transactions` stores business intent, while `ledger_entries` stores its accounting lines. External settlement evidence has its own tables and does not post money.
- **Why this approach:** normalized tables keep ownership, operation state, accounting, settlement evidence, matching, and audit facts distinct. Constraints reject malformed rows before procedural logic runs.
- **Alternatives:** use an enum for each status, or store flexible JSON records. V1 uses constrained text checks for small stable values and typed relational columns for business facts.
- **Failure cases:** DDL is transactional; any invalid constraint rolls the whole migration back. PostgreSQL 17's built-in `sha256(bytea)` avoids an extension or additional database privilege. Monetary typmods do not validate the original caller scale, so operation functions must do that before inserts.
- **Execute:** `scripts/setup.sh` applies this migration after the platform migration.
- **Verify:** inspect `\d ledger.*`, `pg_constraint`, and table comments; run `tests/schema_integrity.sql` after reference data exists.
- **Interview questions:** Why are imported settlement rows not journal entries? Why does a normal `CHECK` not validate journal balance? Why is the balance projection separate from the ledger?
