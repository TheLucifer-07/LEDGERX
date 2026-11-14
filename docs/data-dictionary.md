# LedgerX Data Dictionary

Conventions: `bigint GENERATED ALWAYS AS IDENTITY` primary keys; `timestamptz` timestamps; all monetary values use `NUMERIC(20,4)`; all tables reside in schema `ledger`. Runtime operation functions receive unconstrained `numeric` inputs and validate range/scale before writing to typmod columns. `PK`, `FK`, `UQ`, and `NN` mean primary key, foreign key, unique, and not null.

## Reference and ownership tables

### `currencies`

- `currency_code` — `text` PK; CHECK exactly three uppercase letters.
- `name` — NN display label.
- `minor_unit` — NN integer from 0 through 4; maximum permitted fractional digits.
- `active` — NN boolean, defaults true; inactive currencies cannot be used for new operations.

### `customers`

- `customer_id` — PK.
- `customer_ref` — NN UQ fictional stable identifier.
- `display_name` — NN synthetic name only.
- `status` — NN `active` or `closed`.
- `created_at` — NN defaults to transaction timestamp.

### `accounts`

- `account_id` — PK.
- `customer_id` — nullable FK; customer wallets require a customer, system accounts require NULL.
- `account_code` — NN UQ stable internal identifier.
- `account_kind` — NN constrained kind: customer wallet, merchant wallet, funding clearing, or payout clearing.
- `normal_side` — NN `debit` or `credit`; controls projection sign.
- `currency_code` — NN FK currencies; each account has one currency.
- `status` — NN `open`, `frozen`, or `closed`.
- `created_at` — NN.
- CHECK constraints require customer ownership and credit normality for customer/merchant wallets, and no customer owner plus debit normality for system clearing accounts.

### `account_balances`

- `account_id` — PK and FK accounts; exactly one projection row per account.
- `posted_balance` — NN `NUMERIC(20,4)`, normalized to account normal side: debit-normal = debits − credits; credit-normal = credits − debits.
- `updated_at` — NN projection maintenance time.
- Customer and merchant wallet balances cannot become negative. Runtime users cannot update this table directly. Rebuild derives values only from valid posted journals.

## Transaction and ledger tables

### `transactions`

- `transaction_id` — PK.
- `transaction_ref` — NN UQ fictional reference.
- `transaction_type` — NN `deposit`, `withdrawal`, `transfer`, `capture`, `refund`, or `reversal`.
- `status` — NN `pending`, `posted`, or `reversed`. A pending header may not commit; rejected requests roll back and do not leave failure records.
- `amount` — NN positive business amount, `NUMERIC(20,4)`.
- `currency_code` — NN FK currencies.
- `source_account_id`, `destination_account_id` — nullable FKs, required according to operation type; CHECK/trigger prevents self-transfer and invalid type/account combinations.
- `reversal_of_transaction_id` — nullable self-FK, UQ; only one full reversal per original.
- `request_reference` — nullable fictional correlation value; no secrets or sensitive personal data.
- `created_at`, `posted_at` — NN creation time and nullable posting time.
- Posted financial fields are immutable. Reversal changes only the original lifecycle status and adds a separate reversing transaction.

### `ledger_entries`

- `ledger_entry_id` — PK.
- `transaction_id` — NN FK transactions, delete restricted.
- `account_id` — NN FK accounts, delete restricted.
- `entry_side` — NN `debit` or `credit`.
- `amount` — NN positive amount.
- `currency_code` — NN FK currencies; deferred journal validation confirms it matches header and account.
- `created_at` — NN.
- Posted entries are append-only. A deferred constraint trigger requires every posted journal to have at least two positive entries, one currency, and equal total debits/credits.

### `idempotency_keys`

- `idempotency_id` — PK.
- `scope` — NN caller/operation namespace.
- `idempotency_key` — NN opaque request key.
- `payload_hash` — NN SHA-256 of a canonical operation/account/currency/amount/reference representation.
- `transaction_id` — NN UQ FK to the original result.
- `created_at` — NN.
- UQ `(scope, idempotency_key)` arbitrates concurrent duplicates. Keys are retained for the business-history lifetime and never reused in V1.

### `refunds`

- `refund_id` — PK.
- `original_transaction_id` — NN FK to a posted capture.
- `refund_transaction_id` — NN UQ FK to the compensating refund transaction.
- `amount` — NN positive amount.
- `currency_code` — NN FK, must equal capture currency.
- `created_at` — NN.
- A refund row only exists if its posting commits. Refund cap enforcement locks the original capture and sums previous refunds in the same transaction.

## Settlement and reconciliation tables

### `settlement_batches`

- `settlement_batch_id` — PK.
- `external_batch_ref` — NN UQ source batch reference.
- `source_name` — NN external statement source label.
- `statement_date` — NN.
- `window_start`, `window_end` — NN half-open event interval `[start, end)` defining internal capture/refund eligibility.
- `currency_code` — NN FK currencies.
- `status` — NN `importing`, `imported`, `reconciled`, or `closed`.
- `imported_at`, `closed_at` — lifecycle timestamps.
- Closed batches reject additional imports and matches.

### `settlement_items`

- `settlement_item_id` — PK.
- `settlement_batch_id` — NN FK batch.
- `external_ref` — NN statement row reference; UQ with batch.
- `external_amount` — NN positive gross amount.
- `flow` — NN `capture` or `refund`; supports direction-aware comparison.
- `currency_code` — NN FK and must match batch currency.
- `external_at` — nullable source timestamp.
- `internal_reference` — nullable external reference text matched to `transactions.transaction_ref`.
- Imported statement evidence is append-only and is not a ledger entry.

### `settlement_matches`

- `settlement_match_id` — PK.
- `settlement_item_id` — NN UQ FK external item; an item can match once.
- `transaction_id` — NN UQ FK to internal posted capture/refund; a transaction can match once.
- `matched_at` — NN timestamp.
- The one-to-one relationship is separate from imported evidence and can only be written by the reconciliation function.

### `reconciliation_runs`

- `reconciliation_run_id` — PK.
- `settlement_batch_id` — NN FK batch.
- `run_number` — NN positive integer, UQ with batch.
- `started_at` — NN timestamp.
- `completed_at` — nullable until complete.
- Each retry/reconciliation is a new version; earlier results remain auditable.

### `reconciliation_results`

- `reconciliation_result_id` — PK.
- `reconciliation_run_id` — NN FK run.
- `settlement_item_id` — nullable FK item; NULL for internal-only unmatched results.
- `transaction_id` — nullable FK transaction; NULL for external-only unmatched results.
- `result_type` — NN `matched`, `missing_internal`, `missing_external`, `amount_mismatch`, `currency_mismatch`, or `unsettled`.
- `expected_amount`, `external_amount` — nullable comparison amounts.
- `expected_currency_code`, `external_currency_code` — nullable currency evidence.
- `expected_flow`, `external_flow` — nullable capture/refund classification.
- `evaluated_at` — NN timestamp.
- Partial unique indexes on `(reconciliation_run_id, settlement_item_id)` and `(reconciliation_run_id, transaction_id)` prevent duplicates within a run.

### `audit_logs`

- `audit_log_id` — PK.
- `entity_type`, `entity_id` — NN entity descriptor and identifier.
- `transaction_id`, `account_id` — nullable typed FKs.
- `action` — NN stable event name.
- `details` — NN JSONB object with allowlisted non-sensitive values only.
- `occurred_at` — NN timestamp.
- Append-only; runtime role cannot directly insert, update, or delete audit rows.

## Relationship summary

Customers own customer wallets; system clearing accounts have no customer. Every account has one currency and one normalized balance projection. Transactions produce one or more ledger entries and may have one idempotency result. A posted capture can have multiple refunds up to its amount, or one full reversal if it has no posted refunds. Settlement batches contain immutable imported items and versioned reconciliation runs. `settlement_matches` enforces one-to-one links, while each run stores a result snapshot. Audit events can reference a transaction and/or account.
