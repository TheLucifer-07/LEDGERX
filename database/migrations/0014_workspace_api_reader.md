# Migration 0014 — workspace API reader

Creates `ledgerx_api` as a `NOLOGIN`, `NOBYPASSRLS`, read-only role. It has
the same approved financial read surface as the local dashboard, but it does
not use the dashboard's private legacy-only access policy. Its request path
must verify a Supabase bearer token, call `ledger.set_request_context` in a
transaction, and let RLS check workspace membership.

The migration does not set a password, enable login, or grant posting and
mutation functions. A deployment must provision a dedicated credential
through its secret manager before configuring the authenticated API pool.
The existing `ledgerx_dashboard` login and financial records are unchanged.

Execution follows migrations 0012 and 0013. The migration runner must execute
this file as the database administrator because role creation and grants are
cluster-level administration; the role itself owns no database objects.

Validation checks role attributes, approved SELECT and context-function
privileges, denied mutation privileges, and a verified membership context in
an isolated populated database copy. The rollback-only SQL assertions are in
`tests/multi_tenant_security.sql` and `tests/api_workspace_role.sql`.
