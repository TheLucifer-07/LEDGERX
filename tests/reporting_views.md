# Reporting View Tests

- **Purpose:** verify UTC daily/monthly summaries, rankings, running account balances, refund totals, settlement totals, and exception/unsettled views.
- **Dependencies:** migrations 0001–0009 and reference data.
- **Concepts:** grouped aggregates, `FILTER`, CTEs, ranking window functions, ordered running sums, and joins across ledger and external evidence.
- **Important statements:** a fixture deposits 100, captures 40, transfers 10, and refunds 5. Its wallet running normal balance must end at 55; the refund view must show 5 refunded and 35 remaining; an exact settlement batch must report 40 on both sides and no exceptions.
- **Why this approach:** checks compare the views to known journal effects instead of merely checking that a query executes.
- **Alternatives:** materialize reports at this stage. V1 uses ordinary views; no measured workload justifies staleness or refresh management.
- **Failure cases:** any incorrect count, balance, total, or unexpected exception raises and causes a nonzero psql exit.
- **Execute:** `scripts/test-reports.sh`.
- **Verify:** expect `financial reporting views and running balances: passed`.
- **Interview questions:** How do window frames define a running balance? Why group in UTC? When would a materialized view make sense?
