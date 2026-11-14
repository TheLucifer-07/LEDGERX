# LedgerX Database Architecture

**Status: implementation baseline.** The execution brief resolves the initial open choices as recorded in `design-decisions.md`; this document is kept synchronized with migrations.

## Design overview

Use a normalized PostgreSQL schema in a single database. The immutable journal is the financial source of truth. `account_balances` is a transactionally maintained projection used for fast available-balance checks; it must be rebuildable and reconcilable from posted ledger lines. A transaction header describes a business operation, while its ledger lines describe the accounting effect. External settlement rows remain separate from internal transactions.

All persisted financial amounts are positive `NUMERIC(20,4)` values plus a debit/credit side, with a currency FK. Four fractional digits is the storage ceiling, while currency metadata defines permitted scale. Operation functions accept unconstrained `numeric`, validate scale and range before inserting into typmod columns, and reject excess precision instead of rounding. The first version does not perform FX.

## Accounting model

All customer wallet accounts are liability accounts with credit-normal balances. System accounts include debit-normal cash/clearing assets and, if later needed, revenue/expense accounts. Each line amount is positive. The journal invariant is `SUM(debit) = SUM(credit)` for the journal's single currency, with at least two lines.

| Operation | Debit | Credit |
|---|---|---|
| Deposit to wallet | Cash / funding clearing asset | Customer wallet liability |
| Withdrawal | Customer wallet liability | Cash / payout clearing asset |
| Wallet transfer | Sender wallet liability | Recipient wallet liability |
| Refund of capture | Debit merchant wallet liability | Credit customer wallet liability |
| Full reversal | Exact opposite of every original line | Compensating side |

The word “deposit” is modeled as a movement from a configured system funding account, not newly created value. A transfer is not represented as a balance-only update: its two ledger lines are the accounting record. Capture is an explicit transaction type representing a wallet-to-merchant payment. Refunds apply only to posted captures; cumulative posted refunds cannot exceed the captured amount. A capture with any posted refund cannot be fully reversed. Refunds and reversals are new compensating transactions.

## Posting and integrity boundary

1. A focused SQL function validates request fields and account statuses, acquires affected account rows in ascending `account_id` order, and checks the balance projection for a withdrawal/debit.
2. The function creates/claims its idempotency record, creates a transaction header, inserts all journal lines, and marks the transaction posted in the same database transaction.
3. A deferred constraint trigger fires at commit for relevant header/line changes. For a posted journal it checks line count, one currency, and equal debit and credit totals. A violation aborts the caller's transaction, including projection changes.
4. A trigger protects posted `ledger_entries` from update/delete and rejects new lines for a posted header. State transition guards prevent changing a posted transaction's financial fields. Corrections are new linked compensating transactions.
5. Only controlled posting functions may write transaction and ledger tables. Direct DML is revoked from the normal application role. This privilege boundary matters: cross-row triggers alone do not provide a safe public posting protocol if arbitrary writers can race to mutate one journal.

The deferred constraint trigger is appropriate because balance is an aggregate across rows and cannot be expressed by a normal `CHECK`. It is attached to relevant ledger-line changes and the header transition to `posted`, declared `DEFERRABLE INITIALLY DEFERRED`, and validates the final transaction state. The posting function and lock discipline form part of the invariant, not an optional convenience. Tests cover balanced and unbalanced journals, state transition, immutability, rollback, and operation paths.

## Atomicity, idempotency, and locking

The caller starts and commits a PostgreSQL transaction; the function does not issue transaction-control statements. All business effects, idempotency ownership, journal rows, refund totals, and balance projection updates commit or roll back together. Exceptions are propagated after any narrowly scoped cleanup; no failed operation is silently converted to success.

The idempotency table has a unique constraint on `(scope, idempotency_key)` and stores a canonical payload hash plus the final transaction id/result. A unique-index conflict arbitrates simultaneous same-key requests. The winning transaction performs the operation; the loser waits, reads the committed record, compares payload hashes, and either returns the original transaction or raises a key-reuse error. Hash input is canonical (operation, account ids, currency, decimal amount, and relevant reference); raw secrets are not included. V1 retains request keys with business history and does not expire/reuse them. Rejected requests raise and roll back; there is no durable failed-request record in V1.

Use `READ COMMITTED` plus `SELECT ... FOR UPDATE` on all touched account rows in ascending ID order. Once locked, perform the balance read in a subsequent statement so it receives a fresh `READ COMMITTED` snapshot after any lock wait. Update the balance projection and append journal rows before releasing locks at commit. For refunds, also lock the original transaction before summing posted refunds; this serializes competing refunds against the cap. Retry deadlock/serialization SQLSTATEs at the caller boundary with a bounded policy; stable lock order greatly reduces but cannot eliminate every deadlock.

## Settlement and reconciliation

`settlement_batches` holds batch metadata, a currency, and a half-open `[window_start, window_end)` eligibility interval. `settlement_items` holds imported external statement lines, including external reference, gross amount, direction, currency, and an optional internal reference. Imported lines are not ledger entries and never change a customer balance. V1 matches capture and refund transactions one-to-one; unique constraints prevent reusing an internal transaction or external row. Reconciliation records preserve each run's results: matched, missing internal transaction, missing external statement item, amount mismatch, currency mismatch, transaction-type mismatch, or unsettled. Unmatched external rows have no match relation. Fees, taxes, and FX are excluded.

Expected totals are computed from posted capture and refund records eligible for the batch statement date; each external row carries a positive gross amount and a direction (`capture` or `refund`). Reconciliation runs are numbered per batch and store a result snapshot without changing the ledger or imported evidence. A batch can close only after a reconciliation run; closed batches reject further imports and matches. A deliberate reopen operation is out of scope for V1.

## Performance and analytics

Start with B-tree indexes driven by access paths and foreign keys, including unique idempotency scope/key, ledger `(account_id, transaction_id)`, transaction `(status, created_at)` and partial posted-time indexes where query evidence supports them, and settlement batch/reference indexes. Avoid speculative indexes on low-selectivity status columns alone. Reports use views/CTEs/window functions over canonical records. A materialized view is added only after benchmark evidence demonstrates refreshable aggregate value and acceptable staleness. Benchmarks record PostgreSQL version, dataset size, query, `EXPLAIN (ANALYZE, BUFFERS)`, and before/after results; no times are predicted.

## Roles, deployment, and migrations

Docker Compose runs a pinned PostgreSQL 17 image with a named volume and health check. Credentials come from a local ignored environment file/example, never committed secrets. Ordered SQL files are applied once by a Bash setup script using `psql` with `ON_ERROR_STOP`. Schema changes are forward migrations; development reset is an explicit destructive script. Separate owner/migration and restricted runtime/test roles are preferred even in the local environment.

## SQL execution order

1. `database/migrations/0001_platform_roles.sql` — namespace and owner/runtime roles.
2. `database/migrations/0002_core_schema.sql` — normalized business, ledger, idempotency, settlement, reconciliation and audit tables.
3. `database/migrations/0003_integrity_triggers.sql` — access-path indexes, state guards, projection updates, deferred journal checks and audit capture.
4. `database/migrations/0004_financial_operations.sql` — controlled deposits, withdrawals, transfers, captures, refunds and reversals.
5. `database/migrations/0005_idempotency_result_guard.sql` — validate the final committed idempotency result.
6. `database/migrations/0006_integrity_auditor.sql` — independent checks and privileged projection recovery.
7. `database/migrations/0007_settlement_reconciliation.sql` — batch import and versioned matching.
8. `database/migrations/0008_settlement_windows.sql` — explicit eligible event windows.
9. `database/migrations/0009_reporting_views.sql` — useful financial and reconciliation views.
10. `seeds/reference_data.sql` — currencies, fictional customers, system accounts, wallets, and initial projection rows.
11. `tests/` scripts — run after migrations and reference data; concurrency scripts require independent sessions.
12. `benchmarks/` scripts — deterministic temporary scale generation then measured query runs.

The Bash migration runner applies each SQL migration and checksum record in the same transaction and refuses an already-applied version whose file checksum changed. Every significant SQL file has a neighboring learning note with purpose, dependencies, concepts, alternatives, failure cases, execution, verification, and interview questions.

Each migration and significant SQL file has a neighboring explanation documenting purpose, prerequisites, expected effects, and verification. Performance workload methodology and actual observations are in `docs/performance-analysis.md`.

## Key alternatives considered

- **Balance from a full ledger SUM on every operation:** simplest canonical design, but locks do not by themselves make a previously calculated aggregate safe under contention and each check grows costlier. Use a guarded, rebuildable projection, reconcile it against the journal, and keep the journal authoritative.
- **Ordinary CHECK for journal balance:** invalid for cross-row aggregates. Use a deferred constraint trigger plus restricted write path.
- **Serializable isolation for every operation:** strong but causes more serialization failures and retry complexity than needed for explicit account-row locking. Use READ COMMITTED and deterministic locks; revisit if invariants become predicate-based.
- **Delete/update mistaken postings:** rejected because it destroys auditability. Post a compensating journal.
- **Merge external settlement into ledger:** rejected because an external statement is evidence to compare, not internal authorization to move funds.
