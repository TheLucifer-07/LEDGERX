# Migration 0001: Platform Roles

- **Purpose:** create the `ledger` namespace and separate object ownership from runtime access.
- **Dependencies:** an empty PostgreSQL 17 database and a local administrative connection.
- **Concepts:** `NOLOGIN` group roles, schema ownership, explicit schema privileges, transactional DDL.
- **Important statements:** the `ledgerx_owner` role owns project objects; `ledgerx_runtime` receives schema usage only. The first role migration runs as the database administrator because the owner role does not yet exist.
- **Why this approach:** runtime privileges are granted deliberately in later migrations and never include arbitrary table mutation.
- **Alternative:** grant the application a single schema-owner login. That makes accidental writes much easier and is not used here.
- **Failure cases:** the migration transaction rolls back if role/schema creation fails. A manually pre-created role causes a clear migration failure rather than being silently adopted.
- **Execute:** `scripts/setup.sh` runs this migration through the checksum-verified runner.
- **Verify:** inspect `pg_roles`, `pg_namespace`, and `has_schema_privilege('ledgerx_runtime', 'ledger', 'USAGE')`.
- **Interview questions:** Why separate a `NOLOGIN` owner from runtime? What does schema `USAGE` permit? Why is the migration checksum recorded in the same transaction?
