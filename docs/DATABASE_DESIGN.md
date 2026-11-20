# Database design

Everything is in schema `lx`. Money is `NUMERIC(24,6)`; there is no floating-point money anywhere (the API accepts decimal *strings* and rejects `NaN`, exponents, negatives).

## Tables
| Table | Purpose / key constraints |
|---|---|
| `currencies` | ISO code + minor unit (INR 2, JPY 0); amounts must not exceed the currency's minor units |
| `users` | `auth_user_id` links to the external identity provider; unique lower(email) |
| `workspaces` | type ∈ student/personal/family/business/demo; `base_currency` |
| `workspace_members` | PK (workspace, user); role owner/admin/member/viewer; status active/suspended/removed |
| `invitations` | only a SHA-256 of the token is stored; expiry; role admin/member/viewer |
| `accounts` | chart of accounts + accounts in one table: class asset/liability/equity/income/expense, **fixed currency**, optional parent, optional `owner_user_id` (= private account) |
| `journal_entries` | header; kind standard/transfer/opening_balance/reversal; `reverses_entry_id` is unique (one reversal per entry); `private_owner_id`; `created_xid` |
| `journal_lines` | exactly one positive side (CHECK); **composite FK (workspace, account, currency)** ties each line to an account of the same workspace *and* currency |
| `account_balances` | rebuildable projection of per-account totals (trigger-maintained under row locks) |
| `idempotency_keys` | (workspace, key) → request hash + resulting entry; unreadable by the runtime role |
| `audit_events` | append-only history |

Views (`security_invoker`, so the caller's RLS applies): `v_account_balances`, `v_monthly_cashflow`, `v_category_spend` — all grouped by currency; currencies are never summed together.

## Ledger rules and where they are enforced
| Rule | Mechanism |
|---|---|
| Every entry balances **per currency**, ≥ 2 lines | checked eagerly in `post_journal_entry`, again by a **deferred constraint trigger** at COMMIT (covers direct inserts) |
| Posting is atomic | one function = one transaction; any failure rolls back header, lines, projection and idempotency claim |
| Posted entries are immutable | `BEFORE UPDATE/DELETE/TRUNCATE` triggers raise `LX423` — even for the table owner; lines may only be inserted in the transaction that created their entry (`created_xid = pg_current_xact_id()`) |
| Corrections use reversals | `reverse_journal_entry` posts the mirror entry; one reversal per entry; a reversal cannot be reversed |
| No duplicate operations | idempotency key + normalised request hash; concurrent duplicates serialise on the key's primary key |
| Transfers are not income/expense | `kind='transfer'` may touch only asset/liability accounts; reports read income/expense *accounts* only |
| Tenant scoping | composite FKs carry `workspace_id` everywhere; RLS on every table |
| Private records | `owner_user_id` / `private_owner_id`; private and shared accounts can never be mixed in one entry (prevents private amounts leaking into shared aggregates) |
| Projection consistency | trigger-maintained; lines inserted in account order (no lock-order deadlocks); `verify_account_balances()` detects drift, `rebuild_account_balances()` repairs it under a workspace advisory lock |

## Deliberate non-rules
There is **no universal non-negative-balance rule**: a credit card, loan, overdraft facility or business payable legitimately goes "negative".
Overdraft behaviour is to be modelled explicitly per account (policy + limit) in Phase 2 — it is not enforced yet.

## Error codes
`LX401` no/invalid context → 401 · `LX403` forbidden · `LX404` not found · `LX409` conflict/idempotency · `LX422` validation · `LX423` immutable record.

## Migration history
001 schema · 002 tenant context · 003 integrity triggers · 004 workspace/account/invitation API · 005 posting & reversal · 006 projection maintenance ·
007 RLS & grants · 008 reporting views · **009 security hardening** · **010 RLS optimisation**. The migrations are applied by `scripts/migrate.sh`
(ordered, one transaction each, checksum-verified; editing an applied migration is an error).
