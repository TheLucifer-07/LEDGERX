# Learning Guide

This is a study sequence through the implementation as it exists. Keep a PostgreSQL session open and inspect each object after applying migrations; the paired migration notes explain the unfamiliar statements and verification questions.

## 1. Start with the model

Read `docs/requirements.md`, `docs/architecture.md`, `docs/er-diagram.md`, and `docs/data-dictionary.md`. Be able to explain why an account balance is a projection, why a journal is single-currency, and why settlement imports do not create ledger entries.

## 2. Set up PostgreSQL and understand migrations

Run `scripts/setup.sh`, then inspect `public.ledgerx_schema_migrations`. Read migration `0001` and its note. Explain the owner/runtime roles, trusted search path, advisory lock, and migration checksum. Try `scripts/migrate.sh` twice and observe the second run verifying rather than replaying each change.

## 3. Learn the relational foundation

Study `0002_core_schema.sql`, then `seeds/reference_data.sql`. Trace the foreign keys from customer to account and transaction to ledger entries. Identify which rules are row-local checks and which need triggers or functions.

## 4. Follow a posted deposit

Read `0003_integrity_triggers.sql` and `0004_financial_operations.sql`, then `docs/transaction-lifecycle.md`. Follow the deposit function from idempotency claim through sorted row locks, journal insertion, projection update, and posted status. Explain why the caller owns `BEGIN` and `COMMIT`.

## 5. Prove the constraints

Read `tests/schema_integrity.sql` and run `scripts/test-schema.sh`. Change a journal line in a scratch transaction and observe the append-only guard. Attempt an unbalanced journal and observe the deferred constraint at commit. Explain why a `CHECK` cannot sum sibling rows.

## 6. Study idempotency and concurrency

Read migrations `0005` and `0004`'s idempotency sections, then `tests/concurrency/` and `scripts/test-concurrency.sh`. Run the suite and inspect the two independent psql sessions. Explain unique-index arbitration, the fresh balance query after lock acquisition, and ascending account ID lock order.

## 7. Study refunds, reversals, and recovery

Read `tests/financial_operations.sql`, `0006_integrity_auditor.sql`, and its learning note. Run `scripts/test-integrity.sh`. Explain why refunds lock the original capture and why projection recovery is restricted to the owner role and derives from posted journal lines.

## 8. Trace settlement evidence

Read migrations `0007` and `0008`, `tests/settlement_reconciliation.sql`, and `docs/transaction-lifecycle.md`. Explain the half-open eligibility window, one-to-one cardinality, reconciliation run versions, and why a discrepancy does not mutate a financial transaction.

## 9. Read reports and query plans

Study migration `0009_reporting_views.sql`, its note, and `tests/reporting_views.sql`. Then run `scripts/benchmark.sh 100000` and compare the observed plans. Explain which synthetic workload is measured and why that result does not generalize to every query or machine.

## 10. Practice explaining the system

Use `docs/interview-preparation.md` to explain one invariance at a time: journal balance, atomicity, idempotency, overspending prevention, refund caps, and settlement differences. State the tests you actually ran and their limits; do not describe this project as production-ready.
