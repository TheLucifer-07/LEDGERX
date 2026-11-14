# Migration 0009: Reporting Views

- **Purpose:** provide compact read-only reports over posted journal, refund, and settlement facts.
- **Dependencies:** migrations 0001–0008.
- **Concepts:** conditional aggregation, CTEs, `ROW_NUMBER`, `RANK`, `DENSE_RANK`, windowed running totals, UTC date grouping, and left joins.
- **Important statements:** `v_account_activity` computes signed normal-side deltas and running balances in stable posting/entry order. The batch summary selects the latest reconciliation run and totals both sides. Exception and unsettled views preserve the source records and do not write state.
- **Why this approach:** views keep report logic close to the database and make the meaning of each total inspectable. They are not materialized because no benchmark has shown that refreshable cached aggregates are necessary.
- **Alternatives:** one wide dashboard query, a materialized view, or multiple near-duplicate reports. V1 keeps focused views and lets `EXPLAIN (ANALYZE, BUFFERS)` determine later tuning.
- **Failure cases:** source records remain unchanged; an incorrect view can be corrected in a new migration. A recursive CTE is intentionally omitted because accounts have no hierarchy in V1.
- **Execute:** `scripts/setup.sh` applies the migration; query a view with `SELECT ... FROM ledger.v_account_activity`.
- **Verify:** `scripts/test-reports.sh` compares report totals and running balances against deterministic postings.
- **Interview questions:** Why use a window function for running balance? When would a materialized view be justified? Why is the day grouping explicitly UTC?
