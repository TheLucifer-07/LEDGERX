# Security model and audit

Evidence: `docs/evidence/security-audit.txt` (catalog report, `make audit`) and `database/tests/sql/30_security_audit.sql` (29 executable assertions).

## Trust boundaries
1. **The identity layer is external.** The database cannot tell who a person is. A trusted caller authenticates the user and passes the identity to
   `lx.set_context(user, workspace)`. The database then *re-validates active membership* and enforces everything else.
2. **`ledgerx_runtime` credentials are as powerful as the identity layer.** Holding them lets you call `set_context` for any existing user. Keep them server-side.
3. **A forged raw setting is harmless.** Policies and API functions re-check membership in the tables on every evaluation: setting `lx.user_id` by hand for a non-member returns
   nothing and every write function refuses (tested: `20_tenant_isolation.sql`, section 3).
4. **SECURITY DEFINER functions run as `ledgerx_migrator`** (the table owner, which bypasses RLS). They are therefore the *only* write path, and each begins with `lx._require_ws(...)`, which checks context, membership, role and workspace state. They are not an RLS bypass for clients.

## Audit findings
| # | Finding | Severity | Status | Evidence |
|---|---|---|---|---|
| F1 | `SECURITY DEFINER` functions ran with `search_path = lx, pg_catalog`: `lx` before `pg_catalog`, `pg_temp` implicitly first. Not shown exploitable (all references are schema-qualified) but a standard hardening gap. | Medium (hardening) | **Fixed** in migration 009: all 22 definer functions now pin `pg_catalog, pg_temp`. The whole test-suite passes with this setting, which proves every reference is qualified. | audit §6; test 30 |
| F2 | `PUBLIC` could `CONNECT` and create `TEMPORARY` objects, so the runtime role could create temp objects (the classic shadowing vector). | Medium | **Fixed** in `bootstrap/00_roles.sql` (`REVOKE ALL ON DATABASE … FROM PUBLIC`, `public` schema locked). Migration 009 *fails closed* if the lockdown is missing. | audit §2, §8; test 30 |
| F3 | During development, internal helper functions (e.g. `_claim_idempotency`) were executable by the runtime role: PostgreSQL grants EXECUTE to `PUBLIC` by default and a schema-scoped `ALTER DEFAULT PRIVILEGES` cannot remove that. Caught by a test. | High | **Fixed** (global default-privilege revoke in 001, explicit revoke + allow-list grants in 007). Test 30 asserts the *exact* set of executable functions and readable relations. | test 30 |
| F4 | RLS predicates called a non-inlinable `SECURITY DEFINER` function per row: ~3.8 s for an aggregate over 240k rows; a latent denial-of-service vector as data grows. | Performance / availability | **Fixed** in migration 010 with security equivalence *proven* (see PERFORMANCE.md, `50_rls_policy_equivalence.sql`). | rls-diagnosis.txt |

## What is verified (not assumed)
* Runtime role: not superuser / BYPASSRLS / CREATEROLE / CREATEDB; owns nothing; no write-type privilege on any relation or column; readable relations and executable functions are exactly the intended sets; no role memberships.
* Privilege-escalation attempts by the runtime role are refused with `42501`: `SET ROLE` (also over a real login), `session_replication_role = replica`, `ALTER ROLE … BYPASSRLS`, disabling triggers or RLS, creating schemas/tables/functions/temp tables, repointing a definer function's `search_path`.
* Every RLS policy is `SELECT`-only and scoped `TO ledgerx_runtime`.
* `idempotency_keys`, `users.auth_user_id`, `invitations.token_hash`, `schema_migrations` are unreadable by the runtime role.
* Family privacy: another member — including the workspace owner and an admin — sees none of a member's private accounts, entries, lines, balances, report rows, audit rows, or idempotency keys, and cannot post to or reverse them (`21_family_privacy.sql`).

## Residual risks and limitations (deliberately not hidden)
* **R1** Context spoofing by a holder of runtime credentials (trust boundary 2).
* **R2** `provision_user` and `resolve_user` are callable by the runtime role: a compromised caller can create user rows and probe whether an external id exists.
* **R3** Co-members see each other's email and display name (needed for workspace UX; revisit if undesirable).
* **R4** Three tiny inlinable SQL helpers (`ctx_user`, `ctx_workspace`, `can_see_private`) intentionally have no pinned `search_path` — pinning would prevent inlining; they call only `pg_catalog` built-ins and the test suite asserts this exact exception list.
* **R5** The audit trail and immutability are enforced by triggers: a *superuser* can disable triggers. This is tamper-resistant against application roles and the table owner, not against a database administrator. Use external logging (pgAudit, WAL archiving) for that threat model.
* **R6** Password authentication itself was not exercised in the development environment (its PostgreSQL used `trust`); the Docker image uses password auth. No claim is made about connection-level security.
* **R7** This is a portfolio project, not a reviewed financial system. No compliance claim (DPDP, PCI, accounting standards) is made.
