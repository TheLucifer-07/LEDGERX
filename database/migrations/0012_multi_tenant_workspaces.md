# Migration 0012: workspaces and row-level security

## Purpose

Adds the user-to-workspace model, role permission matrix, workspace defaults,
tenant ownership columns, composite foreign keys, and PostgreSQL row-level
security. Existing migrations remain unchanged.

## Dependencies and execution order

Requires migrations `0001` through `0011` and PostgreSQL 17. Run through
`scripts/migrate.sh`; the migration runner applies this file in one transaction
after verifying earlier migration checksums.

## Existing data treatment

Every existing customer, account, balance, transaction, journal entry,
idempotency key, refund, settlement, reconciliation, and audit row is assigned
to the private `legacy` workspace (`00000000-0000-4000-8000-000000000001`). A
separate empty `demo` workspace is created. The migration never copies legacy
records into the demo workspace.

The ownership backfill temporarily disables user triggers on tenant tables.
It changes only the new `workspace_id` column, then re-enables the triggers
before adding constraints. This is needed because the existing ledger and audit
triggers correctly reject all updates or queue deferred journal checks.

## Security behavior

`ledger.set_request_context` maps the verified Supabase UUID to an internal
user and checks an active membership before setting `app.user_id` and
`app.workspace_id` transaction-locally. The caller must use one checked-out
database connection and one explicit transaction for the complete request.
Missing context resolves to no tenant for restricted application roles.

The existing local `ledgerx_admin` test connection retains a legacy-only
fallback so the database regression suite continues to exercise the original
financial functions. The separate `ledgerx_dashboard` login is read-only and
is configured for the legacy workspace by
`scripts/configure-dashboard-access.sh`. Neither role is appropriate for a
hosted application runtime.

## Why composite foreign keys are included

RLS controls which rows a query can see, while composite foreign keys prevent a
write from linking a row in one workspace to an account, transaction, refund,
or settlement item in another. Both checks are required.

## Verification

`tests/multi_tenant_security.sql` exercises workspace creation, owner
invariants, duplicate business identifiers across tenants, missing-context
denial, workspace switching, and cross-tenant foreign-key rejection. The
existing financial SQL tests are also run after this migration to check that
idempotency, transaction posting, refunds, and settlement continue to work.

The role-to-permission mapping is documented in
`docs/security/role-permission-matrix.md`.
