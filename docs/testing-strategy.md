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
| Refund reversal and projection recovery | `scripts/test-financial.sh`, `scripts/test-integrity.sh`, `scripts/test-reports.sh` | Reversed refund capacity is released while history remains; missing projections and balanced wrong-account reversals are detected. |

## Running tests

```sh
scripts/test.sh
```

Run a single suite with its corresponding `scripts/test-*.sh`. A running local database is reused. The concurrency test leaves demonstration history and restores account balances, so repeating the suite does not require deleting the database.

## Current execution record

On 2026-11-14, `scripts/test.sh` exited successfully against a new PostgreSQL 17.12 Compose volume. All ten numbered migrations applied in order; the complete seven-group suite passed, including checksum rejection. The test suite checked runtime write denial, refund reversal and reuse of released capacity, projection deletion detection/recreation without changing journal history, and a balanced reversal posted to an incorrect account.

The concurrent run observed lock waits in all four intended races. The withdrawal loser and refund-cap loser each returned the expected SQLSTATE `23514` and matching insufficient-balance/refund-limit message. Both reverse-direction transfers committed, both same-key calls returned the same transaction, resulting ledger lines and balances were checked, and fixture wallets returned to their $100 starting balances. The rollback-only end-to-end demonstration also returned four matched statement rows and a clean auditor result.

The GitHub Actions workflow is configured but has not been observed running from this checkout. Do not claim CI passed until a remote workflow run confirms it. The benchmark results are separate single-run local observations; they are not throughput tests or a production performance guarantee.

The runner checks every command's exit status. A SQL assertion or migration failure stops the sequence with a nonzero exit. Tests currently use fictional, deterministic account codes and do not exercise network payment rails or crash recovery of a production deployment.
