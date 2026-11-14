# LedgerX Requirements Specification

## Purpose and scope

LedgerX is a PostgreSQL 17 learning project that demonstrates safe financial posting, double-entry accounting, idempotent requests, concurrency control, settlement matching, reconciliation, analytics, and measured query tuning. It uses fictional customers and accounts and stores no payment-card data or sensitive personal information. It is a database-only project: PostgreSQL/PL/pgSQL, Docker Compose, Bash, Git, and GitHub Actions CI. The database is the product; no API or application service is included.

## Functional requirements

1. Maintain fictional customers and currency-denominated accounts with lifecycle status.
2. Represent every posted business operation as a journal with at least two positive ledger lines. Debits equal credits per journal and currency.
3. Process deposits, withdrawals, wallet transfers, merchant captures, full reversals where permitted, and bounded full or partial refunds atomically. Refunds apply only to posted captures. A capture with a posted refund cannot be fully reversed.
4. Reject inactive or incompatible accounts, self-transfers, invalid amounts, insufficient funds, over-refunds, and duplicate reversals.
5. Give each client request a unique idempotency key and payload fingerprint. A retry with the same key and same payload returns the original transaction; a different payload is rejected.
6. Serialize spending on affected accounts and acquire account locks in a stable order.
7. Preserve posted journal history. Correct mistakes with compensating journals; do not update or delete posted lines.
8. Store external settlement statement rows separately from internal ledger records, then classify matched and unmatched records and amount differences.
9. Offer explainable reports for daily/monthly activity, account activity/running balances, refunds, settlement, and reconciliation. Durable failed-request analytics are out of scope for V1; rejected requests raise and roll back.
10. Provide repeatable SQL assertions, two-session concurrency scenarios, synthetic data generation, and measured EXPLAIN/EXPLAIN ANALYZE reports.

## Integrity and operational requirements

- Use `NUMERIC(20,4)` as the storage ceiling and explicit currency codes backed by a currency reference table. Validate the unconstrained input amount against the currency's permitted scale before assigning to a typmod column, so excess precision cannot be rounded into acceptance. A journal uses one currency; FX is excluded.
- Enforce row-local rules with `NOT NULL`, foreign keys, `UNIQUE`, and `CHECK`; enforce journal-wide balance at the database boundary with a deferred constraint trigger.
- Keep all writes for a financial operation in one PostgreSQL transaction. The SQL function performs business steps; the caller controls `BEGIN`/`COMMIT` when composing operations. An exception aborts the unit of work.
- Target `READ COMMITTED` with explicit row locks for this design. Document that deployments needing multi-row predicate guarantees may require `SERIALIZABLE` and retry handling.
- Use least-privilege roles: application/test role calls approved functions; it does not directly mutate posted lines or internal projection state.
- Make setup and test scripts rerunnable where practical, deterministic, and explicit about errors. Never claim an unrun test or benchmark passed.
- Apply versioned migrations in order and store checksums so edits to applied migrations are detected. Use clean-database setup as the reproducibility baseline.
- Runtime roles cannot directly mutate financial state, projections, idempotency, or audit records; they call narrowly granted functions with fixed trusted search paths.
- Settlement uses gross amounts, excludes fees/taxes/FX, matches at most one external row to one internal transaction, and preserves versioned reconciliation evidence.

## Out of scope for the initial project

Real payment rails, card numbers, authentication, APIs, UI, foreign-exchange conversion, tax/fee policy, chargeback networks, durable failed-request analytics, regulatory reporting, production high availability, and real personally identifying data. Any external statement is fabricated test data.

## Acceptance evidence (to be gathered during implementation)

Schema assertions show constraints and relationships; transaction tests show balanced journals and all-or-nothing rollback; retry tests show exactly one transaction; independent sessions demonstrate no overspend and deadlock-safe lock ordering; refund/reversal tests show bounded compensations; reconciliation tests show each classification; benchmark documents contain captured commands, data scale, plans, and actual timings.
