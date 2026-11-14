# End-to-End SQL Demonstration

- **Purpose:** walk through one fictional wallet, merchant, refund, and settlement lifecycle with visible query results.
- **Dependencies:** migrations 0001–0010 and `seeds/reference_data.sql`; run through `scripts/demo.sh` on a disposable local database.
- **Concepts:** caller-owned transaction scope, idempotent operations, compensating refund/reversal journals, separate statement evidence, reconciliation results, auditor use, views, and balance projections.
- **Important statements:** the first capture receives a partial refund. A separate capture's partial refund is reversed and a later refund uses the released capacity. External statement rows match only posted captures/refunds; the reversed refund stays visible in history but is excluded from the active settlement. Queries display match classifications, refund history, audit findings, account activity, and balances.
- **Why this approach:** the scenario exercises the core layers together while keeping all business writes in one explicit transaction and rolling them back at the end.
- **Alternatives:** committed demo data or destructive table cleanup. Committed examples pollute immutable history; deleting demo rows would contradict the ledger model.
- **Failure cases:** run only against a disposable, migrated database with the demo reference accounts. Any assertion or SQL error stops execution; the session transaction is rolled back when the psql connection closes.
- **Execute:** `scripts/demo.sh`, or run the SQL file manually in a single psql session against a disposable database.
- **Verify:** the output contains four `matched` reconciliation results, an `integrity_clean` value of true, historical and active refund rows, and final demo balances of USD 90, USD 60, and USD 100. The ending message confirms the writes were rolled back.
- **Interview questions:** Which parts are internal books and which are external evidence? Why can a reversed refund remain visible while it is excluded from settlement? Why does the demonstration roll back?
