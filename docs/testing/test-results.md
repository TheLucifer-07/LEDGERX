# Application test results

## 2026-11-15 — monorepo and Express API foundation

**Environment:** Node.js 24.20.0, npm 11.19.0, PostgreSQL 17.12, Docker Compose. Database audit completed before application changes; no migration was applied and no financial records were written by the API checks.

| Check | Actual result |
|---|---|
| `backend/npm ci` | Passed; 155 packages installed, zero reported vulnerabilities |
| `backend/npm test` | Passed; 2 files, 13 tests |
| `backend/npm audit` | Passed; zero reported vulnerabilities |
| `frontend/npm ci` | Passed; 212 packages installed, zero reported vulnerabilities |
| `frontend/npm test` | Passed; 4 files, 9 tests |
| `frontend/npm run build` | Passed; Vite reports a 555.62 kB minified Overview chunk (164.69 kB gzip), above its 500 kB warning threshold |
| `frontend/npm audit` | Passed; zero reported vulnerabilities |
| `backend/npm run test:api` | Passed; 23 HTTP checks plus a balanced-journal assertion against the live local API and PostgreSQL data |
| `docker compose up -d --build --wait backend` | Passed; Node API healthy on the configured loopback host port |

The live checks covered both health routes; API health, currencies, all dashboard summaries, list and detail routes for transactions and accounts, account activity, journal entries and journal detail, refunds, settlements, reconciliation runs/exceptions/unsettled records, and integrity findings. Invalid dates and negative pages returned 400; POST `/api/v1/transactions` returned 405. The journal detail response reported equal decimal debit and credit totals and `balanced: true`.

The settlement-item route was not independently queried against a real batch because the local database contains zero settlement batches. Its SQL behavior remains covered only by the existing settlement database tests, which were not rerun in this application phase.

One initial live API sweep failed two endpoints because the old Spring connection pool and the Node pool competed for the database role's ten-connection limit. The Spring container was stopped and retired, the Node pool was capped at four, and the full live sweep then passed. One initial environment test also exposed an uncaught `URL` parser error for an empty database URL; validation was changed to return the expected configuration error and the final 13-test run passed.

## Database records preserved

Before and after the application migration, observed counts remained: 4 customers, 25 accounts, 68 transactions, 136 ledger entries, 68 idempotency records, and 14 refunds. There are currently zero settlement batches and zero reconciliation runs. The only database container started was the existing PostgreSQL 17 container backed by the existing named volume.

The full SQL regression suite was not run as part of this phase because no SQL migration or financial function changed. Its previously recorded run is in [testing strategy](../testing-strategy.md); it is not a result for these new application files.

## 2026-11-15 — tenant schema and RLS migrations

Migrations `0012_multi_tenant_workspaces.sql` and `0013_safe_legacy_permission_lookup.sql` were first applied to a populated database copy and a separate fresh PostgreSQL 17.12 cluster. The live local database was left untouched until the populated-copy checks passed; the same migrations were then applied to the local database in separate checksum-tracked transactions.

| Check | Actual result |
|---|---|
| Populated-copy records before/after 0012 | All 13 tenant-owned tables retained identical row counts and matching deterministic content fingerprints after excluding the newly added `workspace_id` column. Counts: 4 customers, 25 accounts, 25 balances, 68 transactions, 136 ledger entries, 68 idempotency rows, 14 refunds, 272 audit rows; settlement and reconciliation tables were empty. |
| Workspace assignment | All existing records were assigned to the private legacy workspace. The separate synthetic demo workspace remained empty. Only the new `workspace_id` column was populated; original business, amount, status, ledger, and audit payload fields matched their pre-migration fingerprints. |
| Composite foreign keys | 19 of 19 new workspace-aware foreign keys are validated. A deliberately cross-workspace account reference failed with a foreign-key violation. |
| RLS | 19 of 19 workspace and tenant-owned tables have RLS enabled and forced. `ledgerx_runtime` is not a superuser, cannot bypass RLS, and cannot log in directly. |
| Tenant isolation | Missing context returned zero account rows. Two test users each saw only their own workspace account; selecting another member's workspace was denied. Duplicate account codes, idempotency keys, and settlement batch references worked independently across workspaces; a same-tenant idempotent retry returned its original transaction. |
| Local dashboard boundary | The read-only dashboard role saw 68 legacy transactions and 136 legacy account-activity rows, saw zero rows after changing its workspace setting to the empty demo workspace, could not impersonate a workspace member, and has no membership-table or mutation privileges. |
| SQL regression suites on the populated copy | Passed: schema integrity, financial operations, integrity/projection audit, settlement reconciliation, reporting views, dashboard permissions, multi-tenant security, and migration checksum rejection. |
| Concurrent database tests on the populated copy | Passed: competing withdrawals (one success, one insufficient-balance rejection), reverse transfers, same-key idempotency, and refund cap. The concurrency fixture balances were restored. |
| Fresh installation | `scripts/setup.sh` completed on an isolated PostgreSQL 17.12 cluster. Schema, financial, integrity, settlement, reporting, dashboard privilege, and tenant-isolation suites passed. After migration 0013, tenant and dashboard tests passed again on the fresh database; the final concurrency suite passed on the populated copy. |
| Local application after migration | `/health/ready` returned `{"status":"ready"}`. The dashboard summary returned 68 transactions, USD 4160.0000 posted volume, 25 accounts, and zero integrity findings from the real database. |

An initial attempt to initialize a second database inside the existing PostgreSQL cluster stopped at migration 0001 because `ledgerx_owner` is a cluster-wide role that already exists. No data changed in that failed attempt. A clean isolated PostgreSQL 17 cluster then completed fresh initialization and all reported checks. The existing migration 0001 remains unchanged.

## Not yet verified

Hosted Supabase Auth configuration, real Supabase-issued session tests, end-to-end browser onboarding, authenticated financial read routes, financial write workflows, imports/exports, AI tools, public demo data, Vercel, Render, and hosted database migration behavior are not implemented or tested. Browser account forms and workspace request handling have unit tests with mocked Supabase/API clients; JWT verification, context selection, and database bootstrap have separate local-key and PostgreSQL isolation tests. The local dashboard API still runs only in the restricted legacy-reader mode. The current API intentionally refuses production startup.

## 2026-11-15 — API JWT and workspace-context boundary

| Check | Actual result |
|---|---|
| `backend/npm test` | Passed after the auth boundary changes: 3 files, 21 tests. This includes signed RSA test JWT verification, expired/invalid token rejection, issuer/audience/role checks, missing workspace selection, membership denial rollback, CORS support for the workspace header, and the successful context response using a mocked PostgreSQL client. |
| `backend/npm audit --omit=dev` | Passed; zero reported vulnerabilities. Package installation also reported zero vulnerabilities across 172 packages. |
| Migration 0014 on isolated PostgreSQL 17.12 | Passed through `scripts/migrate.sh`; applied and checksum recorded on the separate `ledgerx-phase2-fresh-db` cluster. No live rows changed. |
| `tests/api_workspace_role.sql` | Passed on the isolated cluster. `ledgerx_api` is `NOLOGIN`, non-superuser, and `NOBYPASSRLS`; it has approved SELECT/context privileges and no financial posting privilege. |
| `tests/multi_tenant_security.sql` after 0014 | Passed on the isolated cluster, including use of `ledgerx_api` under a verified member context and isolation from the other workspace. All fixture writes rolled back. |
| Existing isolated-cluster counts before/after 0014 | Unchanged: 4 customers, 25 accounts, 12 transactions, and 24 ledger entries. |
| Full `scripts/test.sh` after 0014 | Passed on the disposable PostgreSQL 17.12 cluster: schema integrity, financial operations, integrity/projection audit, settlement reconciliation, reporting views, concurrency scenarios, dashboard privileges, tenant isolation/API-role checks, and migration checksum rejection. Concurrency fixtures restored their balances. |
| Disposable database after full SQL suite | Observed 4 customers, 25 accounts, 21 transactions, and 42 ledger entries; the suite uses synthetic financial fixtures on this disposable database. |
| Existing local database after 0014 | Checksum migration is applied; counts remain 4 customers, 25 accounts/balances, 68 transactions, 136 ledger entries, 68 idempotency rows, 14 refunds, and 272 audit rows. `ledgerx_api` remains `NOLOGIN`; no password was configured. |
| Existing local dashboard after 0014 | `/health/ready` returned `{"status":"ready"}`. The actual summary still returned 68 transactions, USD 4160.0000 volume, 25 accounts, zero reconciliation exceptions, and zero integrity findings. |

The new route is `GET /api/v1/workspace/context`. Its JWT verification was tested with an ephemeral test signing key and fake database client; PostgreSQL's role and RLS behavior was tested separately on the isolated cluster. No Supabase project or real user session is configured. The local API does not enable this route because `AUTH_DATABASE_URL` and `SUPABASE_URL` are blank. Existing dashboard reads are not yet protected by workspace context.

## 2026-11-15 — workspace bootstrap hardening and local migration verification

Migrations `0015_idempotent_workspace_bootstrap.sql` through `0017_workspace_bootstrap_visibility.sql` were tested on an isolated PostgreSQL 17.12 cluster before applying them to the existing local database. The existing database was not changed until the populated-copy preservation, foreign-key, RLS, and tenant-isolation checks had passed.

| Check | Actual result |
|---|---|
| Bootstrap/security tests on isolated PostgreSQL 17.12 | Passed. The bootstrap API role created one owned `student` workspace, then a retry returned the same workspace with `created=false`. The SQL fixture transaction rolled back. |
| Security issues found during scratch validation | An initial role test found workspace security-definer functions still executable by `PUBLIC`; a bootstrap retry also could not see the workspace under forced RLS. Migration 0016 revokes the default grants and restores only explicit role grants. Migration 0017 adds transaction-scoped visibility limited to an active owner during provisioning. The bootstrap lock uses a transaction advisory lock, avoiding an update-policy dependency. All three fixes were verified before local migration application. |
| `tests/api_workspace_role.sql` and `tests/api_workspace_bootstrap.sql` | Passed after migrations 0015–0017. The `ledgerx_api` role remains `NOLOGIN`, non-superuser, and `NOBYPASSRLS`; it has only intended API privileges and no financial posting privileges. |
| Tenant-isolation suite after migrations 0015–0017 | Passed on the isolated cluster. Missing context returned no tenant rows; cross-workspace membership and references were denied; same-tenant retries returned the original result. Test fixture writes rolled back. |
| Full `scripts/test.sh` on isolated PostgreSQL 17.12 after migration 0017 | Passed (exit code 0), including schema, financial operations, integrity/projection audit, settlement reconciliation, reporting, concurrency, dashboard privilege, tenant/API role, bootstrap, and migration-checksum tests. Concurrency fixtures restored their balances. |
| Backend tests after API changes | `npm test` passed: 3 files, 25 tests. `npm audit --omit=dev` reported zero vulnerabilities. |
| Local migration history | Read-only catalog inspection confirmed 17 checksum-tracked migrations, latest `0017_workspace_bootstrap_visibility`. |
| Existing local business records | Counts still match the populated-copy baseline: 4 customers, 25 accounts, 25 balances, 68 transactions, 136 ledger entries, 68 idempotency records, 14 refunds, and 272 audit rows. No migration changed those business records. |
| Local workspace constraints and RLS | Read-only catalog inspection found all 25 workspace-named foreign keys validated and all 19 workspace/tenant tables with both RLS enabled and forced. `ledgerx_api` is `NOLOGIN`, not a superuser, and cannot bypass RLS. |
| Local API and financial summary | `/health/ready` returned `{"status":"ready"}`. The real dashboard summary returned 68 transactions, 68 posted, USD 4160.0000 posted volume, 25 accounts (24 active), zero settlement batches, zero reconciliation exceptions, and zero integrity findings. |

These are local and isolated-database results only. The authenticated handlers were not exercised against a real Supabase project: no project keys or `ledgerx_api` login were configured. The existing dashboard remains legacy-workspace-only and unauthenticated, so it is not suitable for public exposure.

## 2026-11-15 — public account and workspace setup screens

| Check | Actual result |
|---|---|
| `frontend/npm test` | Passed: 7 files, 17 tests. New tests cover normalized email login, signup age check/password length, email confirmation response, Google OAuth initiation, missing configuration, workspace bootstrap request headers/body, API failure state, and landing-page routes/content. |
| `frontend/npm run build` | Passed. Vite built the public pages and the dev-only operator route. It reports two chunks above the 500 kB warning threshold: `index` 521.90 kB and `Overview` 555.64 kB before gzip. |
| `frontend/npm audit --omit=dev` | Passed; zero reported vulnerabilities after adding `@supabase/supabase-js`. |
| Local browser page check | The Vite page rendered at `http://127.0.0.1:5173/`; the landing page and the explicit “Authentication setup needed” state at `/login` were visible. |
| Local account-provider integration | Not run. Supabase project URL/key, Google provider, and `ledgerx_api` login are not configured. Unit tests use mocked providers and no authentication credentials. |
| Financial record impact | None. Frontend unit tests and the local page check did not write to PostgreSQL. |

The 18+ confirmation is currently a browser-side attestation only. It is not stored in PostgreSQL or enforced by the API, so it is not sufficient for a public beta. The production application also has no authenticated workspace financial views; the legacy operator dashboard is restricted to Vite development builds.

## 2026-11-15 — global audit privilege review

While reviewing the database API role before adding authenticated financial screens, the general `ledger.audit_integrity()` function was found to be `SECURITY DEFINER` and to scan records without a workspace predicate. RLS on its source tables does not scope results returned by this privileged function. Migration `0018_revoke_global_audit_from_api.sql` removes its `EXECUTE` grant from `ledgerx_api`; no financial rows or function body changed.

| Check | Actual result |
|---|---|
| Populated safety copy | Restored the existing local database into a new database on the separate PostgreSQL 17.12 scratch cluster. Before migration 0018 it matched 4 customers, 25 accounts, 25 balances, 68 transactions, 136 ledger entries, 68 idempotency rows, 14 refunds, 272 audit rows, and migration 0017. |
| Migration and workspace/API tests | `scripts/migrate.sh` applied and checksum-recorded migration 0018 on the populated copy. `scripts/test-multi-tenant.sh` passed: composite-FK and tenant isolation checks, API role privilege assertions (including no `audit_integrity()` EXECUTE), bootstrap first call/retry, and rollback. Exit code 0. |
| Populated-copy preservation | After migration and tests, the same business-row counts remained unchanged; the workspace/tenant structure still has 25 of 25 validated workspace-named foreign keys and 19 of 19 tenant/workspace tables with RLS enabled and forced. `ledgerx_api` has no effective `EXECUTE` on the global auditor. |
| Local migration application | Only after the populated-copy checks passed, migration 0018 was applied to the local database. Read-only catalog checks show 18 migrations through `0018_revoke_global_audit_from_api`, 25 of 25 validated workspace-named foreign keys, 19 workspace/tenant tables with RLS enabled and forced, and no `ledgerx_api` execution grant on the global auditor. |
| Local business rows and API health | Counts remain 4 customers, 25 accounts, 25 balances, 68 transactions, 136 ledger entries, 68 idempotency rows, 14 refunds, and 272 audit rows. `/health/ready` still returns ready; the actual dashboard summary remains 68 posted transactions, USD 4160.0000 volume, 25 accounts, and zero integrity findings. |

The function remains available to the loopback-only local dashboard role because that application still needs its global integrity view. The authenticated API must not expose this operator function; tenant-scoped integrity reporting needs a dedicated design before it is added.
