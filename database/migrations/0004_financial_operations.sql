-- Purpose: implement caller-transaction-scoped, idempotent financial operations.

CREATE FUNCTION ledger.post_financial_operation(
  p_transaction_type text,
  p_scope text,
  p_idempotency_key text,
  p_source_account_id bigint,
  p_destination_account_id bigint,
  p_amount numeric,
  p_currency_code text,
  p_request_reference text,
  p_original_transaction_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_hash text;
  v_payload text;
  v_idempotency_id bigint;
  v_existing_hash text;
  v_existing_transaction_id bigint;
  v_transaction_id bigint;
  v_original_status text;
  v_original_type text;
  v_original_amount numeric(20,4);
  v_original_currency text;
  v_original_source bigint;
  v_original_destination bigint;
  v_refunded_amount numeric(20,4);
  v_minor_unit smallint;
  v_source_kind text;
  v_destination_kind text;
  v_source_status text;
  v_destination_status text;
  v_source_currency text;
  v_destination_currency text;
  v_source_customer_status text;
  v_destination_customer_status text;
  v_locked_count bigint;
  v_account_id bigint;
  v_available numeric(20,4);
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'LedgerX operations require READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;
  IF p_transaction_type NOT IN (
      'deposit', 'withdrawal', 'transfer', 'capture', 'refund', 'reversal'
  ) THEN
    RAISE EXCEPTION 'unsupported transaction type: %', p_transaction_type
      USING ERRCODE = '22023';
  END IF;
  IF p_scope IS NULL OR length(btrim(p_scope)) = 0
     OR p_idempotency_key IS NULL
     OR length(p_idempotency_key) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'scope and a 1-200 character idempotency key are required'
      USING ERRCODE = '22023';
  END IF;

  v_payload := jsonb_build_object(
    'transaction_type', p_transaction_type,
    'source_account_id', p_source_account_id,
    'destination_account_id', p_destination_account_id,
    'amount', CASE WHEN p_amount IS NULL THEN NULL ELSE trim_scale(p_amount)::text END,
    'currency_code', p_currency_code,
    'request_reference', p_request_reference,
    'original_transaction_id', p_original_transaction_id
  )::text;
  v_hash := encode(sha256(convert_to(v_payload, 'UTF8')), 'hex');

  INSERT INTO ledger.idempotency_keys (
    scope, idempotency_key, payload_hash
  ) VALUES (
    p_scope, p_idempotency_key, v_hash
  )
  ON CONFLICT (scope, idempotency_key) DO NOTHING
  RETURNING idempotency_id INTO v_idempotency_id;

  IF v_idempotency_id IS NULL THEN
    SELECT ik.payload_hash, ik.transaction_id
      INTO v_existing_hash, v_existing_transaction_id
      FROM ledger.idempotency_keys AS ik
     WHERE ik.scope = p_scope AND ik.idempotency_key = p_idempotency_key;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'idempotency conflict was not visible after unique-key wait'
        USING ERRCODE = '40001';
    END IF;
    IF v_existing_hash <> v_hash THEN
      RAISE EXCEPTION 'idempotency key was reused with a different request payload'
        USING ERRCODE = '22023';
    END IF;
    IF v_existing_transaction_id IS NULL THEN
      RAISE EXCEPTION 'committed idempotency key has no transaction result'
        USING ERRCODE = '23514';
    END IF;
    RETURN v_existing_transaction_id;
  END IF;

  IF p_transaction_type = 'refund' OR p_transaction_type = 'reversal' THEN
    IF p_original_transaction_id IS NULL THEN
      RAISE EXCEPTION '% requires an original transaction', p_transaction_type
        USING ERRCODE = '22023';
    END IF;
    SELECT t.status, t.transaction_type, t.amount, t.currency_code,
           t.source_account_id, t.destination_account_id
      INTO v_original_status, v_original_type, v_original_amount,
           v_original_currency, v_original_source, v_original_destination
      FROM ledger.transactions AS t
     WHERE t.transaction_id = p_original_transaction_id
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'original transaction % does not exist', p_original_transaction_id
        USING ERRCODE = '23503';
    END IF;
    IF p_transaction_type = 'reversal' AND EXISTS (
      SELECT 1 FROM ledger.transactions AS t
       WHERE t.reversal_of_transaction_id = p_original_transaction_id
    ) THEN
      RAISE EXCEPTION 'transaction % already has a full reversal',
        p_original_transaction_id USING ERRCODE = '23505';
    END IF;
    IF v_original_status <> 'posted' THEN
      RAISE EXCEPTION 'only a posted transaction can be compensated'
        USING ERRCODE = '23514';
    END IF;

    IF p_transaction_type = 'refund' THEN
      IF v_original_type <> 'capture' THEN
        RAISE EXCEPTION 'refunds are allowed only for posted captures'
          USING ERRCODE = '23514';
      END IF;
      IF p_amount IS NULL OR p_amount <= 0
         OR p_amount >= 10000000000000000 THEN
        RAISE EXCEPTION 'refund amount is outside the supported positive range'
          USING ERRCODE = '22003';
      END IF;
      IF p_currency_code IS NOT NULL
         AND p_currency_code IS DISTINCT FROM v_original_currency THEN
        RAISE EXCEPTION 'refund currency must match capture currency'
          USING ERRCODE = '23514';
      END IF;
      SELECT c.minor_unit INTO v_minor_unit
        FROM ledger.currencies AS c
       WHERE c.currency_code = v_original_currency AND c.active;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'capture currency is not active'
          USING ERRCODE = '23514';
      END IF;
      IF p_amount <> trunc(p_amount, v_minor_unit)
         OR p_amount <> trunc(p_amount, 4) THEN
        RAISE EXCEPTION 'refund amount has more precision than currency % permits',
          v_original_currency USING ERRCODE = '22003';
      END IF;
      SELECT COALESCE(sum(r.amount), 0)
        INTO v_refunded_amount
        FROM ledger.refunds AS r
       WHERE r.original_transaction_id = p_original_transaction_id;
      IF v_refunded_amount + p_amount > v_original_amount THEN
        RAISE EXCEPTION 'refund total % would exceed capture amount %',
          v_refunded_amount + p_amount, v_original_amount USING ERRCODE = '23514';
      END IF;
      p_source_account_id := v_original_destination;
      p_destination_account_id := v_original_source;
      p_currency_code := v_original_currency;
    ELSE
      IF v_original_type = 'capture' AND EXISTS (
        SELECT 1 FROM ledger.refunds AS r
         WHERE r.original_transaction_id = p_original_transaction_id
      ) THEN
        RAISE EXCEPTION 'a capture with a posted refund cannot be fully reversed'
          USING ERRCODE = '23514';
      END IF;
      p_amount := v_original_amount;
      p_currency_code := v_original_currency;
      p_source_account_id := v_original_destination;
      p_destination_account_id := v_original_source;
    END IF;
  ELSIF p_original_transaction_id IS NOT NULL THEN
    RAISE EXCEPTION 'original transaction is only valid for refund or reversal'
      USING ERRCODE = '22023';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0
     OR p_amount >= 10000000000000000 THEN
    RAISE EXCEPTION 'amount must be positive and fit NUMERIC(20,4)'
      USING ERRCODE = '22003';
  END IF;
  IF p_source_account_id IS NULL OR p_destination_account_id IS NULL
     OR p_source_account_id = p_destination_account_id THEN
    RAISE EXCEPTION 'two distinct source and destination accounts are required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.minor_unit INTO v_minor_unit
    FROM ledger.currencies AS c
   WHERE c.currency_code = p_currency_code AND c.active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'currency % does not exist or is inactive', p_currency_code
      USING ERRCODE = '23514';
  END IF;
  IF p_amount <> trunc(p_amount, v_minor_unit)
     OR p_amount <> trunc(p_amount, 4) THEN
    RAISE EXCEPTION 'amount has more precision than currency % permits',
      p_currency_code USING ERRCODE = '22003';
  END IF;

  PERFORM a.account_id
    FROM ledger.accounts AS a
   WHERE a.account_id IN (p_source_account_id, p_destination_account_id)
   ORDER BY a.account_id
   FOR UPDATE;
  GET DIAGNOSTICS v_locked_count = ROW_COUNT;
  IF v_locked_count <> 2 THEN
    RAISE EXCEPTION 'source or destination account does not exist'
      USING ERRCODE = '23503';
  END IF;

  SELECT a.account_kind, a.status, a.currency_code, c.status
    INTO v_source_kind, v_source_status, v_source_currency, v_source_customer_status
    FROM ledger.accounts AS a
    LEFT JOIN ledger.customers AS c ON c.customer_id = a.customer_id
   WHERE a.account_id = p_source_account_id;
  SELECT a.account_kind, a.status, a.currency_code, c.status
    INTO v_destination_kind, v_destination_status,
         v_destination_currency, v_destination_customer_status
    FROM ledger.accounts AS a
    LEFT JOIN ledger.customers AS c ON c.customer_id = a.customer_id
   WHERE a.account_id = p_destination_account_id;

  IF v_source_status <> 'open' OR v_destination_status <> 'open'
     OR COALESCE(v_source_customer_status, 'active') <> 'active'
     OR COALESCE(v_destination_customer_status, 'active') <> 'active' THEN
    RAISE EXCEPTION 'both accounts and their owners must be active'
      USING ERRCODE = '23514';
  END IF;
  IF v_source_currency <> p_currency_code
     OR v_destination_currency <> p_currency_code THEN
    RAISE EXCEPTION 'both account currencies must match transaction currency'
      USING ERRCODE = '23514';
  END IF;

  IF (p_transaction_type = 'deposit'
        AND (v_source_kind <> 'funding_clearing'
             OR v_destination_kind <> 'customer_wallet'))
     OR (p_transaction_type = 'withdrawal'
        AND (v_source_kind <> 'customer_wallet'
             OR v_destination_kind <> 'payout_clearing'))
     OR (p_transaction_type = 'transfer'
        AND (v_source_kind <> 'customer_wallet'
             OR v_destination_kind <> 'customer_wallet'))
     OR (p_transaction_type = 'capture'
        AND (v_source_kind <> 'customer_wallet'
             OR v_destination_kind <> 'merchant_wallet'))
     OR (p_transaction_type = 'refund'
        AND (v_source_kind <> 'merchant_wallet'
             OR v_destination_kind <> 'customer_wallet')) THEN
    RAISE EXCEPTION 'accounts do not match operation type %', p_transaction_type
      USING ERRCODE = '23514';
  END IF;

  IF p_transaction_type IN ('withdrawal', 'transfer', 'capture', 'refund')
     OR p_transaction_type = 'reversal' THEN
    IF p_transaction_type <> 'reversal' THEN
      SELECT b.posted_balance INTO v_available
        FROM ledger.account_balances AS b
       WHERE b.account_id = p_source_account_id;
      IF v_available < p_amount THEN
        RAISE EXCEPTION 'insufficient available balance in account %',
          p_source_account_id USING ERRCODE = '23514';
      END IF;
    ELSE
      FOR v_account_id IN
        SELECT DISTINCT le.account_id
          FROM ledger.ledger_entries AS le
         WHERE le.transaction_id = p_original_transaction_id
           AND le.entry_side = 'credit'
           AND EXISTS (
             SELECT 1 FROM ledger.accounts AS a
              WHERE a.account_id = le.account_id
                AND a.account_kind IN ('customer_wallet', 'merchant_wallet')
           )
         ORDER BY le.account_id
      LOOP
        SELECT b.posted_balance INTO v_available
          FROM ledger.account_balances AS b
         WHERE b.account_id = v_account_id;
        IF v_available < (
          SELECT sum(le.amount)
            FROM ledger.ledger_entries AS le
           WHERE le.transaction_id = p_original_transaction_id
             AND le.account_id = v_account_id
             AND le.entry_side = 'credit'
        ) THEN
          RAISE EXCEPTION 'insufficient available balance to reverse account %',
            v_account_id USING ERRCODE = '23514';
        END IF;
      END LOOP;
    END IF;
  END IF;

  INSERT INTO ledger.transactions (
    transaction_ref, transaction_type, amount, currency_code,
    source_account_id, destination_account_id,
    reversal_of_transaction_id, request_reference
  ) VALUES (
    'txn_' || gen_random_uuid()::text,
    p_transaction_type, p_amount, p_currency_code,
    p_source_account_id, p_destination_account_id,
    CASE WHEN p_transaction_type = 'reversal'
      THEN p_original_transaction_id ELSE NULL END,
    p_request_reference
  ) RETURNING transaction_id INTO v_transaction_id;

  UPDATE ledger.idempotency_keys
     SET transaction_id = v_transaction_id
   WHERE idempotency_id = v_idempotency_id;

  IF p_transaction_type = 'reversal' THEN
    INSERT INTO ledger.ledger_entries (
      transaction_id, account_id, entry_side, amount, currency_code
    )
    SELECT v_transaction_id, le.account_id,
           CASE le.entry_side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
           le.amount, le.currency_code
      FROM ledger.ledger_entries AS le
     WHERE le.transaction_id = p_original_transaction_id
     ORDER BY le.ledger_entry_id;
  ELSE
    INSERT INTO ledger.ledger_entries (
      transaction_id, account_id, entry_side, amount, currency_code
    ) VALUES
      (v_transaction_id, p_source_account_id, 'debit', p_amount, p_currency_code),
      (v_transaction_id, p_destination_account_id, 'credit', p_amount, p_currency_code);
  END IF;

  UPDATE ledger.transactions
     SET status = 'posted', posted_at = transaction_timestamp()
   WHERE transaction_id = v_transaction_id;

  IF p_transaction_type = 'refund' THEN
    INSERT INTO ledger.refunds (
      original_transaction_id, refund_transaction_id, amount, currency_code
    ) VALUES (
      p_original_transaction_id, v_transaction_id, p_amount, p_currency_code
    );
  ELSIF p_transaction_type = 'reversal' THEN
    UPDATE ledger.transactions
       SET status = 'reversed'
     WHERE transaction_id = p_original_transaction_id;
  END IF;

  RETURN v_transaction_id;
END
$function$;

CREATE FUNCTION ledger.deposit(
  p_scope text, p_idempotency_key text,
  p_funding_account_id bigint, p_wallet_account_id bigint,
  p_amount numeric, p_currency_code text,
  p_request_reference text DEFAULT NULL
)
RETURNS bigint LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT ledger.post_financial_operation(
    'deposit', p_scope, p_idempotency_key, p_funding_account_id,
    p_wallet_account_id, p_amount, p_currency_code, p_request_reference
  )
$function$;

CREATE FUNCTION ledger.withdraw(
  p_scope text, p_idempotency_key text,
  p_wallet_account_id bigint, p_payout_account_id bigint,
  p_amount numeric, p_currency_code text,
  p_request_reference text DEFAULT NULL
)
RETURNS bigint LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT ledger.post_financial_operation(
    'withdrawal', p_scope, p_idempotency_key, p_wallet_account_id,
    p_payout_account_id, p_amount, p_currency_code, p_request_reference
  )
$function$;

CREATE FUNCTION ledger.transfer(
  p_scope text, p_idempotency_key text,
  p_source_wallet_id bigint, p_destination_wallet_id bigint,
  p_amount numeric, p_currency_code text,
  p_request_reference text DEFAULT NULL
)
RETURNS bigint LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT ledger.post_financial_operation(
    'transfer', p_scope, p_idempotency_key, p_source_wallet_id,
    p_destination_wallet_id, p_amount, p_currency_code, p_request_reference
  )
$function$;

CREATE FUNCTION ledger.capture(
  p_scope text, p_idempotency_key text,
  p_customer_wallet_id bigint, p_merchant_wallet_id bigint,
  p_amount numeric, p_currency_code text,
  p_request_reference text DEFAULT NULL
)
RETURNS bigint LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT ledger.post_financial_operation(
    'capture', p_scope, p_idempotency_key, p_customer_wallet_id,
    p_merchant_wallet_id, p_amount, p_currency_code, p_request_reference
  )
$function$;

CREATE FUNCTION ledger.refund_capture(
  p_scope text, p_idempotency_key text,
  p_original_transaction_id bigint, p_amount numeric
)
RETURNS bigint LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT ledger.post_financial_operation(
    'refund', p_scope, p_idempotency_key, NULL, NULL,
    p_amount, NULL, NULL, p_original_transaction_id
  )
$function$;

CREATE FUNCTION ledger.reverse_transaction(
  p_scope text, p_idempotency_key text,
  p_original_transaction_id bigint
)
RETURNS bigint LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT ledger.post_financial_operation(
    'reversal', p_scope, p_idempotency_key, NULL, NULL,
    NULL, NULL, NULL, p_original_transaction_id
  )
$function$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.deposit(text, text, bigint, bigint, numeric, text, text)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.withdraw(text, text, bigint, bigint, numeric, text, text)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.transfer(text, text, bigint, bigint, numeric, text, text)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.capture(text, text, bigint, bigint, numeric, text, text)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.refund_capture(text, text, bigint, numeric)
  TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.reverse_transaction(text, text, bigint)
  TO ledgerx_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA ledger TO ledgerx_runtime;
