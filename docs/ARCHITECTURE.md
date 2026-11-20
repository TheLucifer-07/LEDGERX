# Architecture

LedgerX is a PostgreSQL-only system: the schema, the business rules, the security model and the reporting layer all live in the
database. There is no application server. Anything that can run SQL (psql, a script, an application's driver) is a client.

```
 client ──(PostgreSQL protocol)──►  ledgerx_runtime  ──►  lx.* API functions (SECURITY DEFINER)  ──►  tables (owned by ledgerx_migrator)
                                          │                         │                                         ▲
                                          └── SELECT through RLS ───┴── triggers: immutability, balance check, projection
```

## Roles (database/bootstrap/00_roles.sql)
| Role | Purpose | Key properties |
|---|---|---|
| `ledgerx_migrator` | owns all `lx` objects; applies migrations | `NOSUPERUSER NOBYPASSRLS`; not used by clients |
| `ledgerx_runtime`  | the only role clients use | owns nothing; `NOBYPASSRLS`; SELECT-only (through RLS); EXECUTE only on the public API; no TEMP, no CREATE anywhere; `statement_timeout=15s`, `idle_in_transaction_session_timeout=20s` |
| administrator      | creates roles/databases, runs tests and seeds | superuser (local/Docker); never used by clients |

## Request lifecycle
```sql
BEGIN;
SELECT lx.set_context('<user uuid>', '<workspace uuid>');   -- validates ACTIVE membership in the DB, sets transaction-local settings
SELECT * FROM lx.post_journal_entry('<idempotency key>', '2026-11-01', 'Groceries', '[...lines...]');
COMMIT;                                                       -- settings vanish here; deferred balance check runs here
```
* `set_context` uses `set_config(..., is_local => true)`: context cannot outlive the transaction, so connection pooling cannot leak it
  (verified over a real reused connection in `tests/multisession`).
* Reads go straight to the tables/views and are filtered by RLS using that context. Writes are impossible except through the API functions.
* No context, malformed context, or a context for a workspace the user is not an active member of ⇒ zero rows / `LX401` / `LX403`.

## Trust boundary (read this)
PostgreSQL does **not** authenticate end users here. Some trusted layer (an API, a job runner) must authenticate the person
(e.g. verify a JWT) and then call `set_context` with that identity. The database guarantees what a *given* context can and cannot do —
it cannot prove who is behind it. Anyone holding `ledgerx_runtime` credentials can call `set_context` for any existing user, so those credentials are
server-side secrets. Details and residual risks: [SECURITY.md](SECURITY.md).

## Code layout
`database/migrations` — 10 ordered, checksummed migrations (001 schema … 010 RLS optimisation) · `database/bootstrap` — roles & database lockdown ·
`database/tests/sql` — pgTAP tests · `database/tests/multisession` — concurrency / committed-transaction tests · `database/audit` — posture report ·
`database/seeds` — deterministic generator · `benchmarks` — queries and captured results · `scripts` — Bash harness · `third_party/pgtap` — vendored pgTAP.
