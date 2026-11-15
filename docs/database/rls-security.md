# Row-level security and request context

Migration `0012_multi_tenant_workspaces.sql` enables and forces RLS on all
workspace and financial tables. Financial queries require the active workspace
from `app.workspace_id` and an active permission row for the authenticated
internal user. Reconciliation records use reconciliation permissions; audit
logs use `audit.read`. Missing context produces no visible rows and write
policies reject inserts.

The intended request lifecycle is:

1. The backend verifies the Supabase JWT and obtains its signed subject.
2. In one checked-out PostgreSQL client and explicit transaction, it calls
   `ledger.set_request_context(verified_subject, active_workspace_id)`.
3. The function maps the subject to `app_users`, checks active membership and
   stores the internal user and workspace using transaction-local settings.
4. Queries and financial functions run on that same client; the backend commits
   or rolls back and releases the client.

The transaction-local GUCs are a boundary between the trusted backend and the
database. They are not proof of identity by themselves: any party holding the
database application credential could set custom GUC values. The browser must
never connect directly to PostgreSQL, and the backend must never accept a user
or workspace ID as authorization without verifying the JWT and membership.

`ledgerx_runtime` is `NOLOGIN`, is not a table owner, and has no `BYPASSRLS`.
Production must use a restricted login; it must not use the migration or
database-admin credential. The local `ledgerx_dashboard` login is SELECT-only
and confined to the legacy workspace. Authenticated requests use a separate
API role and a JWT-verified subject. The `ledgerx_admin` fallback exists only
for the local SQL regression suite.

The current API still serves the unauthenticated, loopback-only legacy
dashboard. Supabase JWT verification and authenticated workspace-context
handling are a separate route and are not yet an end-to-end sign-in flow.

Reporting views use PostgreSQL's `security_invoker` option so their base-table
reads retain the caller's grants and RLS policies. Demo access remains denied
until an explicit server-controlled read-only demo policy and fixture set are
implemented.
