# Workspace role permissions

Migration `0012_multi_tenant_workspaces.sql` stores this matrix in
`ledger.workspace_role_permissions`. The table is a lookup for the RLS helper
and backend authorization; it does not grant SQL privileges by itself.

| Permission | Owner | Administrator | Analyst | Auditor | Member | Viewer |
| --- | --- | --- | --- | --- | --- | --- |
| Read workspace | Yes | Yes | Yes | Yes | Yes | Yes |
| Manage settings | Yes | Yes | — | — | — | — |
| Read/manage members | Yes | Yes | — | — | — | — |
| Read finance | Yes | Yes | Yes | Yes | Yes | Yes |
| Write finance | Yes | Yes | — | — | Yes | — |
| Import/export records | Yes | Yes | — | — | Yes | — |
| Read reports | Yes | Yes | Yes | Yes | Yes | Yes |
| Read reconciliation | Yes | Yes | Yes | Yes | Yes | — |
| Manage reconciliation | Yes | Yes | — | — | — | — |
| Read audit history | Yes | Yes | — | Yes | — | — |
| Use AI assistance | Yes | Yes | — | — | Yes | — |

Ownership is one active membership with role `owner`; a partial unique index
allows at most one, and a deferred constraint trigger requires exactly one for
each student, personal, family, or business workspace. `demo` and `legacy` are
system-owned and cannot have a user owner. Membership management endpoints and
family record-level sharing rules are not implemented yet.
