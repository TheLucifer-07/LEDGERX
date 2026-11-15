# Monorepo structure

The repository is being changed from a database-only showcase into an independently installable application monorepo. Existing SQL remains at the repository root so setup, migration, benchmark, and database test scripts continue to work without moving the financial source of truth.

| Directory | Current responsibility | Local command |
|---|---|---|
| `frontend/` | Public React/Vite landing, Supabase account and workspace setup screens, plus a development-only PostgreSQL operator dashboard | `npm ci && npm run dev` |
| `backend/` | Express 5 read-only API using `pg`; local health and current dashboard read routes | `npm ci && npm run dev` |
| `database/` | Numbered PostgreSQL migrations and SQL implementation | `scripts/migrate.sh` from the root |
| `seeds/` | Fictional reference records for the local database | `scripts/seed.sh` from the root |
| `tests/`, `scripts/` | Database assertions, concurrency fixtures, migration, setup, and test runners | `scripts/test.sh` from the root |
| `docs/` | Existing database engineering notes plus the new product architecture records | Read-only |

The previous Spring Boot dashboard API was translated to the Node service and stopped. Its source remains in Git history. PostgreSQL owns financial rules; the current API uses a restricted read-only role and does not calculate or mutate balances.

Migrations 0012–0013 add app-user mapping, workspaces, memberships, a role-permission matrix, tenant ownership, composite foreign keys, and forced RLS. Migrations 0014–0018 add a separate `ledgerx_api` role, secure/idempotent workspace bootstrap, restricted security-function grants, and removal of the cross-workspace auditor from API privileges. The Node API has optional Supabase JWT context and workspace-bootstrap routes. The React app has public landing, sign-in/signup, email callback, and onboarding screens, but no real Supabase setup is configured and dashboard reads are not tenant-scoped. `backend/src/config/env.js` therefore continues to refuse production startup.

Existing local records are assigned to the private legacy workspace. A separate demo workspace exists but is empty and has no public read route. Do not expose legacy records as demo content.
