# Multi-tenant data model

LedgerX scopes each financial record to one workspace. User-created workspaces
support `student`, `personal`, `family`, and `business`. System workspaces are
`legacy` and `demo`.

`app_users` maps an internal UUID to a verified Supabase Auth UUID and stores no
email or profile fields. `workspace_memberships` is the source of ownership and
access: every user workspace must have exactly one `owner` membership at
transaction commit. A person can have active memberships in several
workspaces. `workspace_settings` stores default currency and timezone.
`workspace_invitations` stores an email needed to deliver an invitation and a
SHA-256 token hash; it never stores the invitation token itself.

Migration `0012_multi_tenant_workspaces.sql` assigns all existing local records
to a private legacy workspace. It creates a different empty synthetic demo
workspace and does not copy or expose the old rows there. INR is added to the
reference currency table because the original engine contained USD, JPY, and
KWD only; new workspace settings default to INR.

All tenant-owned financial tables include a non-null `workspace_id`. The
workspace identifier is immutable after insertion. Composite foreign keys pair
`workspace_id` with related account, transaction, settlement, and reconciliation
IDs so a valid global bigint from another tenant cannot be attached by mistake.
Human-selected references and idempotency keys are unique within a workspace.

The financial engine remains the source of truth. Existing `SECURITY DEFINER`
posting and settlement functions use the current workspace default, while the
migration updates their conflict handling so idempotency and external batch
references remain independent between tenants. Their financial calculations
remain in PostgreSQL.

The public demo record is currently empty and has no unauthenticated read path.
Demo seeding and a controlled read-only route are later product phases; setting
`is_public_demo` alone does not grant database access.

Migrations `0014_workspace_api_reader.sql` through
`0017_workspace_bootstrap_visibility.sql` establish the separate API role and
an idempotent owner-workspace bootstrap. `POST /api/v1/workspaces/bootstrap`
accepts only a verified Supabase subject and a validated workspace type/name;
the database records that subject, creates one owned workspace, and returns the
existing workspace on a retry. It does not create financial records. The
bootstrap path has a transaction-scoped visibility policy and explicit
function grants. See [the API contract](../api/api-contracts.md) and
[the recorded tests](../testing/test-results.md).

Migration `0018_revoke_global_audit_from_api.sql` removes the general integrity
auditor from `ledgerx_api`. That routine is `SECURITY DEFINER` and evaluates
all workspaces, so forced RLS on its source tables does not make its output
tenant-scoped. It remains available only to the separate local dashboard and
operator roles; tenant-scoped integrity reporting needs a dedicated function.
