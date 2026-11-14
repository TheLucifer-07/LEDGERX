# LedgerX

LedgerX is a database-only financial transaction processing and reconciliation project for learning PostgreSQL 17. It demonstrates a double-entry journal, controlled posting functions, idempotent requests, multi-session concurrency, refunds and reversals, settlement reconciliation, database roles, and query plans. It uses fictional records; it is not intended for real payment processing.

## Start locally

Requirements: Docker Desktop or Docker Engine with Compose, Bash, and Git. PostgreSQL runs in a container on `127.0.0.1:55432`; no host PostgreSQL install is needed.

```sh
cp .env.example .env
# Set POSTGRES_PASSWORD in .env to a private local password.
scripts/setup.sh
scripts/test.sh
```

`setup.sh` starts PostgreSQL 17, applies ordered checksummed migrations, and loads fictional reference data. Re-running setup verifies already applied migrations and leaves existing records in place. `test.sh` runs rollback-based SQL assertions plus independent-session concurrency tests. Those concurrency fixtures leave a small set of committed demonstration transactions while restoring their wallet balances; use a disposable database if you want a completely empty test history.

To stop the database and keep its data, run `docker compose stop`. To remove the local database and all its data, run `docker compose down -v` from this repository. The latter is destructive.

## Layout

- `database/migrations/` — numbered schema, trigger, operation, auditor, settlement, and reporting changes. Each SQL file has a learning note beside it.
- `seeds/reference_data.sql` — fictional currencies, customers, and accounts.
- `tests/` and `scripts/test-*.sh` — SQL assertions and multi-session tests.
- `benchmarks/` — isolated synthetic query workload and captured plans.
- `docs/` — architecture, data dictionary, decisions, risks, lifecycle, security, testing, and learning material.
- `.github/workflows/database-ci.yml` — clean PostgreSQL CI setup.

Read [LEARNING_GUIDE.md](LEARNING_GUIDE.md) first, then follow [docs/learning-path.md](docs/learning-path.md). Architecture details are in [docs/architecture.md](docs/architecture.md).

## Financial model in brief

Wallets are credit-normal liabilities; funding and payout clearing accounts are debit-normal. Every posted journal has at least two positive lines and balances within a single currency. The append-only ledger is authoritative. `account_balances` is a protected, rebuildable projection used for balance checks. Rejected operations raise errors and roll back; no failed financial row is retained. Refunds apply only to captures, and a capture with a posted refund cannot be fully reversed.

## Verify or inspect

```sh
scripts/test.sh
scripts/benchmark.sh 100000
```

The benchmark writes a text report under `benchmarks/results/` with the observed PostgreSQL version, generated row count, timings, buffer counts, and plans before and after an index is added to temporary synthetic data. It does not alter financial history. Benchmark results are hardware-specific; see [docs/performance-analysis.md](docs/performance-analysis.md).

The migration runner rejects edits to migrations that have already been applied. Add a new numbered migration for schema changes; do not edit an applied migration.
