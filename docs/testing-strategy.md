# Testing Strategy

## Test layers

`scripts/test.sh` runs setup and then schema, financial operations, integrity recovery, settlement, reporting, concurrency, and migration-checksum checks in order. SQL tests use `ON_ERROR_STOP` and explicit assertions that raise on failure. Most business-path fixtures run in a transaction and roll back. The concurrency harness uses independent `psql` sessions; those tests commit and restore their wallet fixtures.

| Area | Test | Evidence asserted |
|---|---|---|
| Row constraints and journal integrity | `scripts/test-schema.sh` | Invalid rows rejected, balanced journal updates the projection, posted lines are immutable, deferred unbalanced journal fails. |
| Financial functions and privileges | `scripts/test-financial.sh` | Deposit, withdrawal, transfer, capture, refund, reversal, retry, payload mismatch, invalid business requests, rollback, and runtime DML denial. |
| Projection and auditor | `scripts/test-integrity.sh` | Deliberate projection corruption is found; owner-only rebuild restores parity. |
| Settlement | `scripts/test-settlement.sh` | Duplicate import behavior, matching classifications, versioning, close safeguards, and post-close import denial. |
| Views | `scripts/test-reports.sh` | Activity/running-balance and period summaries agree with deterministic transactions. |
| Concurrent requests | `scripts/test-concurrency.sh` | Competing withdrawals cannot overspend; opposite transfers both finish; same-key requests post once; refund cap is respected. |
| Migration integrity | `scripts/test-migration-checksum.sh` | A changed copy of an applied migration is refused by the runner. |

## Running tests

```sh
scripts/test.sh
```

Run a single suite with its corresponding `scripts/test-*.sh`. A running local database is reused. The concurrency test leaves demonstration history and restores account balances, so repeating the suite does not require deleting the database.

## Current execution record

On 2026-11-14, `scripts/test.sh` completed successfully against the local Docker PostgreSQL 17.12 container. All seven suites passed. The concurrency run observed PostgreSQL transaction lock waits for each contended case; one of two $70/$50 refund contenders was rejected by the $100 cap, and exactly one of two competing withdrawals succeeded. Opposite-direction transfers both succeeded, same-key requests returned one transaction, and fixture balances were restored. See the benchmark record separately; test success is not a performance claim.

The runner checks every command's exit status. A SQL assertion or migration failure stops the sequence with a nonzero exit. Tests currently use fictional, deterministic account codes and do not exercise network payment rails or crash recovery of a production deployment.
