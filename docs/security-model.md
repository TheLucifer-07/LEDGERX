# Security Model

## Roles and trust boundaries

Compose initializes a local `ledgerx_admin` superuser because PostgreSQL's container initialization needs an administrative account. `ledgerx_owner` owns the application schema and routines but cannot log in. `ledgerx_runtime` is the restricted caller role. The local admin credential is supplied in ignored `.env`; `.env.example` contains only a placeholder.

Runtime callers receive `USAGE` on the `ledger` schema, `SELECT` on approved reference/reporting objects, and `EXECUTE` on approved business functions. They do not receive table DML on transactions, ledger entries, idempotency keys, balances, refunds, audit logs, or settlement internals. The financial tests check both that permitted calls work and direct mutation is denied.

## Definer functions

Sensitive routines use `SECURITY DEFINER`, a fixed `search_path` of `pg_catalog, ledger, pg_temp`, schema-qualified object references, and explicit grants. `pg_temp` is last so a caller cannot shadow trusted names. Public execution is revoked before granting the intended runtime role. Untrusted roles cannot create objects in `ledger`.

## Workspace request identity

Migrations 0012 and 0013 add the internal Supabase subject mapping, workspace membership checks, composite tenant foreign keys, and forced row-level security. Migrations 0014–0018 add a restricted API role, controlled idempotent workspace bootstrap, explicit function grants after revoking `PUBLIC EXECUTE`, and revoke the global `SECURITY DEFINER` auditor from the API role. The auditor scans across all workspaces and cannot be treated as an RLS-scoped report. The API verifies the bearer JWT signature and expected issuer before passing its subject to `ledger.set_request_context`; the database checks active membership in the selected workspace. Workspace IDs are selection input, never authorization by themselves. Workspace bootstrap uses an advisory transaction lock for concurrent retries and a transaction-local visibility flag limited to the provisioning transaction. See [multi-tenancy](database/multi-tenancy.md) and [RLS request context](database/rls-security.md).

The current local dashboard remains a separate legacy-only read path. Authenticated workspace requests use a separate restricted database role so an end-user request cannot inherit the dashboard's private legacy access. Keep each request's workspace context in one checked-out PostgreSQL connection and one transaction; do not set tenant GUCs at session scope. The authenticated routes are optional and not connected to the financial dashboard reads yet.

## Ledger and recovery

Posted journal rows are append-only. Deferred constraint triggers validate final journal state, while controlled functions are the only runtime write path. The independent auditor compares reversal journals account by account and side by side, reports missing projections, and identifies invalid active-refund totals. The projection rebuild procedure is owner-only, upserts every account projection from posted journal lines, and performs a final audit before returning. There is no production-facing test bypass: test-only corruption runs as owner inside rolled-back subtransactions.

## Limits

This is a local learning system, not a hardened payment deployment. The Compose admin is a superuser, the legacy dashboard API remains unauthenticated and loopback-only, and there is no production network encryption policy. Hosted Supabase identity and an authenticated workspace-specific financial read path are not configured end to end. The age check currently exists only in the browser and is not a durable server-side attestation. CI uses ephemeral credentials. A real service would need managed secret delivery, carefully scoped migration credentials, consent and retention workflows, operational auditing, backup and restore drills, incident procedures, and independent security review.
