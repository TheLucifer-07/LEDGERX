# Performance Analysis

## Benchmark design

Run `scripts/benchmark.sh <transactions>` for 1 through 1,000,000 synthetic transactions. The SQL creates session-local temporary transaction and double-line entry tables, then compares the same account-activity join and running-balance query before and after adding `(account_id, transaction_id)` to the temporary entry table. It runs `ANALYZE` and captures `EXPLAIN (ANALYZE, BUFFERS, SUMMARY)`. It does not insert or index real LedgerX financial history. Captured output is in `benchmarks/results/`.

This is an isolated access-path demonstration, not an end-to-end throughput benchmark. It excludes the posting functions, lock contention, durability settings, and network clients. The temporary-table index does not itself justify adding a production index; production indexes are based on the actual schema access patterns and future measurements.

## Observed run — 2026-11-14

Environment: Apple Silicon MacBook Pro, macOS 27.2, local Docker container, PostgreSQL 17.12 Debian image, one psql session. Each scale was run once without controlled cache warm-up. “Before/after” are the reported `Execution Time` for that single query plan; do not read the difference as a stable percentage improvement.

| Synthetic transactions | Ledger lines | Before index | After index | Main scan change |
|---:|---:|---:|---:|---|
| 1,000 | 2,000 | 0.215 ms | 0.138 ms | Entry scan to bitmap index scan |
| 100,000 | 200,000 | 13.693 ms | 8.433 ms | Entry scan to index scan |
| 1,000,000 | 2,000,000 | 133.464 ms | 90.195 ms | Entry scan to index scan |

The query returns 1% of synthetic entry rows for the selected account. Both plans still sequentially scan the transaction table and use a hash join, sort, and window aggregate. At one million transactions, the entry relation read fell from 14,720 to 7,394 local blocks; overall local reads fell from 23,104 to 15,778. At 100,000 rows, the refreshed run read 2,368 local blocks before the index and 1,638 local blocks after it (including 3 shared hits). These are not perfectly cold-cache comparisons. Index creation and analysis are outside query execution times.

The 100,000-row case was repeated after the quality pass on 2026-11-14; the table reports the latest captured plan. The 1,000- and 1,000,000-row plans are from the earlier same-day run. All remain single-run observations without a controlled warm-up or repeated percentile measurement.

## Reproduction and interpretation

```sh
scripts/benchmark.sh 1000
scripts/benchmark.sh 100000
scripts/benchmark.sh 1000000
```

The run writes `benchmarks/results/account-activity-<scale>.txt`. PostgreSQL may choose a different scan at another scale, with different cache state or settings. Review the complete plan and row estimates, not only elapsed time. A next experiment would repeat with warm-up and multiple runs, then compare median/p95 on the same dedicated environment. No materialized view has been added because these runs do not establish that a persisted aggregate is needed.
