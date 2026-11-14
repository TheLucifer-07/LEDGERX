-- Purpose: protect append-only history, maintain the balance projection,
-- and enforce journal-wide constraints at transaction commit.

CREATE INDEX accounts_customer_id_idx ON ledger.accounts(customer_id)
  WHERE customer_id IS NOT NULL;
CREATE INDEX accounts_currency_status_idx ON ledger.accounts(currency_code, status);
CREATE INDEX transactions_source_created_idx
  ON ledger.transactions(source_account_id, created_at DESC);
CREATE INDEX transactions_destination_created_idx
  ON ledger.transactions(destination_account_id, created_at DESC);
CREATE INDEX transactions_posted_time_idx
  ON ledger.transactions(posted_at DESC)
  WHERE status IN ('posted', 'reversed');
CREATE INDEX ledger_entries_transaction_id_idx
  ON ledger.ledger_entries(transaction_id, ledger_entry_id);
CREATE INDEX ledger_entries_account_time_idx
  ON ledger.ledger_entries(account_id, created_at, ledger_entry_id);
CREATE INDEX refunds_original_transaction_idx
  ON ledger.refunds(original_transaction_id, created_at);
CREATE INDEX settlement_items_batch_idx
  ON ledger.settlement_items(settlement_batch_id, external_at);
CREATE INDEX settlement_matches_transaction_idx
  ON ledger.settlement_matches(transaction_id);
CREATE INDEX reconciliation_runs_batch_idx
  ON ledger.reconciliation_runs(settlement_batch_id, run_number DESC);
CREATE UNIQUE INDEX reconciliation_results_run_item_uq
  ON ledger.reconciliation_results(reconciliation_run_id, settlement_item_id)
  WHERE settlement_item_id IS NOT NULL;
CREATE UNIQUE INDEX reconciliation_results_run_transaction_uq
  ON ledger.reconciliation_results(reconciliation_run_id, transaction_id)
  WHERE transaction_id IS NOT NULL;
CREATE INDEX audit_logs_transaction_time_idx
  ON ledger.audit_logs(transaction_id, occurred_at DESC)
  WHERE transaction_id IS NOT NULL;
CREATE INDEX audit_logs_account_time_idx
  ON ledger.audit_logs(account_id, occurred_at DESC)
  WHERE account_id IS NOT NULL;

CREATE FUNCTION ledger.guard_account_identity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF ROW(NEW.customer_id, NEW.account_kind, NEW.normal_side, NEW.currency_code)
     IS DISTINCT FROM
     ROW(OLD.customer_id, OLD.account_kind, OLD.normal_side, OLD.currency_code)
     AND EXISTS (
       SELECT 1 FROM ledger.ledger_entries AS le
       WHERE le.account_id = OLD.account_id
     ) THEN
    RAISE EXCEPTION 'account ownership, kind, normal side, and currency are immutable after first entry'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER accounts_identity_guard
BEFORE UPDATE ON ledger.accounts
FOR EACH ROW EXECUTE FUNCTION ledger.guard_account_identity();

CREATE FUNCTION ledger.guard_transaction_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'transaction history cannot be deleted'
      USING ERRCODE = '55000';
  END IF;

  IF ROW(NEW.transaction_ref, NEW.transaction_type, NEW.amount,
         NEW.currency_code, NEW.source_account_id, NEW.destination_account_id,
         NEW.reversal_of_transaction_id, NEW.request_reference, NEW.created_at)
     IS DISTINCT FROM
     ROW(OLD.transaction_ref, OLD.transaction_type, OLD.amount,
         OLD.currency_code, OLD.source_account_id, OLD.destination_account_id,
         OLD.reversal_of_transaction_id, OLD.request_reference, OLD.created_at) THEN
    RAISE EXCEPTION 'transaction financial attributes are immutable'
      USING ERRCODE = '55000';
  END IF;

  IF OLD.status = 'pending' AND NEW.status = 'posted' THEN
    IF NEW.posted_at IS NULL THEN
      RAISE EXCEPTION 'posted transaction requires posted_at'
        USING ERRCODE = '23514';
    END IF;
  ELSIF OLD.status = 'posted' AND NEW.status = 'reversed' THEN
    IF NEW.posted_at IS DISTINCT FROM OLD.posted_at THEN
      RAISE EXCEPTION 'reversal cannot change original posted_at'
        USING ERRCODE = '55000';
    END IF;
  ELSIF NEW.status IS DISTINCT FROM OLD.status
     OR NEW.posted_at IS DISTINCT FROM OLD.posted_at THEN
    RAISE EXCEPTION 'invalid transaction lifecycle transition: % to %',
      OLD.status, NEW.status USING ERRCODE = '55000';
  END IF;

  RETURN NEW;
END
$function$;

CREATE TRIGGER transactions_change_guard
BEFORE UPDATE OR DELETE ON ledger.transactions
FOR EACH ROW EXECUTE FUNCTION ledger.guard_transaction_change();

CREATE FUNCTION ledger.apply_ledger_entry()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_transaction_status text;
  v_transaction_currency text;
  v_account_currency text;
  v_account_status text;
  v_account_kind text;
  v_normal_side text;
  v_delta numeric(20,4);
  v_new_balance numeric(20,4);
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'ledger entries are append-only'
      USING ERRCODE = '55000';
  END IF;

  SELECT t.status, t.currency_code, a.currency_code, a.status,
         a.account_kind, a.normal_side
    INTO v_transaction_status, v_transaction_currency, v_account_currency,
         v_account_status, v_account_kind, v_normal_side
    FROM ledger.transactions AS t
    JOIN ledger.accounts AS a ON a.account_id = NEW.account_id
   WHERE t.transaction_id = NEW.transaction_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'journal transaction or account does not exist'
      USING ERRCODE = '23503';
  END IF;
  IF v_transaction_status <> 'pending' THEN
    RAISE EXCEPTION 'ledger entries may only be added to a pending transaction'
      USING ERRCODE = '55000';
  END IF;
  IF v_account_status <> 'open' THEN
    RAISE EXCEPTION 'account % is not open', NEW.account_id
      USING ERRCODE = '23514';
  END IF;
  IF NEW.currency_code <> v_transaction_currency
     OR NEW.currency_code <> v_account_currency THEN
    RAISE EXCEPTION 'ledger entry currency must match both transaction and account'
      USING ERRCODE = '23514';
  END IF;

  v_delta := CASE WHEN NEW.entry_side = v_normal_side
    THEN NEW.amount ELSE -NEW.amount END;

  IF v_account_kind IN ('customer_wallet', 'merchant_wallet') THEN
    UPDATE ledger.account_balances AS b
       SET posted_balance = b.posted_balance + v_delta,
           updated_at = clock_timestamp()
     WHERE b.account_id = NEW.account_id
       AND b.posted_balance + v_delta >= 0
     RETURNING b.posted_balance INTO v_new_balance;
  ELSE
    UPDATE ledger.account_balances AS b
       SET posted_balance = b.posted_balance + v_delta,
           updated_at = clock_timestamp()
     WHERE b.account_id = NEW.account_id
     RETURNING b.posted_balance INTO v_new_balance;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'insufficient available balance for account %', NEW.account_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END
$function$;

CREATE TRIGGER ledger_entries_apply_balance
BEFORE INSERT OR UPDATE OR DELETE ON ledger.ledger_entries
FOR EACH ROW EXECUTE FUNCTION ledger.apply_ledger_entry();

CREATE FUNCTION ledger.validate_final_journal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_transaction_id bigint;
  v_status text;
  v_amount numeric(20,4);
  v_currency text;
  v_line_count bigint;
  v_currency_count bigint;
  v_mismatch_count bigint;
  v_debits numeric(20,4);
  v_credits numeric(20,4);
BEGIN
  IF TG_TABLE_NAME = 'transactions' THEN
    v_transaction_id := COALESCE(NEW.transaction_id, OLD.transaction_id);
  ELSE
    v_transaction_id := COALESCE(NEW.transaction_id, OLD.transaction_id);
  END IF;

  SELECT t.status, t.amount, t.currency_code
    INTO v_status, v_amount, v_currency
    FROM ledger.transactions AS t
   WHERE t.transaction_id = v_transaction_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_status = 'pending' THEN
    RAISE EXCEPTION 'transaction % cannot commit in pending state', v_transaction_id
      USING ERRCODE = '23514';
  END IF;

  SELECT count(*), count(DISTINCT le.currency_code),
         count(*) FILTER (WHERE le.currency_code <> v_currency
                             OR a.currency_code <> v_currency),
         COALESCE(sum(le.amount) FILTER (WHERE le.entry_side = 'debit'), 0),
         COALESCE(sum(le.amount) FILTER (WHERE le.entry_side = 'credit'), 0)
    INTO v_line_count, v_currency_count, v_mismatch_count, v_debits, v_credits
    FROM ledger.ledger_entries AS le
    JOIN ledger.accounts AS a ON a.account_id = le.account_id
   WHERE le.transaction_id = v_transaction_id;

  IF v_line_count < 2 THEN
    RAISE EXCEPTION 'posted journal % must contain at least two lines', v_transaction_id
      USING ERRCODE = '23514';
  END IF;
  IF v_currency_count <> 1 OR v_mismatch_count <> 0 THEN
    RAISE EXCEPTION 'journal % contains inconsistent currencies', v_transaction_id
      USING ERRCODE = '23514';
  END IF;
  IF v_debits <> v_credits THEN
    RAISE EXCEPTION 'journal % is unbalanced: debit %, credit %',
      v_transaction_id, v_debits, v_credits USING ERRCODE = '23514';
  END IF;
  IF v_debits <> v_amount OR v_credits <> v_amount THEN
    RAISE EXCEPTION 'journal % totals must equal transaction amount %',
      v_transaction_id, v_amount USING ERRCODE = '23514';
  END IF;

  RETURN NULL;
END
$function$;

CREATE CONSTRAINT TRIGGER transactions_deferred_journal_check
AFTER INSERT OR UPDATE ON ledger.transactions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ledger.validate_final_journal();

CREATE CONSTRAINT TRIGGER ledger_entries_deferred_journal_check
AFTER INSERT OR UPDATE OR DELETE ON ledger.ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ledger.validate_final_journal();

CREATE FUNCTION ledger.require_finished_idempotency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF NEW.transaction_id IS NULL THEN
    RAISE EXCEPTION 'idempotency key must reference its committed transaction'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END
$function$;

CREATE CONSTRAINT TRIGGER idempotency_key_deferred_result
AFTER INSERT OR UPDATE ON ledger.idempotency_keys
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ledger.require_finished_idempotency();

CREATE FUNCTION ledger.audit_transaction_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  INSERT INTO ledger.audit_logs (
    entity_type, entity_id, transaction_id, account_id, action, details
  ) VALUES (
    'transaction', NEW.transaction_id, NEW.transaction_id, NULL,
    CASE WHEN TG_OP = 'INSERT' THEN 'transaction_created' ELSE 'transaction_state_changed' END,
    jsonb_build_object(
      'transaction_type', NEW.transaction_type,
      'status', NEW.status,
      'amount', NEW.amount,
      'currency_code', NEW.currency_code,
      'previous_status', CASE WHEN TG_OP = 'UPDATE' THEN OLD.status ELSE NULL END
    )
  );
  RETURN NEW;
END
$function$;

CREATE TRIGGER transactions_audit
AFTER INSERT OR UPDATE ON ledger.transactions
FOR EACH ROW EXECUTE FUNCTION ledger.audit_transaction_change();

CREATE FUNCTION ledger.audit_ledger_entry()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  INSERT INTO ledger.audit_logs (
    entity_type, entity_id, transaction_id, account_id, action, details
  ) VALUES (
    'ledger_entry', NEW.ledger_entry_id, NEW.transaction_id, NEW.account_id,
    'ledger_entry_appended',
    jsonb_build_object('entry_side', NEW.entry_side, 'amount', NEW.amount,
                       'currency_code', NEW.currency_code)
  );
  RETURN NEW;
END
$function$;

CREATE TRIGGER ledger_entries_audit
AFTER INSERT ON ledger.ledger_entries
FOR EACH ROW EXECUTE FUNCTION ledger.audit_ledger_entry();

CREATE FUNCTION ledger.guard_audit_log()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'audit history is append-only'
    USING ERRCODE = '55000';
END
$function$;

CREATE TRIGGER audit_logs_immutable
BEFORE UPDATE OR DELETE ON ledger.audit_logs
FOR EACH ROW EXECUTE FUNCTION ledger.guard_audit_log();

REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ledger FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC;
