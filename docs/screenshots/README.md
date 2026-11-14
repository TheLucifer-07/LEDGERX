# Database execution screenshots

This folder is reserved for genuine captures from a local LedgerX PostgreSQL session. No screenshots are included yet.

Suggested captures after connecting DBeaver to the running local database:

1. `dbeaver-ledger-schema.png` — DBeaver connection and expanded `ledger` schema showing actual tables and views.
2. `dbeaver-migration-history.png` — SQL result from `SELECT version, applied_at FROM public.ledgerx_schema_migrations ORDER BY version;` showing the applied migrations.
3. `dbeaver-integrity-audit.png` — SQL result from `SELECT * FROM ledger.audit_integrity();` showing the actual auditor output for the local database.

Capture the real application state; do not recreate query output in an image editor or use sample data to imply a test ran. Hide passwords, environment values, personal data, and unrelated local information before adding an image. The database contains fictional LedgerX records only.
