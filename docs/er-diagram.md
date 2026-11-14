# Entity Relationship Diagram

This is the implementation baseline. `account_balances` is a rebuildable projection; `ledger_entries` is the financial source of truth. Settlement evidence, matching, and run results are separate relations.

```mermaid
erDiagram
    CURRENCIES ||--o{ ACCOUNTS : denominates
    CUSTOMERS ||--o{ ACCOUNTS : owns
    ACCOUNTS ||--|| ACCOUNT_BALANCES : projects
    CURRENCIES ||--o{ TRANSACTIONS : denominates
    TRANSACTIONS ||--|{ LEDGER_ENTRIES : journals
    ACCOUNTS ||--o{ LEDGER_ENTRIES : receives
    CURRENCIES ||--o{ LEDGER_ENTRIES : denominates
    TRANSACTIONS ||--o| IDEMPOTENCY_KEYS : originated_by
    TRANSACTIONS ||--o{ REFUNDS : is_refunded_by
    TRANSACTIONS ||--o| REFUNDS : refund_operation
    TRANSACTIONS ||--o| TRANSACTIONS : reversed_by
    CURRENCIES ||--o{ SETTLEMENT_BATCHES : denominates
    SETTLEMENT_BATCHES ||--o{ SETTLEMENT_ITEMS : imports
    SETTLEMENT_BATCHES ||--o{ RECONCILIATION_RUNS : executes
    RECONCILIATION_RUNS ||--o{ RECONCILIATION_RESULTS : records
    SETTLEMENT_ITEMS o|--o{ RECONCILIATION_RESULTS : compared_in
    TRANSACTIONS o|--o{ RECONCILIATION_RESULTS : compared_in
    SETTLEMENT_ITEMS ||--o| SETTLEMENT_MATCHES : matched_once
    TRANSACTIONS ||--o| SETTLEMENT_MATCHES : matched_once
    TRANSACTIONS o|--o{ AUDIT_LOGS : concerns
    ACCOUNTS o|--o{ AUDIT_LOGS : concerns

    CURRENCIES {
      text currency_code PK
      smallint minor_unit
      text name
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
      bigint account_id PK_FK
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
      bigint reversal_of_transaction_id FK_UK
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
      bigint refund_transaction_id FK_UK
      numeric amount
      text currency_code FK
      timestamptz created_at
    }
    SETTLEMENT_BATCHES {
      bigint settlement_batch_id PK
      text external_batch_ref UK
      text currency_code FK
      text status
      date statement_date
      timestamptz window_start
      timestamptz window_end
      timestamptz imported_at
    }
    SETTLEMENT_ITEMS {
      bigint settlement_item_id PK
      bigint settlement_batch_id FK
      text external_ref
      numeric external_amount
      text flow
      text currency_code FK
      timestamptz external_at
    }
    SETTLEMENT_MATCHES {
      bigint settlement_match_id PK
      bigint settlement_item_id FK_UK
      bigint transaction_id FK_UK
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
      bigint settlement_item_id FK_NULL
      bigint transaction_id FK_NULL
      text result_type
      numeric expected_amount
      numeric external_amount
      text expected_currency_code
      text external_currency_code
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

Audit entity references are intentionally generic for append-only event capture; they are not substitutes for typed business foreign keys.
