-- Purpose: validate the final idempotency row, not a queued trigger row image.
CREATE OR REPLACE FUNCTION ledger.require_finished_idempotency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_transaction_id bigint;
  v_transaction_status text;
BEGIN
  SELECT ik.transaction_id, t.status
    INTO v_transaction_id, v_transaction_status
    FROM ledger.idempotency_keys AS ik
    LEFT JOIN ledger.transactions AS t
      ON t.transaction_id = ik.transaction_id
   WHERE ik.idempotency_id = NEW.idempotency_id;

  IF NOT FOUND OR v_transaction_id IS NULL
     OR v_transaction_status NOT IN ('posted', 'reversed') THEN
    RAISE EXCEPTION 'idempotency key must reference a completed transaction'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END
$function$;
