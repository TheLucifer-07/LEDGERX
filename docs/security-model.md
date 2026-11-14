# Security Model

## Roles and trust boundaries

Compose initializes a local `ledgerx_admin` superuser because PostgreSQL's container initialization needs an administrative account. `ledgerx_owner` owns the application schema and routines but cannot log in. `ledgerx_runtime` is the restricted caller role. The local admin credential is supplied in ignored `.env`; `.env.example` contains only a placeholder.

Runtime callers receive `USAGE` on the `ledger` schema, `SELECT` on approved reference/reporting objects, and `EXECUTE` on approved business functions. They do not receive table DML on transactions, ledger entries, idempotency keys, balances, refunds, audit logs, or settlement internals. The financial tests check both that permitted calls work and direct mutation is denied.

## Definer functions

Sensitive routines use `SECURITY DEFINER`, a fixed `search_path` of `pg_catalog, ledger, pg_temp`, schema-qualified object references, and explicit grants. `pg_temp` is last so a caller cannot shadow trusted names. Public execution is revoked before granting the intended runtime role. Untrusted roles cannot create objects in `ledger`.

## Ledger and recovery

Posted journal rows are append-only. Deferred constraint triggers validate final journal state, while controlled functions are the only runtime write path. The independent auditor reports inconsistencies; the projection rebuild procedure is owner-only and recomputes from posted journal lines. There is no production-facing test bypass: the test-only corruption executes as owner inside a transaction that is rolled back.

## Limits

This is a local learning system, not a hardened payment deployment. The Compose admin is a superuser, there is no authentication layer or network encryption policy, and CI uses ephemeral credentials. A real service would need managed secret delivery, carefully scoped migration credentials, operational auditing, backup and restore drills, incident procedures, and independent security review.
