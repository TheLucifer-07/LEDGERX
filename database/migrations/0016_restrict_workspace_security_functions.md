# Migration 0016 — restrict workspace security functions

Removes the default `PUBLIC EXECUTE` permission from functions and procedures
in the `ledger` schema. It explicitly grants current workspace helpers to the
intended database roles, keeps user registration and workspace creation
limited to `ledgerx_runtime`, and exposes only the combined onboarding function
to `ledgerx_api`. It also replaces migration 0015's initial row-lock attempt
with a transaction-scoped advisory lock that works with forced RLS and the
read-only role's lack of direct user-table writes.

This migration is a security correction found by the isolated workspace API
role test. It must be applied before enabling `ledgerx_api` login. Validate
function privileges, workspace bootstrap retries, and tenant isolation in an
isolated PostgreSQL 17 database first. The role assertions are in
`tests/api_workspace_role.sql`; bootstrap assertions are in
`tests/api_workspace_bootstrap.sql`.
