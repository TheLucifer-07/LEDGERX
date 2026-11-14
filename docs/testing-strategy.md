# Testing strategy and observed results

## Test layers

[`scripts/test.sh`](../scripts/test.sh) runs setup and then seven suites. SQL assertions use `ON_ERROR_STOP` and raise on failure. Most business-path fixtures run in a transaction and roll back. The concurrency harness uses independent `psql` sessions; those scenarios commit demonstration transactions and restore their fixture wallet balances.

| Area | Runner | Evidence checked |
|---|---|---|
| Schema and journal integrity | [`test-schema.sh`](../scripts/test-schema.sh) | Invalid rows rejected, balanced journal updates projection, posted lines immutable, deferred unbalanced journal fails. |
| Financial operations and privileges | [`test-financial.sh`](../scripts/test-financial.sh) | Deposits, withdrawals, transfer, capture, refunds, reversals, rollback, same-key retry, changed-payload rejection, refund limits, and runtime direct-write denial. |
| Projection and auditor | [`test-integrity.sh`](../scripts/test-integrity.sh) | Projection corruption and missing rows are found; owner-only rebuild restores parity; reversal journal account/side mismatches are reported. |
| Settlement | [`test-settlement.sh`](../scripts/test-settlement.sh) | Duplicate imports, matching classifications, reconciliation versions, close safeguards, and post-close import denial. |
| Reporting | [`test-reports.sh`](../scripts/test-reports.sh) | Account activity/running balances and period, refund, settlement, exception, and unsettled reports match deterministic transactions. |
| Concurrency | [`test-concurrency.sh`](../scripts/test-concurrency.sh) | Competing withdrawals, opposite transfers, same-key requests, and competing refunds use separate database sessions. |
| Migration integrity | [`test-migration-checksum.sh`](../scripts/test-migration-checksum.sh) | A modified copy of an applied migration is rejected by the runner. |

Tests are fictional SQL fixtures. They do not prove correctness for every possible database schedule, external payment network, production outage, or crash-recovery scenario.

## Local execution record

**Observed 2026-11-14:** `bash scripts/test.sh` exited successfully against the existing PostgreSQL 17.12 Compose database. Setup verified all 10 numbered migrations and checksums; reference seed inserts were idempotent and added no rows. All seven suites passed.

The test output showed lock waits in the four intended concurrency scenarios. One of two simultaneous withdrawals was rejected for insufficient funds, both opposite-direction transfers completed, both same-key calls returned the same transaction, and the refund-cap loser was rejected. The concurrency harness reported all scenarios passed and fixture balances restored. The suite also passed journal constraints, rollback, runtime privilege denial, refund reversal and capacity reuse, projection recovery, settlement classification/close rules, report assertions, and modified-migration rejection.

This is an observed local run, not a claim that this documentation-only working tree has been retested after its edits. The suite leaves a small number of committed demonstration transactions in the fixture history while restoring account balances; it does not clear or reset the database volume.

## GitHub Actions record

The [latest observed Database CI run](https://github.com/TheLucifer-07/LEDGERX/actions/runs/43577577172) completed successfully on 2026-11-14 for commit `76ee06e` (run #2). It ran the repository's workflow against a clean ephemeral PostgreSQL 17 Compose volume. This run predates the current local documentation changes; no remote run has tested those unpushed edits.

The workflow is defined in [`.github/workflows/database-ci.yml`](../.github/workflows/database-ci.yml). It creates ephemeral credentials, applies setup, runs `scripts/test.sh`, and removes its CI volume afterward. That cleanup applies to the ephemeral CI job, not a developer's local database.

## Benchmark record

Benchmarks are not part of `scripts/test.sh`. Captured query plans and single-run measurements are in [`benchmarks/results/`](../benchmarks/results/); methodology and limitations are in [`performance-analysis.md`](performance-analysis.md). They measure a temporary synthetic account-activity query, not posting throughput. No benchmark was run as part of the most recent local test execution.
