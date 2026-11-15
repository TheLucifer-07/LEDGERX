# Current API contract

This contract records the local read-only operations dashboard and optional authenticated workspace-context and workspace-bootstrap routes. Browser sign-in and onboarding screens are implemented but require real Supabase and API role configuration; authenticated financial reads remain future work.

## Routes

| Method | Path | Query or path inputs | Response |
|---|---|---|---|
| GET | `/health/live` | — | `{ "status": "live" }` |
| GET | `/health/ready` | — | `{ "status": "ready" }` or a generic 503 starting response |
| GET | `/api/v1/health` | — | `{ "status": "ok" }` after a database probe |
| GET | `/api/v1/workspace/context` | `X-LedgerX-Workspace-ID` header and Supabase bearer token | Authenticated membership role and selected workspace; available only when Supabase and the separate API database role are configured |
| POST | `/api/v1/workspaces/bootstrap` | Supabase bearer token; JSON `{ "workspace_type": "student"|"personal"|"family"|"business", "workspace_name": string }` | `201` and the newly created owned workspace; `200` with the same workspace on a legitimate retry |
| GET | `/api/v1/currencies` | — | `{ items: Currency[] }` |
| GET | `/api/v1/dashboard/summary` | `from`, `to` | Transaction, volume-by-currency, account, settlement, integrity, and range summaries |
| GET | `/api/v1/dashboard/transaction-volume` | `from`, `to` | `{ items: DailyVolume[] }` |
| GET | `/api/v1/dashboard/transaction-distribution` | `from`, `to` | `{ by_status, by_type }` |
| GET | `/api/v1/transactions` | filters, `page`, `size`, `sort`, `direction` | Paged transaction rows |
| GET | `/api/v1/transactions/{id}` | positive integer ID | Transaction details |
| GET | `/api/v1/accounts` | filters, `page`, `size`, `sort`, `direction` | Paged account rows with projected balances |
| GET | `/api/v1/accounts/{id}` | positive integer ID | Account details |
| GET | `/api/v1/accounts/{id}/activity` | `page`, `size` | Paged account activity |
| GET | `/api/v1/ledger/entries` | `from`, `to`, `side`, `currency`, `search`, `page`, `size` | Paged journal lines |
| GET | `/api/v1/ledger/journals/{id}` | transaction ID | Transaction, journal lines, exact debit/credit totals, and integrity findings |
| GET | `/api/v1/refunds` | `search`, `status`, `page`, `size` | Paged refund history and remaining refundable values |
| GET | `/api/v1/settlements` | `search`, `status`, `currency`, `page`, `size` | Paged external batch summaries |
| GET | `/api/v1/settlements/{id}/items` | batch ID, `page`, `size` | Paged imported external items and internal match data |
| GET | `/api/v1/reconciliation/runs` | `page`, `size` | Paged reconciliation-run counts |
| GET | `/api/v1/reconciliation/exceptions` | `type`, `search`, `page`, `size` | Paged exception rows |
| GET | `/api/v1/reconciliation/unsettled` | `page`, `size` | Paged unsettled transactions |
| GET | `/api/v1/integrity/findings` | `page`, `size` | Paged output from `ledger.audit_integrity()` |

List responses use `{ items, page, size, total, pages }`; page numbers are zero-based and size is capped at 100. Detail lookups return a single record. Dates use `YYYY-MM-DD`; reversed or malformed ranges return 400. Unknown paths return 404, and attempted transaction writes return 405.

PostgreSQL `NUMERIC` values are serialized as decimal strings by `pg`, preserving exact values. The frontend formats them for display and converts chart values only at the visualization boundary. 64-bit database identifiers remain strings.

The API uses parameterized queries. SQL sort identifiers are selected from fixed allowlists. Local dashboard routes run with the read-only `ledgerx_dashboard` login and never call a financial mutation function. The optional context and bootstrap routes use the separate `ledgerx_api` role, which has no financial mutation privileges. Bootstrap creates only an internal user mapping and one owned workspace; it cannot create financial records. Migration 0018 removes `ledger.audit_integrity()` from the API role because that security-definer routine scans across workspaces; the existing integrity route remains only part of the loopback local operator API.

## Authentication and deployment status

The existing dashboard routes remain unauthenticated and loopback-only. The optional workspace routes verify a Supabase bearer JWT and use the separate API role. Context selection validates active membership in a read-only transaction; bootstrap is idempotent and writes only the user/workspace setup records through a narrowly granted database function. The routes are enabled only when `AUTH_DATABASE_URL` and `SUPABASE_URL` are configured together; the API database role must be provisioned separately. They are not yet applied to dashboard financial reads. The backend still rejects production startup while those product and deployment controls are incomplete. Do not expose the API publicly in its current phase.
