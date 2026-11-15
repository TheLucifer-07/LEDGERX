# Migration 0013: local dashboard permission lookup

## Purpose

Keeps the legacy-only local dashboard working under forced RLS without giving
its read-only database login `SELECT` access to workspace memberships.

## Dependencies and execution order

Requires `0012_multi_tenant_workspaces.sql`. Apply through
`scripts/migrate.sh`; it replaces the permission helper in place through a new
numbered migration, leaving both earlier migration files and checksums intact.

## Security behavior

`ledger.has_workspace_permission` now returns false immediately when the
session login is `ledgerx_dashboard`. That login continues to receive only
legacy data through the explicit local-reader predicate and cannot set
`app.user_id` to impersonate a workspace member. Authenticated runtime roles
continue to use the active membership and permission matrix. The helper is
`SECURITY DEFINER`, but its owner does not bypass RLS and every protected table
uses `FORCE ROW LEVEL SECURITY`.

## Verification

The populated scratch upgrade must test both the local read-only dashboard and
two authenticated workspace contexts. The dashboard must see legacy rows,
must see no rows after switching its tenant setting to the empty demo workspace,
and must retain no mutation privileges.
