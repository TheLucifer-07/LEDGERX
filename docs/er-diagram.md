# LedgerX entity relationship diagram

The diagram represents the 14 base tables in the current migrations. Optional account ownership supports system clearing accounts. `account_balances` is a derived projection. Settlement statement lines and reconciliation snapshots remain separate from posted internal journals.

```mermaid
erDiagram
    CURRENCIES ||--o{ ACCOUNTS : denominates
    CUSTOMERS o|--o{ ACCOUNTS : owns
    ACCOUNTS ||--o| ACCOUNT_BALANCES : projects
    CURRENCIES ||--o{ TRANSACTIONS : denominates
    ACCOUNTS ||--o{ TRANSACTIONS : source
    ACCOUNTS ||--o{ TRANSACTIONS : destination
    TRANSACTIONS ||--|{ LEDGER_ENTRIES : journals
    ACCOUNTS ||--o{ LEDGER_ENTRIES : receives
    CURRENCIES ||--o{ LEDGER_ENTRIES : denominates
    TRANSACTIONS ||--o| IDEMPOTENCY_KEYS : result_for
    TRANSACTIONS ||--o{ REFUNDS : original_capture
    TRANSACTIONS ||--o| REFUNDS : refund_transaction
    TRANSACTIONS ||--o| TRANSACTIONS : reversed_by
    CURRENCIES ||--o{ SETTLEMENT_BATCHES : denominates
    CURRENCIES ||--o{ SETTLEMENT_ITEMS : denominates
    SETTLEMENT_BATCHES ||--o{ SETTLEMENT_ITEMS : imports
    SETTLEMENT_BATCHES ||--o{ RECONCILIATION_RUNS : has_runs
    RECONCILIATION_RUNS ||--o{ RECONCILIATION_RESULTS : records
    SETTLEMENT_ITEMS o|--o{ RECONCILIATION_RESULTS : compared_in
    TRANSACTIONS o|--o{ RECONCILIATION_RESULTS : compared_in
    SETTLEMENT_ITEMS ||--o| SETTLEMENT_MATCHES : matched_once
    TRANSACTIONS ||--o| SETTLEMENT_MATCHES : matched_once
    TRANSACTIONS o|--o{ AUDIT_LOGS : concerns
    ACCOUNTS o|--o{ AUDIT_LOGS : concerns

    CURRENCIES {
      text currency_code PK
      text name
      smallint minor_unit
      boolean active
    }
    CUSTOMERS {
      bigint customer_id PK
      text customer_ref UK
      text display_name
      text status
      timestamptz created_at
    }
    ACCOUNTS {
      bigint account_id PK
      bigint customer_id FK
      text account_code UK
      text account_kind
      text normal_side
      text currency_code FK
      text status
      timestamptz created_at
    }
    ACCOUNT_BALANCES {
      bigint account_id PK
      numeric posted_balance
      timestamptz updated_at
    }
    TRANSACTIONS {
      bigint transaction_id PK
      text transaction_ref UK
      text transaction_type
      text status
      numeric amount
      text currency_code FK
      bigint source_account_id FK
      bigint destination_account_id FK
      bigint reversal_of_transaction_id FK
      text request_reference
      timestamptz created_at
      timestamptz posted_at
    }
    LEDGER_ENTRIES {
      bigint ledger_entry_id PK
      bigint transaction_id FK
      bigint account_id FK
      text entry_side
      numeric amount
      text currency_code FK
      timestamptz created_at
    }
    IDEMPOTENCY_KEYS {
      bigint idempotency_id PK
      text scope
      text idempotency_key
      text payload_hash
      bigint transaction_id FK
      timestamptz created_at
    }
    REFUNDS {
      bigint refund_id PK
      bigint original_transaction_id FK
      bigint refund_transaction_id FK
      numeric amount
      text currency_code FK
      timestamptz created_at
    }
    SETTLEMENT_BATCHES {
      bigint settlement_batch_id PK
      text external_batch_ref UK
      text source_name
      date statement_date
      text currency_code FK
      timestamptz window_start
      timestamptz window_end
      text status
      timestamptz imported_at
      timestamptz closed_at
    }
    SETTLEMENT_ITEMS {
      bigint settlement_item_id PK
      bigint settlement_batch_id FK
      text external_ref
      numeric external_amount
      text flow
      text currency_code FK
      timestamptz external_at
      text internal_reference
    }
    SETTLEMENT_MATCHES {
      bigint settlement_match_id PK
      bigint settlement_item_id FK
      bigint transaction_id FK
      timestamptz matched_at
    }
    RECONCILIATION_RUNS {
      bigint reconciliation_run_id PK
      bigint settlement_batch_id FK
      integer run_number
      timestamptz started_at
      timestamptz completed_at
    }
    RECONCILIATION_RESULTS {
      bigint reconciliation_result_id PK
      bigint reconciliation_run_id FK
      bigint settlement_item_id FK
      bigint transaction_id FK
      text result_type
      numeric expected_amount
      numeric external_amount
      text expected_currency_code FK
      text external_currency_code FK
      text expected_flow
      text external_flow
      timestamptz evaluated_at
    }
    AUDIT_LOGS {
      bigint audit_log_id PK
      text entity_type
      bigint entity_id
      bigint transaction_id FK_NULL
      bigint account_id FK_NULL
      text action
      jsonb details
      timestamptz occurred_at
    }
```

## Relationship and integrity notes

- Each account has a projection row created by an account trigger. The auditor detects a missing row and the owner-only rebuild can restore it; the projection is therefore a maintained invariant, not the source of truth.
- Transaction source and destination accounts are explicit foreign keys. Self-transfers are prohibited by a check constraint.
- Every committed posted transaction created through the controlled functions has a completed idempotency result. A unique constraint on `(scope, idempotency_key)` serializes retries; the transaction result reference is also unique.
- A journal has two or more positive lines. A deferred constraint trigger checks one-currency debit/credit equality at commit.
- `reversal_of_transaction_id` is unique, allowing at most one full reversal per original transaction. Reversal rows are themselves transactions with compensating journal lines.
- `settlement_items.internal_reference` is a statement-supplied reference, not a foreign key. It is matched against a posted capture/refund transaction reference during reconciliation.
- Unique constraints on each side of `settlement_matches` enforce one-to-one matching. Result rows may reference an external item, an internal transaction, or both; the result snapshot is append-only.
- `audit_logs.entity_id` is intentionally generic and is not a foreign key. Typed optional transaction/account references are retained where available.

## SQL source

- [Core tables and constraints](../database/migrations/0002_core_schema.sql)
- [Posting, ledger, and audit triggers](../database/migrations/0003_integrity_triggers.sql)
- [Settlement and reconciliation additions](../database/migrations/0007_settlement_reconciliation.sql)
- [Explicit settlement window](../database/migrations/0008_settlement_windows.sql)
- [Projection and refund history additions](../database/migrations/0010_refund_reversal_and_projection_integrity.sql)
