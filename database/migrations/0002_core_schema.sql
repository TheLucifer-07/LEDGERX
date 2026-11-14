-- Purpose: create normalized LedgerX business and evidence tables.
CREATE TABLE ledger.currencies (
  currency_code text PRIMARY KEY
    CHECK (currency_code ~ '^[A-Z]{3}$'),
  name text NOT NULL CHECK (length(btrim(name)) > 0),
  minor_unit smallint NOT NULL CHECK (minor_unit BETWEEN 0 AND 4),
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE ledger.customers (
  customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_ref text NOT NULL UNIQUE CHECK (length(btrim(customer_ref)) > 0),
  display_name text NOT NULL CHECK (length(btrim(display_name)) > 0),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'closed')),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TABLE ledger.accounts (
  account_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint REFERENCES ledger.customers(customer_id) ON DELETE RESTRICT,
  account_code text NOT NULL UNIQUE CHECK (length(btrim(account_code)) > 0),
  account_kind text NOT NULL
    CHECK (account_kind IN (
      'customer_wallet', 'merchant_wallet', 'funding_clearing', 'payout_clearing'
    )),
  normal_side text NOT NULL CHECK (normal_side IN ('debit', 'credit')),
  currency_code text NOT NULL REFERENCES ledger.currencies(currency_code)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'frozen', 'closed')),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT accounts_owner_kind_side_ck CHECK (
    (account_kind IN ('customer_wallet', 'merchant_wallet')
      AND customer_id IS NOT NULL AND normal_side = 'credit')
    OR
    (account_kind IN ('funding_clearing', 'payout_clearing')
      AND customer_id IS NULL AND normal_side = 'debit')
  )
);

CREATE TABLE ledger.account_balances (
  account_id bigint PRIMARY KEY REFERENCES ledger.accounts(account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  posted_balance numeric(20,4) NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TABLE ledger.transactions (
  transaction_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_ref text NOT NULL UNIQUE,
  transaction_type text NOT NULL CHECK (transaction_type IN (
    'deposit', 'withdrawal', 'transfer', 'capture', 'refund', 'reversal'
  )),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'posted', 'reversed')),
  amount numeric(20,4) NOT NULL CHECK (amount > 0),
  currency_code text NOT NULL REFERENCES ledger.currencies(currency_code)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  source_account_id bigint NOT NULL REFERENCES ledger.accounts(account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  destination_account_id bigint NOT NULL REFERENCES ledger.accounts(account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  reversal_of_transaction_id bigint UNIQUE
    REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  request_reference text,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  posted_at timestamptz,
  CONSTRAINT transactions_different_accounts_ck
    CHECK (source_account_id <> destination_account_id),
  CONSTRAINT transactions_reversal_link_ck CHECK (
    (transaction_type = 'reversal' AND reversal_of_transaction_id IS NOT NULL)
    OR
    (transaction_type <> 'reversal' AND reversal_of_transaction_id IS NULL)
  ),
  CONSTRAINT transactions_posted_timestamp_ck CHECK (
    (status = 'pending' AND posted_at IS NULL)
    OR (status IN ('posted', 'reversed') AND posted_at IS NOT NULL)
  )
);

CREATE TABLE ledger.ledger_entries (
  ledger_entry_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id bigint NOT NULL REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  account_id bigint NOT NULL REFERENCES ledger.accounts(account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  entry_side text NOT NULL CHECK (entry_side IN ('debit', 'credit')),
  amount numeric(20,4) NOT NULL CHECK (amount > 0),
  currency_code text NOT NULL REFERENCES ledger.currencies(currency_code)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TABLE ledger.idempotency_keys (
  idempotency_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope text NOT NULL CHECK (length(btrim(scope)) > 0),
  idempotency_key text NOT NULL
    CHECK (length(idempotency_key) BETWEEN 1 AND 200),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  transaction_id bigint UNIQUE REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT idempotency_scope_key_uq UNIQUE (scope, idempotency_key)
);

CREATE TABLE ledger.refunds (
  refund_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  original_transaction_id bigint NOT NULL
    REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  refund_transaction_id bigint NOT NULL UNIQUE
    REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  amount numeric(20,4) NOT NULL CHECK (amount > 0),
  currency_code text NOT NULL REFERENCES ledger.currencies(currency_code)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT refunds_distinct_transactions_ck
    CHECK (original_transaction_id <> refund_transaction_id)
);

CREATE TABLE ledger.settlement_batches (
  settlement_batch_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  external_batch_ref text NOT NULL UNIQUE,
  source_name text NOT NULL CHECK (length(btrim(source_name)) > 0),
  statement_date date NOT NULL,
  currency_code text NOT NULL REFERENCES ledger.currencies(currency_code)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'importing'
    CHECK (status IN ('importing', 'imported', 'reconciled', 'closed')),
  imported_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  closed_at timestamptz,
  CONSTRAINT settlement_batch_close_ck CHECK (
    (status = 'closed' AND closed_at IS NOT NULL)
    OR (status <> 'closed' AND closed_at IS NULL)
  )
);

CREATE TABLE ledger.settlement_items (
  settlement_item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  settlement_batch_id bigint NOT NULL
    REFERENCES ledger.settlement_batches(settlement_batch_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  external_ref text NOT NULL CHECK (length(btrim(external_ref)) > 0),
  external_amount numeric(20,4) NOT NULL CHECK (external_amount > 0),
  flow text NOT NULL CHECK (flow IN ('capture', 'refund')),
  currency_code text NOT NULL REFERENCES ledger.currencies(currency_code)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  external_at timestamptz,
  raw_reference text,
  CONSTRAINT settlement_items_batch_ref_uq
    UNIQUE (settlement_batch_id, external_ref)
);

CREATE TABLE ledger.settlement_matches (
  settlement_match_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  settlement_item_id bigint NOT NULL UNIQUE
    REFERENCES ledger.settlement_items(settlement_item_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  transaction_id bigint NOT NULL UNIQUE
    REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  matched_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TABLE ledger.reconciliation_runs (
  reconciliation_run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  settlement_batch_id bigint NOT NULL
    REFERENCES ledger.settlement_batches(settlement_batch_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  run_number integer NOT NULL CHECK (run_number > 0),
  started_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  completed_at timestamptz,
  CONSTRAINT reconciliation_runs_batch_number_uq
    UNIQUE (settlement_batch_id, run_number),
  CONSTRAINT reconciliation_runs_completion_ck CHECK (
    completed_at IS NULL OR completed_at >= started_at
  )
);

CREATE TABLE ledger.reconciliation_results (
  reconciliation_result_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reconciliation_run_id bigint NOT NULL
    REFERENCES ledger.reconciliation_runs(reconciliation_run_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  settlement_item_id bigint REFERENCES ledger.settlement_items(settlement_item_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  transaction_id bigint REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  result_type text NOT NULL CHECK (result_type IN (
    'matched', 'missing_internal', 'missing_external', 'amount_mismatch',
    'currency_mismatch', 'unsettled'
  )),
  expected_amount numeric(20,4),
  external_amount numeric(20,4),
  evaluated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT reconciliation_results_has_subject_ck
    CHECK (settlement_item_id IS NOT NULL OR transaction_id IS NOT NULL)
);

CREATE TABLE ledger.audit_logs (
  audit_log_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_type text NOT NULL CHECK (length(btrim(entity_type)) > 0),
  entity_id bigint NOT NULL,
  transaction_id bigint REFERENCES ledger.transactions(transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  account_id bigint REFERENCES ledger.accounts(account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  action text NOT NULL CHECK (length(btrim(action)) > 0),
  details jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(details) = 'object'),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE ledger.ledger_entries IS
  'Append-only double-entry journal lines; posted rows are the financial source of truth.';
COMMENT ON TABLE ledger.account_balances IS
  'Rebuildable, transactionally maintained projection derived from posted journal lines.';
COMMENT ON TABLE ledger.settlement_items IS
  'Immutable external statement evidence; never a posting to the internal ledger.';
