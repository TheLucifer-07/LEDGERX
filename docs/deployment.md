# Deployment Guide

LedgerX is a database engineering project. It does not include a public payment application, API, or customer-facing service. The hosted configuration described here is for a private learning or review environment using fictional records.

## Local Docker deployment

Install Docker with Compose, copy `.env.example` to `.env`, set a private local password, then run:

```sh
scripts/setup.sh
scripts/test.sh
```

PostgreSQL 17 is exposed only on `127.0.0.1:55432`. Migrations are numbered and checksum-verified; the seed file loads fictional currencies, customers, and accounts. `scripts/demo.sh` runs the end-to-end demonstration in a transaction that rolls back its writes. The explicit destructive local reset is `docker compose down -v`; it removes the database volume and all local database history.

## Hosted PostgreSQL prerequisites

- PostgreSQL 17. The implementation uses PostgreSQL 17 features and is not certified against another major version.
- A private PostgreSQL instance/database reachable only by a controlled deployment runner or private administrator network.
- A database migration login that owns the database, can create roles, and can become `ledgerx_owner` after role initialization.
- Provider-managed TLS with its CA certificate available to the deployment runner.
- Secret storage for migration and runtime credentials. Do not commit credentials or paste them into shell history.

Do not expose the database publicly to make this sample easier to reach. Restrict network ingress to a private subnet, VPN, or short-lived deployment runner. The repository contains no public payment endpoint.

## Initialize roles and apply migrations

Provide the connection string through your deployment platform's secret environment facility. Use `sslmode=verify-full` and the provider CA certificate, for example:

```text
postgresql://migration_login@private-db.example/ledgerx?sslmode=verify-full&sslrootcert=/secure/path/provider-ca.pem
```

Supply the password through the platform's protected libpq credential mechanism, such as a short-lived `PGPASSFILE`, instead of embedding it in a checked-in file. URL-encode any reserved characters if the provider requires a password in the URI.

The hosted migration runner uses `LEDGERX_DATABASE_URL` and can stop after a specific migration. First apply the role/schema bootstrap as the hosted database administrator:

```sh
export LEDGERX_DATABASE_URL='...secret-provided connection string...'
LEDGERX_MIGRATE_THROUGH=0001_platform_roles scripts/migrate.sh
psql "$LEDGERX_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -c 'GRANT ledgerx_owner TO CURRENT_USER'
unset LEDGERX_MIGRATE_THROUGH
scripts/migrate.sh
scripts/seed.sh
```

The first migration records its checksum and creates `ledgerx_owner` and `ledgerx_runtime`. Granting the owner role to the migration login allows later migrations and seed data to run with `SET ROLE ledgerx_owner`. If your provider does not allow its database administrator to create roles or grant this membership, use the provider's documented role-administration workflow; do not work around the failure by running application operations as a superuser.

`scripts/setup.sh` detects `LEDGERX_DATABASE_URL` and skips Docker startup, then applies migrations and reference data. The staged commands above make the role-membership boundary visible and reviewable.

Create a separate application login through your secret management or provider tooling, then grant only the runtime group role:

```sql
CREATE ROLE ledgerx_app LOGIN;
GRANT ledgerx_runtime TO ledgerx_app;
```

Set its credential out of band. `ledgerx_runtime` is `NOLOGIN` and should not own tables or receive direct financial-table write privileges. This project has no application service; the role is an example of the database boundary only.

## Connection security and restricted access

- Keep the database endpoint private and restrict inbound rules to approved private workloads.
- Require TLS certificate and hostname verification (`sslmode=verify-full`) for connections outside the database host.
- Store provider CA files and credentials outside the repository with restrictive file permissions.
- Use separate migration and runtime credentials. Do not provide the migration login to an application process.
- Grant runtime login membership in `ledgerx_runtime`; do not grant owner, administrator, `CREATEROLE`, or superuser privileges.
- Rotate credentials through the provider and secret manager. Review active sessions and role membership after deployment.

## Backups and restore

Enable provider-managed automated backups and point-in-time recovery if available. Select retention appropriate for the learning environment and verify restores by restoring into a separate private database. After restore, check migration history, run `SELECT * FROM ledger.audit_integrity()`, and rerun the SQL tests before using the restored database. Protect backup access as carefully as live database access. This repository does not implement backup scheduling or a restore orchestrator.

## Post-deployment verification

Use the migration login to inspect `public.ledgerx_schema_migrations`. Verify the server major version is 17, role memberships match the intended boundary, and the runtime login cannot directly modify ledger or projection tables. Run `scripts/test.sh` against a disposable local database before a hosted migration; the test harness uses Docker Compose and is not designed to run its concurrent fixture writes against a valuable hosted database. On the private hosted target, run read-only integrity checks and inspect the seeded fictional accounts. Never run a reset command against hosted data.

The demo and seed records are fictional. A successful deployment or test does not establish production readiness, regulatory compliance, or suitability for real payment processing.
