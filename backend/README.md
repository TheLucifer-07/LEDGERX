# LedgerX API

The API is an Express 5 service that reads LedgerX reporting data through the dedicated PostgreSQL `ledgerx_dashboard` role. SQL migrations remain in the repository root and are applied by `scripts/migrate.sh`.

## Local setup

Start PostgreSQL from the repository root with `scripts/setup.sh`. Then, from `backend/`:

```sh
cp .env.example .env
npm ci
npm run dev
```

Set the local dashboard password in `DATABASE_URL` to the `POSTGRES_DASHBOARD_PASSWORD` value from the ignored root `.env` file. The development server listens on `127.0.0.1:8080` by default. Docker Compose binds the API container to `0.0.0.0` internally and publishes only a loopback host port.

Run tests with `npm test`; run a production dependency install with `npm ci --omit=dev`.

## Current boundary

The API routes are read-only and call parameterized SQL. The database role has no financial write privileges. `/health/live` checks the process; `/health/ready` checks PostgreSQL without returning connection details. CORS requires an explicit origin allowlist.

This transitional API does not yet authenticate users or scope reads to workspaces. Startup therefore refuses `NODE_ENV=production`. Do not expose it publicly until Supabase identity verification, workspace authorization, and PostgreSQL row-level security are implemented and tested.
