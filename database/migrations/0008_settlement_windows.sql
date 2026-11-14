-- Purpose: scope internal settlement candidates to an explicit event window.

ALTER TABLE ledger.settlement_batches
  ADD COLUMN window_start timestamptz,
  ADD COLUMN window_end timestamptz;
UPDATE ledger.settlement_batches
   SET window_start = statement_date::timestamp AT TIME ZONE 'UTC',
       window_end = (statement_date + 1)::timestamp AT TIME ZONE 'UTC';
ALTER TABLE ledger.settlement_batches
  ALTER COLUMN window_start SET NOT NULL,
  ALTER COLUMN window_end SET NOT NULL,
  ADD CONSTRAINT settlement_batches_window_ck CHECK (window_end > window_start);

CREATE OR REPLACE FUNCTION ledger.guard_settlement_batch_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF ROW(NEW.external_batch_ref, NEW.source_name, NEW.statement_date,
         NEW.window_start, NEW.window_end, NEW.currency_code, NEW.imported_at)
     IS DISTINCT FROM
     ROW(OLD.external_batch_ref, OLD.source_name, OLD.statement_date,
         OLD.window_start, OLD.window_end, OLD.currency_code, OLD.imported_at) THEN
    RAISE EXCEPTION 'settlement batch identity, window, and statement data are immutable'
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

DROP FUNCTION ledger.create_settlement_batch(text, text, date, text);

CREATE FUNCTION ledger.create_settlement_batch(
  p_external_batch_ref text,
  p_source_name text,
  p_statement_date date,
  p_window_start timestamptz,
  p_window_end timestamptz,
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
  v_existing_start timestamptz;
  v_existing_end timestamptz;
  v_existing_currency text;
BEGIN
  IF p_window_start IS NULL OR p_window_end IS NULL
     OR p_window_end <= p_window_start THEN
    RAISE EXCEPTION 'settlement window end must be after its start'
      USING ERRCODE = '22023';
  END IF;
  INSERT INTO ledger.settlement_batches (
    external_batch_ref, source_name, statement_date,
    window_start, window_end, currency_code
  ) VALUES (
    p_external_batch_ref, p_source_name, p_statement_date,
    p_window_start, p_window_end, p_currency_code
  ) ON CONFLICT (external_batch_ref) DO NOTHING
  RETURNING settlement_batch_id INTO v_batch_id;
  IF v_batch_id IS NOT NULL THEN
    RETURN v_batch_id;
  END IF;
  SELECT b.settlement_batch_id, b.source_name, b.statement_date,
         b.window_start, b.window_end, b.currency_code
    INTO v_batch_id, v_existing_source, v_existing_date,
         v_existing_start, v_existing_end, v_existing_currency
    FROM ledger.settlement_batches AS b
   WHERE b.external_batch_ref = p_external_batch_ref;
  IF ROW(v_existing_source, v_existing_date, v_existing_start,
         v_existing_end, v_existing_currency)
     IS DISTINCT FROM
     ROW(p_source_name, p_statement_date, p_window_start,
         p_window_end, p_currency_code) THEN
    RAISE EXCEPTION 'external batch reference was reused with different metadata'
      USING ERRCODE = '22023';
  END IF;
  RETURN v_batch_id;
END
$function$;

CREATE OR REPLACE FUNCTION ledger.reconcile_settlement_batch(p_settlement_batch_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_batch_status text;
  v_window_start timestamptz;
  v_window_end timestamptz;
  v_run_number integer;
  v_run_id bigint;
BEGIN
  SELECT b.status, b.window_start, b.window_end
    INTO v_batch_status, v_window_start, v_window_end
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
      JOIN ledger.transactions AS t ON t.transaction_ref = si.internal_reference
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
    JOIN ledger.settlement_items AS si ON si.settlement_item_id = sm.settlement_item_id
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
     AND t.posted_at >= v_window_start
     AND t.posted_at < v_window_end
     AND t.currency_code = (
       SELECT b.currency_code FROM ledger.settlement_batches AS b
        WHERE b.settlement_batch_id = p_settlement_batch_id
     )
     AND NOT EXISTS (
       SELECT 1 FROM ledger.settlement_matches AS sm
        WHERE sm.transaction_id = t.transaction_id
     );

  UPDATE ledger.reconciliation_runs
     SET completed_at = clock_timestamp()
   WHERE reconciliation_run_id = v_run_id;
  IF v_batch_status = 'imported' THEN
    UPDATE ledger.settlement_batches SET status = 'reconciled'
     WHERE settlement_batch_id = p_settlement_batch_id;
  END IF;
  RETURN v_run_id;
END
$function$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.create_settlement_batch(text, text, date, timestamptz, timestamptz, text)
  TO ledgerx_runtime;
