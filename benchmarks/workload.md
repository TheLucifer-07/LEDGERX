# Synthetic Account Activity Workload

- **Purpose:** produce a repeatable local query-plan comparison at progressively larger row counts without touching financial tables.
- **Dependencies:** a running Compose PostgreSQL database and `scripts/benchmark.sh`; the SQL uses only temporary tables and built-in `generate_series`.
- **Concepts:** deterministic fixture generation, temporary tables, `ANALYZE`, join and window plans, buffer reporting, and index selectivity.
- **Important statements:** each generated transaction has two equal positive lines; one in every 100 is assigned to account 1. The query returns that account's activity and running amount. The same query is run before and after a composite index on `(account_id, transaction_id)`.
- **Why this approach:** it isolates a useful activity-report access path and allows a million-row trial without polluting immutable ledger history.
- **Alternatives:** committed benchmark journals in the application schema or a copy of production-scale data. Both complicate cleanup and create less controlled evidence for a learner project.
- **Failure cases:** results vary with cache, hardware, server settings, and optimizer estimates. The generated workload is not a full representation of production traffic.
- **Execute:** `scripts/benchmark.sh 100000` (accepted range 1–1,000,000).
- **Verify:** inspect `benchmarks/results/account-activity-<scale>.txt`; it includes PostgreSQL version, host, row counts, execution plans, timing, and buffers.
- **Interview questions:** Why can a selective composite index help? Why did the plan still scan all transaction rows? Why are actual timings not a general performance guarantee?
