# Current API contract

This contract records the local read-only API that currently supports the PostgreSQL operations dashboard. It is not the final public API contract: user identity, workspace selection, and role authorization will be added before public deployment.

## Routes

| Method | Path | Query or path inputs | Response |
|---|---|---|---|
| GET | `/health/live` | — | `{ "status": "live" }` |
| GET | `/health/ready` | — | `{ "status": "ready" }` or a generic 503 starting response |
| GET | `/api/v1/health` | — | `{ "status": "ok" }` after a database probe |
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

The API uses parameterized queries. SQL sort identifiers are selected from fixed allowlists. The local API runs with the read-only `ledgerx_dashboard` database login and never calls a financial mutation function.

## Authentication and deployment status

The routes are currently unauthenticated and local-only. The backend rejects production startup until Supabase identity verification, membership checks, transaction-scoped workspace context, and RLS are available. Do not expose this API publicly in its current phase.
