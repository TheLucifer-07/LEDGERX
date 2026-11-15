# Monorepo structure

The repository is being changed from a database-only showcase into an independently installable application monorepo. Existing SQL remains at the repository root so setup, migration, benchmark, and database test scripts continue to work without moving the financial source of truth.

| Directory | Current responsibility | Local command |
|---|---|---|
| `frontend/` | Existing React/Vite PostgreSQL operations dashboard; SPA configuration for Vercel | `npm ci && npm run dev` |
| `backend/` | Express 5 read-only API using `pg`; local health and current dashboard read routes | `npm ci && npm run dev` |
| `database/` | Numbered PostgreSQL migrations and SQL implementation | `scripts/migrate.sh` from the root |
| `seeds/` | Fictional reference records for the local database | `scripts/seed.sh` from the root |
| `tests/`, `scripts/` | Database assertions, concurrency fixtures, migration, setup, and test runners | `scripts/test.sh` from the root |
| `docs/` | Existing database engineering notes plus the new product architecture records | Read-only |

The previous Spring Boot dashboard API was translated to the Node service and stopped. Its source remains in Git history. PostgreSQL owns financial rules; the current API uses a restricted read-only role and does not calculate or mutate balances.

The Node API currently has no Supabase authentication, workspace authorization, or tenant context. `backend/src/config/env.js` refuses production startup until that security work exists. This is an intentional deployment gate, not a completed security claim.

The current legacy records have no workspace owner yet. Before public demo or authenticated access is enabled, a numbered migration must assign them to an inaccessible legacy workspace and create a separate synthetic demo workspace. Do not expose the existing local records as demo content.
