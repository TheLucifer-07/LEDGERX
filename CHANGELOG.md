# Changelog

## Unreleased — initial implementation

- Added PostgreSQL 17 Compose infrastructure and checksum-verified SQL migrations.
- Added customer, account, currency, transaction, journal, idempotency, refund, settlement, reconciliation, audit, and balance-projection schema.
- Added controlled deposits, withdrawals, transfers, captures, refunds, reversals, integrity auditing, and projection rebuild.
- Added gross one-to-one settlement import and versioned reconciliation.
- Added financial reporting views and a repeatable SQL/Bash test suite, including separate-session concurrency scenarios.
- Added GitHub Actions workflow and learner-focused documentation.
