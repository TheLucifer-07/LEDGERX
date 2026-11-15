# Migration 0015 — idempotent workspace bootstrap

Adds `ledger.bootstrap_workspace`, a controlled first-workspace setup function.
It maps the verified Supabase subject, serializes concurrent bootstrap retries
with a row lock, and returns an existing owned workspace or creates exactly
one starter workspace. It exposes no direct table DML to `ledgerx_api`.

The function uses a narrow provisioning RLS policy to read only the current
internal user's active owner memberships while it performs that check. The API
role cannot select from `workspace_memberships` directly. Its existing default
read-only transaction setting remains on; the API explicitly starts a
read-write transaction only around this SECURITY DEFINER onboarding function.

This migration follows 0014. Validate the role grants, concurrent-safe
idempotent behavior, and rollback in an isolated PostgreSQL 17 database before
applying it to the local data volume. SQL assertions are in
`tests/api_workspace_bootstrap.sql` and `tests/api_workspace_role.sql`.
