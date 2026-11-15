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

## Not yet verified

Supabase Auth, multi-tenant RLS, workspace isolation, write APIs, imports/exports, AI tools, public demo data, Vercel, Render, and hosted database migration behavior are not implemented or tested. The current API intentionally refuses production startup.
