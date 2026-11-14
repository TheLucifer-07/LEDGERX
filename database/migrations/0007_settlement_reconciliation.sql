-- Purpose: import external statement evidence and reconcile it to posted journals.

ALTER TABLE ledger.settlement_items
  RENAME COLUMN raw_reference TO internal_reference;
ALTER TABLE ledger.reconciliation_results
  DROP CONSTRAINT reconciliation_results_result_type_check;
ALTER TABLE ledger.reconciliation_results
  ADD CONSTRAINT reconciliation_results_result_type_check CHECK (result_type IN (
    'matched', 'missing_internal', 'missing_external', 'amount_mismatch',
    'currency_mismatch', 'transaction_type_mismatch', 'unsettled'
  ));
ALTER TABLE ledger.reconciliation_results
  ADD COLUMN expected_currency_code text REFERENCES ledger.currencies(currency_code),
  ADD COLUMN external_currency_code text REFERENCES ledger.currencies(currency_code),
  ADD COLUMN expected_flow text,
  ADD COLUMN external_flow text;

CREATE FUNCTION ledger.guard_settlement_batch_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF ROW(NEW.external_batch_ref, NEW.source_name, NEW.statement_date, NEW.currency_code,
         NEW.imported_at)
     IS DISTINCT FROM
     ROW(OLD.external_batch_ref, OLD.source_name, OLD.statement_date, OLD.currency_code,
         OLD.imported_at) THEN
    RAISE EXCEPTION 'settlement batch identity and statement data are immutable'
      USING ERRCODE = '55000';
  END IF;
  IF OLD.status = 'importing' AND NEW.status = 'imported'
     AND NEW.closed_at IS NULL THEN
    RETURN NEW;
  ELSIF OLD.status = 'imported' AND NEW.status = 'reconciled'
     AND NEW.closed_at IS NULL THEN
    RETURN NEW;
  ELSIF OLD.status = 'reconciled' AND NEW.status = 'closed'
     AND NEW.closed_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'invalid settlement batch transition: % to %', OLD.status, NEW.status
    USING ERRCODE = '55000';
END
$function$;

CREATE TRIGGER settlement_batches_change_guard
BEFORE UPDATE ON ledger.settlement_batches
FOR EACH ROW EXECUTE FUNCTION ledger.guard_settlement_batch_change();

CREATE FUNCTION ledger.guard_settlement_evidence()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'external settlement evidence is append-only'
      USING ERRCODE = '55000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ledger.settlement_batches AS b
     WHERE b.settlement_batch_id = NEW.settlement_batch_id
       AND b.status = 'importing'
       AND b.currency_code = NEW.currency_code
  ) THEN
    RAISE EXCEPTION 'settlement item must match an importing batch currency'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER settlement_items_evidence_guard
BEFORE INSERT OR UPDATE OR DELETE ON ledger.settlement_items
FOR EACH ROW EXECUTE FUNCTION ledger.guard_settlement_evidence();

CREATE FUNCTION ledger.guard_settlement_match()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'settlement matches are append-only'
      USING ERRCODE = '55000';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM ledger.settlement_items AS si
      JOIN ledger.settlement_batches AS b
        ON b.settlement_batch_id = si.settlement_batch_id
      JOIN ledger.transactions AS t
        ON t.transaction_id = NEW.transaction_id
     WHERE si.settlement_item_id = NEW.settlement_item_id
       AND b.status IN ('imported', 'reconciled')
       AND si.internal_reference = t.transaction_ref
       AND t.transaction_type IN ('capture', 'refund')
       AND t.status = 'posted'
  ) THEN
    RAISE EXCEPTION 'match must link a statement reference to a posted capture or refund'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER settlement_matches_insert_guard
BEFORE INSERT OR UPDATE OR DELETE ON ledger.settlement_matches
FOR EACH ROW EXECUTE FUNCTION ledger.guard_settlement_match();

CREATE FUNCTION ledger.guard_settlement_result()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'reconciliation results are append-only'
    USING ERRCODE = '55000';
END
$function$;

CREATE TRIGGER reconciliation_results_immutable
BEFORE UPDATE OR DELETE ON ledger.reconciliation_results
FOR EACH ROW EXECUTE FUNCTION ledger.guard_settlement_result();

CREATE FUNCTION ledger.audit_settlement_event()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_entity_id bigint;
  v_action text;
  v_details jsonb;
BEGIN
  IF TG_TABLE_NAME = 'settlement_batches' THEN
    v_entity_id := NEW.settlement_batch_id;
    v_action := CASE WHEN TG_OP = 'INSERT' THEN 'settlement_batch_created'
                     ELSE 'settlement_batch_state_changed' END;
    v_details := jsonb_build_object('status', NEW.status,
                                    'external_batch_ref', NEW.external_batch_ref);
  ELSIF TG_TABLE_NAME = 'settlement_items' THEN
    v_entity_id := NEW.settlement_item_id;
    v_action := 'settlement_item_imported';
    v_details := jsonb_build_object('external_ref', NEW.external_ref,
                                    'amount', NEW.external_amount,
                                    'currency_code', NEW.currency_code,
                                    'flow', NEW.flow);
  ELSIF TG_TABLE_NAME = 'settlement_matches' THEN
    v_entity_id := NEW.settlement_match_id;
    v_action := 'settlement_item_matched';
    v_details := jsonb_build_object('settlement_item_id', NEW.settlement_item_id,
                                    'transaction_id', NEW.transaction_id);
  ELSE
    v_entity_id := NEW.reconciliation_run_id;
    v_action := CASE WHEN TG_OP = 'INSERT' THEN 'reconciliation_started'
                     ELSE 'reconciliation_completed' END;
    v_details := jsonb_build_object('settlement_batch_id', NEW.settlement_batch_id,
                                    'run_number', NEW.run_number);
  END IF;
  INSERT INTO ledger.audit_logs (entity_type, entity_id, action, details)
  VALUES (TG_TABLE_NAME, v_entity_id, v_action, v_details);
  RETURN NEW;
END
$function$;

CREATE TRIGGER settlement_batches_audit
AFTER INSERT OR UPDATE ON ledger.settlement_batches
FOR EACH ROW EXECUTE FUNCTION ledger.audit_settlement_event();
CREATE TRIGGER settlement_items_audit
AFTER INSERT ON ledger.settlement_items
FOR EACH ROW EXECUTE FUNCTION ledger.audit_settlement_event();
CREATE TRIGGER settlement_matches_audit
AFTER INSERT ON ledger.settlement_matches
FOR EACH ROW EXECUTE FUNCTION ledger.audit_settlement_event();
CREATE TRIGGER reconciliation_runs_audit
AFTER INSERT OR UPDATE ON ledger.reconciliation_runs
FOR EACH ROW EXECUTE FUNCTION ledger.audit_settlement_event();

CREATE FUNCTION ledger.create_settlement_batch(
  p_external_batch_ref text,
  p_source_name text,
  p_statement_date date,
  p_currency_code text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_batch_id bigint;
  v_existing_source text;
  v_existing_date date;
  v_existing_currency text;
BEGIN
  INSERT INTO ledger.settlement_batches (
    external_batch_ref, source_name, statement_date, currency_code
  ) VALUES (
    p_external_batch_ref, p_source_name, p_statement_date, p_currency_code
  ) ON CONFLICT (external_batch_ref) DO NOTHING
  RETURNING settlement_batch_id INTO v_batch_id;
  IF v_batch_id IS NOT NULL THEN
    RETURN v_batch_id;
  END IF;
  SELECT b.settlement_batch_id, b.source_name, b.statement_date, b.currency_code
    INTO v_batch_id, v_existing_source, v_existing_date, v_existing_currency
    FROM ledger.settlement_batches AS b
   WHERE b.external_batch_ref = p_external_batch_ref;
  IF ROW(v_existing_source, v_existing_date, v_existing_currency)
     IS DISTINCT FROM ROW(p_source_name, p_statement_date, p_currency_code) THEN
    RAISE EXCEPTION 'external batch reference was reused with different metadata'
      USING ERRCODE = '22023';
  END IF;
  RETURN v_batch_id;
END
$function$;

CREATE FUNCTION ledger.import_settlement_item(
  p_settlement_batch_id bigint,
  p_external_ref text,
  p_external_amount numeric,
  p_flow text,
  p_currency_code text,
  p_external_at timestamptz,
  p_internal_reference text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_batch_status text;
  v_batch_currency text;
  v_minor_unit smallint;
  v_item_id bigint;
  v_existing_amount numeric(20,4);
  v_existing_flow text;
  v_existing_currency text;
  v_existing_at timestamptz;
  v_existing_reference text;
BEGIN
  SELECT b.status, b.currency_code
    INTO v_batch_status, v_batch_currency
    FROM ledger.settlement_batches AS b
   WHERE b.settlement_batch_id = p_settlement_batch_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement batch % does not exist', p_settlement_batch_id
      USING ERRCODE = '23503';
  END IF;
  IF v_batch_status <> 'importing' THEN
    RAISE EXCEPTION 'statement items can only be imported into an importing batch'
      USING ERRCODE = '55000';
  END IF;
  IF p_currency_code IS DISTINCT FROM v_batch_currency THEN
    RAISE EXCEPTION 'external item currency must match batch currency'
      USING ERRCODE = '23514';
  END IF;
  IF p_flow NOT IN ('capture', 'refund') THEN
    RAISE EXCEPTION 'external flow must be capture or refund'
      USING ERRCODE = '22023';
  END IF;
  IF p_external_amount IS NULL OR p_external_amount <= 0
     OR p_external_amount >= 10000000000000000 THEN
    RAISE EXCEPTION 'external amount must be positive and fit NUMERIC(20,4)'
      USING ERRCODE = '22003';
  END IF;
  SELECT c.minor_unit INTO v_minor_unit FROM ledger.currencies AS c
   WHERE c.currency_code = p_currency_code AND c.active;
  IF NOT FOUND OR p_external_amount <> trunc(p_external_amount, v_minor_unit)
     OR p_external_amount <> trunc(p_external_amount, 4) THEN
    RAISE EXCEPTION 'external amount has invalid currency precision'
      USING ERRCODE = '22003';
  END IF;

  INSERT INTO ledger.settlement_items (
    settlement_batch_id, external_ref, external_amount, flow,
    currency_code, external_at, internal_reference
  ) VALUES (
    p_settlement_batch_id, p_external_ref, p_external_amount, p_flow,
    p_currency_code, p_external_at, p_internal_reference
  ) ON CONFLICT (settlement_batch_id, external_ref) DO NOTHING
  RETURNING settlement_item_id INTO v_item_id;
  IF v_item_id IS NOT NULL THEN
    RETURN v_item_id;
  END IF;

  SELECT si.settlement_item_id, si.external_amount, si.flow, si.currency_code,
         si.external_at, si.internal_reference
    INTO v_item_id, v_existing_amount, v_existing_flow, v_existing_currency,
         v_existing_at, v_existing_reference
    FROM ledger.settlement_items AS si
   WHERE si.settlement_batch_id = p_settlement_batch_id
     AND si.external_ref = p_external_ref;
  IF ROW(v_existing_amount, v_existing_flow, v_existing_currency,
         v_existing_at, v_existing_reference)
     IS DISTINCT FROM
     ROW(p_external_amount::numeric(20,4), p_flow, p_currency_code,
         p_external_at, p_internal_reference) THEN
    RAISE EXCEPTION 'external statement row reference was reused with different data'
      USING ERRCODE = '22023';
  END IF;
  RETURN v_item_id;
END
$function$;

CREATE FUNCTION ledger.complete_settlement_import(p_settlement_batch_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_status text;
BEGIN
  SELECT b.status INTO v_status FROM ledger.settlement_batches AS b
   WHERE b.settlement_batch_id = p_settlement_batch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement batch % does not exist', p_settlement_batch_id
      USING ERRCODE = '23503';
  END IF;
  IF v_status = 'imported' OR v_status = 'reconciled' THEN
    RETURN;
  END IF;
  IF v_status <> 'importing' THEN
    RAISE EXCEPTION 'batch cannot complete import from state %', v_status
      USING ERRCODE = '55000';
  END IF;
  UPDATE ledger.settlement_batches
     SET status = 'imported'
   WHERE settlement_batch_id = p_settlement_batch_id;
END
$function$;

CREATE FUNCTION ledger.reconcile_settlement_batch(p_settlement_batch_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_batch_status text;
  v_statement_date date;
  v_batch_currency text;
  v_run_number integer;
  v_run_id bigint;
BEGIN
  SELECT b.status, b.statement_date, b.currency_code
    INTO v_batch_status, v_statement_date, v_batch_currency
    FROM ledger.settlement_batches AS b
   WHERE b.settlement_batch_id = p_settlement_batch_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement batch % does not exist', p_settlement_batch_id
      USING ERRCODE = '23503';
  END IF;
  IF v_batch_status NOT IN ('imported', 'reconciled', 'closed') THEN
    RAISE EXCEPTION 'batch must be imported before reconciliation'
      USING ERRCODE = '55000';
  END IF;

  SELECT COALESCE(max(r.run_number), 0) + 1 INTO v_run_number
    FROM ledger.reconciliation_runs AS r
   WHERE r.settlement_batch_id = p_settlement_batch_id;
  INSERT INTO ledger.reconciliation_runs (settlement_batch_id, run_number)
  VALUES (p_settlement_batch_id, v_run_number)
  RETURNING reconciliation_run_id INTO v_run_id;

  IF v_batch_status <> 'closed' THEN
    INSERT INTO ledger.settlement_matches (settlement_item_id, transaction_id)
    SELECT si.settlement_item_id, t.transaction_id
      FROM ledger.settlement_items AS si
      JOIN ledger.transactions AS t
        ON t.transaction_ref = si.internal_reference
     WHERE si.settlement_batch_id = p_settlement_batch_id
       AND t.status = 'posted'
       AND t.transaction_type IN ('capture', 'refund')
       AND NOT EXISTS (
         SELECT 1 FROM ledger.settlement_matches AS sm
          WHERE sm.settlement_item_id = si.settlement_item_id
             OR sm.transaction_id = t.transaction_id
       )
     ORDER BY si.settlement_item_id
    ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO ledger.reconciliation_results (
    reconciliation_run_id, settlement_item_id, transaction_id, result_type,
    expected_amount, external_amount, expected_currency_code,
    external_currency_code, expected_flow, external_flow
  )
  SELECT v_run_id, si.settlement_item_id, t.transaction_id,
         CASE
           WHEN t.currency_code <> si.currency_code THEN 'currency_mismatch'
           WHEN t.transaction_type <> si.flow THEN 'transaction_type_mismatch'
           WHEN t.amount <> si.external_amount THEN 'amount_mismatch'
           ELSE 'matched'
         END,
         t.amount, si.external_amount, t.currency_code, si.currency_code,
         t.transaction_type, si.flow
    FROM ledger.settlement_matches AS sm
    JOIN ledger.settlement_items AS si
      ON si.settlement_item_id = sm.settlement_item_id
    JOIN ledger.transactions AS t ON t.transaction_id = sm.transaction_id
   WHERE si.settlement_batch_id = p_settlement_batch_id;

  INSERT INTO ledger.reconciliation_results (
    reconciliation_run_id, settlement_item_id, transaction_id, result_type,
    expected_amount, external_amount, expected_currency_code,
    external_currency_code, expected_flow, external_flow
  )
  SELECT v_run_id, si.settlement_item_id, NULL, 'missing_internal',
         NULL, si.external_amount, NULL, si.currency_code, NULL, si.flow
    FROM ledger.settlement_items AS si
   WHERE si.settlement_batch_id = p_settlement_batch_id
     AND NOT EXISTS (
       SELECT 1 FROM ledger.settlement_matches AS sm
        WHERE sm.settlement_item_id = si.settlement_item_id
     );

  INSERT INTO ledger.reconciliation_results (
    reconciliation_run_id, settlement_item_id, transaction_id, result_type,
    expected_amount, external_amount, expected_currency_code,
    external_currency_code, expected_flow, external_flow
  )
  SELECT v_run_id, NULL, t.transaction_id, 'missing_external',
         t.amount, NULL, t.currency_code, NULL, t.transaction_type, NULL
    FROM ledger.transactions AS t
   WHERE t.status = 'posted'
     AND t.transaction_type IN ('capture', 'refund')
     AND t.posted_at::date <= v_statement_date
     AND t.currency_code = v_batch_currency
     AND NOT EXISTS (
       SELECT 1 FROM ledger.settlement_matches AS sm
        WHERE sm.transaction_id = t.transaction_id
     );

  UPDATE ledger.reconciliation_runs
     SET completed_at = clock_timestamp()
   WHERE reconciliation_run_id = v_run_id;
  IF v_batch_status = 'imported' THEN
    UPDATE ledger.settlement_batches
       SET status = 'reconciled'
     WHERE settlement_batch_id = p_settlement_batch_id;
  END IF;
  RETURN v_run_id;
END
$function$;

CREATE FUNCTION ledger.close_settlement_batch(p_settlement_batch_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_status text;
  v_run_id bigint;
BEGIN
  SELECT b.status INTO v_status FROM ledger.settlement_batches AS b
   WHERE b.settlement_batch_id = p_settlement_batch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement batch % does not exist', p_settlement_batch_id
      USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'reconciled' THEN
    RAISE EXCEPTION 'only a reconciled batch can be closed'
      USING ERRCODE = '55000';
  END IF;
  SELECT r.reconciliation_run_id INTO v_run_id
    FROM ledger.reconciliation_runs AS r
   WHERE r.settlement_batch_id = p_settlement_batch_id
   ORDER BY r.run_number DESC LIMIT 1;
  IF v_run_id IS NULL OR EXISTS (
    SELECT 1 FROM ledger.reconciliation_results AS rr
     WHERE rr.reconciliation_run_id = v_run_id
       AND rr.result_type <> 'matched'
  ) THEN
    RAISE EXCEPTION 'batch cannot close while its latest run has exceptions'
      USING ERRCODE = '23514';
  END IF;
  UPDATE ledger.settlement_batches
     SET status = 'closed', closed_at = clock_timestamp()
   WHERE settlement_batch_id = p_settlement_batch_id;
END
$function$;

CREATE FUNCTION ledger.prevent_reversal_after_settlement()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF OLD.status = 'posted' AND NEW.status = 'reversed'
     AND EXISTS (
       SELECT 1 FROM ledger.settlement_matches AS sm
        WHERE sm.transaction_id = OLD.transaction_id
     ) THEN
    RAISE EXCEPTION 'a settled transaction cannot be reversed'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER transactions_settlement_reversal_guard
BEFORE UPDATE OF status ON ledger.transactions
FOR EACH ROW EXECUTE FUNCTION ledger.prevent_reversal_after_settlement();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.create_settlement_batch(text, text, date, text)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.import_settlement_item(bigint, text, numeric, text, text, timestamptz, text)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.complete_settlement_import(bigint)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.reconcile_settlement_batch(bigint)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.close_settlement_batch(bigint)
  TO ledgerx_runtime;
