# Changelog

## Unreleased

- Added additive PostgreSQL migrations 0012 and 0013 for workspace ownership, tenant-aware foreign keys, forced RLS, and a private legacy data boundary. Populated-copy results, preservation fingerprints, and actual tenant/concurrency test outcomes are recorded in [test results](docs/testing/test-results.md).
- Added migration 0014's non-login, read-only `ledgerx_api` role plus an optional Express route that verifies Supabase JWTs and checks workspace membership in a read-only transaction.
- Added migrations 0015–0017 for idempotent workspace bootstrap, restricted security-function grants, and narrowly scoped bootstrap visibility. The bootstrap uses an advisory transaction lock to make concurrent first requests safe.
- Added migration 0018 to revoke the global `SECURITY DEFINER` integrity auditor from `ledgerx_api` after review found that it scans every workspace. The API role tests now assert that this cross-tenant function is unavailable.
- Added optional `POST /api/v1/workspaces/bootstrap`, signed-token API tests, and isolated PostgreSQL checks for the API role and workspace bootstrap. The local API role remains `NOLOGIN`; no Supabase project, user credential, or production connection was configured.
- Added the public React landing page, email/password and Google sign-in flows, confirmation callback, adult-age attestation, and workspace setup screens. These use the Supabase JS client and the existing authenticated bootstrap endpoint; no account or financial records are mocked.
- Moved the legacy operations dashboard to `/operations` and limited it to Vite development builds so its legacy-only records are not part of the public production application.
- Added multi-tenancy and role-permission documentation; corrected architecture and security notes to reflect the applied migrations and the separate legacy dashboard boundary.
- Reworked the README around the project's business problem, implemented database guarantees, reproducible workflows, measured plans, test evidence, and documented limits.
- Added an architecture overview and refund/reversal and settlement lifecycle diagrams; corrected the ER diagram to include actual account, currency, reversal, and settlement relationships.
- Recorded the observed local test run separately from the successful GitHub Actions run and clarified that both predate this documentation update.
- Added a guide for future genuine DBeaver screenshots; no screenshots or query results were fabricated.
- Expanded ignore rules for local environment variants, PostgreSQL dumps, backups, and operating-system metadata.
