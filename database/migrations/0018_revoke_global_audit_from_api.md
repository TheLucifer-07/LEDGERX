# Migration 0018 — keep the global auditor out of tenant API access

This additive permission migration removes `EXECUTE` on
`ledger.audit_integrity()` from `ledgerx_api`. The routine is
`SECURITY DEFINER` and scans all workspaces; RLS on its source tables does not
scope its results to the caller. It remains available to the local dashboard
and database operator roles that need the global integrity report.

The migration changes one function grant only. It does not touch tables,
financial records, or posting routines. A future tenant dashboard should use
an explicitly workspace-scoped integrity routine after that routine has its
own design and tests.

The migration runner applies this after `0017_workspace_bootstrap_visibility`.
The role privilege test verifies that `ledgerx_api` can execute the context and
bootstrap functions but cannot call the global auditor or any posting function.

## Decision

- **Implemented:** revoke the global audit function from the authenticated API role.
- **Why:** a security-definer function reads across RLS boundaries and can
  reveal other tenants' integrity findings.
- **Alternative:** clone the full auditor into a workspace-filtered function.
  That is deferred until tenant-scoped integrity reporting is implemented.
- **Without the restriction:** a verified user could inspect integrity details
  belonging to unrelated workspaces.
- **Verification:** `tests/api_workspace_role.sql` checks the effective grant;
  it runs against a populated PostgreSQL 17 copy before the local migration.
- **Interview explanation:** PostgreSQL views can use `security_invoker`, but a
  `SECURITY DEFINER` function intentionally runs with its owner's privileges.
  RLS therefore must be reviewed at each privileged function boundary, not
  inferred from table policies alone.
