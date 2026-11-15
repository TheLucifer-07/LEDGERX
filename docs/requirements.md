# LedgerX Requirements and Delivery Status

## Purpose and scope

LedgerX keeps its PostgreSQL 17 financial engine as its source of truth and is being extended into a financial recordkeeping product for adults, students, families, and small businesses. The current implementation includes the database, tenant-owned workspace schema and forced RLS, a public React/Vite landing and account setup flow, a development-only operator dashboard, a local Express read API, and optional verified-token workspace-context/bootstrap routes. Supabase configuration is absent, so the signup and workspace flow is not yet end-to-end runnable. Existing local financial rows are private legacy data, not public demo data.

## Functional requirements

1. Maintain fictional customers and currency-denominated accounts with lifecycle status.
2. Represent every posted business operation as a journal with at least two positive ledger lines. Debits equal credits per journal and currency.
3. Process deposits, withdrawals, wallet transfers, merchant captures, full reversals where permitted, and bounded full or partial refunds atomically. Refunds apply only to posted captures. Only refund transactions still in `posted` status consume refundable capacity or block capture reversal; reversed refund history remains queryable.
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
- Create an account balance projection with each account, detect missing projection rows independently, and rebuild them atomically from posted journal entries with a final audit.
- Independently validate reversal headers and compare the original and compensating journal amounts by account and opposite debit/credit side.
- Target `READ COMMITTED` with explicit row locks for this design. Document that deployments needing multi-row predicate guarantees may require `SERIALIZABLE` and retry handling.
- Use least-privilege roles: application/test role calls approved functions; it does not directly mutate posted lines or internal projection state.
- Make setup and test scripts rerunnable where practical, deterministic, and explicit about errors. Never claim an unrun test or benchmark passed.
- Apply versioned migrations in order and store checksums so edits to applied migrations are detected. Use clean-database setup as the reproducibility baseline.
- Runtime roles cannot directly mutate financial state, projections, idempotency, or audit records; they call narrowly granted functions with fixed trusted search paths.
- Settlement uses gross amounts, excludes fees/taxes/FX, matches at most one external row to one internal transaction, and preserves versioned reconciliation evidence.

## Product requirements in progress

- Configure a real Supabase project and verify email/Google sign-in, browser session management, account recovery, and a full end-to-end auth test. The account UI and test-key JWT/database membership boundary exist but are not configured against a hosted project.
- Complete server-side adult attestation/privacy records, workspace switching, invitations, and authenticated financial read routes. Database user/workspace tables, role permissions, record ownership, composite tenant foreign keys, forced PostgreSQL RLS, and database-level cross-tenant tests are implemented.
- Student, personal, family, and business workspace experiences; write forms for recording financial activity; budgets, savings, recurring records, and CSV import/export.
- Isolated, deterministic demo workspaces. The public landing route is implemented without demo financial data.
- Gemini tools that use only authorized, workspace-scoped reporting data.
- Vercel, Render, Supabase-hosted PostgreSQL, controlled deployment migrations, privacy workflows, and operational recovery procedures.

Real payment rails, card numbers, money movement, lending, FX, tax filing, payment processing, and regulatory certification remain outside the V1 product scope. LedgerX is a financial recordkeeping and education project.

## Acceptance evidence (to be gathered during implementation)

Schema assertions show constraints and relationships; transaction tests show balanced journals and all-or-nothing rollback; retry tests show exactly one transaction; independent sessions demonstrate no overspend and deadlock-safe lock ordering; refund/reversal tests show bounded compensations; reconciliation tests show each classification; benchmark documents contain captured commands, data scale, plans, and actual timings.
