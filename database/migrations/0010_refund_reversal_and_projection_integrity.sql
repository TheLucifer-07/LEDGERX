-- Purpose: repair active-refund handling, projection completeness, and reversal auditing.

CREATE FUNCTION ledger.create_account_balance_projection()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  INSERT INTO ledger.account_balances (account_id)
  VALUES (NEW.account_id);
  RETURN NEW;
END
$function$;

CREATE TRIGGER accounts_create_balance_projection
AFTER INSERT ON ledger.accounts
FOR EACH ROW EXECUTE FUNCTION ledger.create_account_balance_projection();

CREATE OR REPLACE FUNCTION ledger.post_financial_operation(
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
    IF p_transaction_type = 'reversal' AND v_original_type = 'reversal' THEN
      RAISE EXCEPTION 'reversing a reversal is not supported'
        USING ERRCODE = '23514';
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
        JOIN ledger.transactions AS refund_tx
          ON refund_tx.transaction_id = r.refund_transaction_id
       WHERE r.original_transaction_id = p_original_transaction_id
         AND refund_tx.status = 'posted';
      IF v_refunded_amount + p_amount > v_original_amount THEN
        RAISE EXCEPTION 'refund total % would exceed capture amount %',
          v_refunded_amount + p_amount, v_original_amount USING ERRCODE = '23514';
      END IF;
      p_source_account_id := v_original_destination;
      p_destination_account_id := v_original_source;
      p_currency_code := v_original_currency;
    ELSE
      IF v_original_type = 'capture' AND EXISTS (
        SELECT 1
          FROM ledger.refunds AS r
          JOIN ledger.transactions AS refund_tx
            ON refund_tx.transaction_id = r.refund_transaction_id
         WHERE r.original_transaction_id = p_original_transaction_id
           AND refund_tx.status = 'posted'
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

CREATE OR REPLACE FUNCTION ledger.audit_integrity()
RETURNS TABLE (
  finding_type text,
  entity_type text,
  entity_id text,
  details jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  WITH journal_totals AS (
    SELECT t.transaction_id,
           t.amount AS transaction_amount,
           t.currency_code AS transaction_currency,
           count(le.ledger_entry_id) AS line_count,
           count(DISTINCT le.currency_code) AS currency_count,
           count(*) FILTER (
             WHERE le.currency_code <> t.currency_code
                OR a.currency_code <> t.currency_code
           ) AS currency_mismatch_count,
           COALESCE(sum(le.amount) FILTER (WHERE le.entry_side = 'debit'), 0) AS debits,
           COALESCE(sum(le.amount) FILTER (WHERE le.entry_side = 'credit'), 0) AS credits
      FROM ledger.transactions AS t
      LEFT JOIN ledger.ledger_entries AS le
        ON le.transaction_id = t.transaction_id
      LEFT JOIN ledger.accounts AS a
        ON a.account_id = le.account_id
     WHERE t.status IN ('posted', 'reversed')
     GROUP BY t.transaction_id
  ), expected_balances AS (
    SELECT a.account_id,
           a.account_kind,
           COALESCE(sum(
             CASE WHEN le.entry_side = a.normal_side
               THEN le.amount ELSE -le.amount END
           ) FILTER (WHERE t.status IN ('posted', 'reversed')), 0)::numeric(20,4)
             AS expected_balance
      FROM ledger.accounts AS a
      LEFT JOIN ledger.ledger_entries AS le ON le.account_id = a.account_id
      LEFT JOIN ledger.transactions AS t ON t.transaction_id = le.transaction_id
     GROUP BY a.account_id, a.account_kind
  ), refund_totals AS (
    SELECT r.original_transaction_id,
           sum(r.amount) AS refunded_amount,
           count(*) AS refund_count
      FROM ledger.refunds AS r
      JOIN ledger.transactions AS refund_tx
        ON refund_tx.transaction_id = r.refund_transaction_id
     WHERE refund_tx.status = 'posted'
     GROUP BY r.original_transaction_id
  ), reversal_pairs AS (
    SELECT reversal.transaction_id AS reversal_id,
           reversal.status AS reversal_status,
           reversal.amount AS reversal_amount,
           reversal.currency_code AS reversal_currency,
           reversal.transaction_type AS reversal_type,
           reversal.reversal_of_transaction_id AS original_id,
           original.transaction_id AS found_original_id,
           original.status AS original_status,
           original.transaction_type AS original_type,
           original.amount AS original_amount,
           original.currency_code AS original_currency
      FROM ledger.transactions AS reversal
      LEFT JOIN ledger.transactions AS original
        ON original.transaction_id = reversal.reversal_of_transaction_id
     WHERE reversal.transaction_type = 'reversal'
  ), original_lines AS (
    SELECT rp.reversal_id,
           le.account_id,
           le.entry_side,
           sum(le.amount) AS amount
      FROM reversal_pairs AS rp
      JOIN ledger.ledger_entries AS le
        ON le.transaction_id = rp.original_id
     GROUP BY rp.reversal_id, le.account_id, le.entry_side
  ), reversal_lines AS (
    SELECT rp.reversal_id,
           le.account_id,
           CASE le.entry_side WHEN 'debit' THEN 'credit' ELSE 'debit' END AS entry_side,
           sum(le.amount) AS amount
      FROM reversal_pairs AS rp
      JOIN ledger.ledger_entries AS le
        ON le.transaction_id = rp.reversal_id
     GROUP BY rp.reversal_id, le.account_id,
              CASE le.entry_side WHEN 'debit' THEN 'credit' ELSE 'debit' END
  ), reversal_line_comparison AS (
    SELECT COALESCE(ol.reversal_id, rl.reversal_id) AS reversal_id,
           COALESCE(ol.account_id, rl.account_id) AS account_id,
           COALESCE(ol.entry_side, rl.entry_side) AS original_entry_side,
           ol.amount AS original_amount,
           rl.amount AS reversing_amount
      FROM original_lines AS ol
      FULL JOIN reversal_lines AS rl
        ON rl.reversal_id = ol.reversal_id
       AND rl.account_id = ol.account_id
       AND rl.entry_side = ol.entry_side
  )
  SELECT 'unbalanced_journal', 'transaction', jt.transaction_id::text,
         jsonb_build_object(
           'line_count', jt.line_count,
           'debits', jt.debits,
           'credits', jt.credits,
           'transaction_amount', jt.transaction_amount
         )
    FROM journal_totals AS jt
   WHERE jt.line_count < 2 OR jt.currency_count <> 1
      OR jt.currency_mismatch_count <> 0
      OR jt.debits <> jt.credits
      OR jt.debits <> jt.transaction_amount
      OR jt.credits <> jt.transaction_amount
  UNION ALL
  SELECT 'currency_mismatch', 'ledger_entry', le.ledger_entry_id::text,
         jsonb_build_object(
           'transaction_currency', t.currency_code,
           'account_currency', a.currency_code,
           'entry_currency', le.currency_code
         )
    FROM ledger.ledger_entries AS le
    JOIN ledger.transactions AS t ON t.transaction_id = le.transaction_id
    JOIN ledger.accounts AS a ON a.account_id = le.account_id
   WHERE le.currency_code <> t.currency_code
      OR le.currency_code <> a.currency_code
  UNION ALL
  SELECT 'projection_mismatch', 'account', eb.account_id::text,
         jsonb_build_object(
           'expected_balance', eb.expected_balance,
           'projected_balance', ab.posted_balance
         )
    FROM expected_balances AS eb
    JOIN ledger.account_balances AS ab USING (account_id)
   WHERE ab.posted_balance IS DISTINCT FROM eb.expected_balance
  UNION ALL
  SELECT 'projection_missing', 'account', eb.account_id::text,
         jsonb_build_object('expected_balance', eb.expected_balance)
    FROM expected_balances AS eb
    LEFT JOIN ledger.account_balances AS ab USING (account_id)
   WHERE ab.account_id IS NULL
  UNION ALL
  SELECT 'projected_negative_wallet', 'account', ab.account_id::text,
         jsonb_build_object('posted_balance', ab.posted_balance)
    FROM ledger.account_balances AS ab
    JOIN ledger.accounts AS a USING (account_id)
   WHERE a.account_kind IN ('customer_wallet', 'merchant_wallet')
     AND ab.posted_balance < 0
  UNION ALL
  SELECT 'ledger_negative_wallet', 'account', eb.account_id::text,
         jsonb_build_object('expected_balance', eb.expected_balance)
    FROM expected_balances AS eb
    JOIN ledger.accounts AS a USING (account_id)
   WHERE a.account_kind IN ('customer_wallet', 'merchant_wallet')
     AND eb.expected_balance < 0
  UNION ALL
  SELECT 'over_refund', 'transaction', rt.original_transaction_id::text,
         jsonb_build_object(
           'active_refunded_amount', rt.refunded_amount,
           'active_refund_count', rt.refund_count,
           'capture_amount', t.amount
         )
    FROM refund_totals AS rt
    JOIN ledger.transactions AS t
      ON t.transaction_id = rt.original_transaction_id
   WHERE rt.refunded_amount > t.amount
  UNION ALL
  SELECT 'invalid_refund', 'refund', r.refund_id::text,
         jsonb_build_object(
           'original_type', original.transaction_type,
           'refund_type', refund_tx.transaction_type,
           'refund_status', refund_tx.status,
           'refund_amount', r.amount,
           'transaction_amount', refund_tx.amount,
           'refund_currency', r.currency_code,
           'original_currency', original.currency_code
         )
    FROM ledger.refunds AS r
    JOIN ledger.transactions AS original
      ON original.transaction_id = r.original_transaction_id
    JOIN ledger.transactions AS refund_tx
      ON refund_tx.transaction_id = r.refund_transaction_id
   WHERE original.transaction_type <> 'capture'
      OR refund_tx.transaction_type <> 'refund'
      OR refund_tx.status NOT IN ('posted', 'reversed')
      OR r.amount <> refund_tx.amount
      OR r.currency_code <> original.currency_code
      OR r.currency_code <> refund_tx.currency_code
  UNION ALL
  SELECT 'duplicate_reversal', 'transaction', grouped.original_id::text,
         jsonb_build_object('reversal_count', grouped.reversal_count)
    FROM (
      SELECT t.reversal_of_transaction_id AS original_id, count(*) AS reversal_count
        FROM ledger.transactions AS t
       WHERE t.reversal_of_transaction_id IS NOT NULL
       GROUP BY t.reversal_of_transaction_id
      HAVING count(*) > 1
    ) AS grouped
  UNION ALL
  SELECT 'invalid_reversal_header', 'transaction', rp.reversal_id::text,
         jsonb_build_object(
           'original_transaction_id', rp.original_id,
           'original_found', rp.found_original_id IS NOT NULL,
           'original_type', rp.original_type,
           'original_status', rp.original_status,
           'original_amount', rp.original_amount,
           'reversal_status', rp.reversal_status,
           'reversal_amount', rp.reversal_amount,
           'original_currency', rp.original_currency,
           'reversal_currency', rp.reversal_currency
         )
    FROM reversal_pairs AS rp
   WHERE rp.found_original_id IS NULL
      OR rp.original_type = 'reversal'
      OR rp.original_status <> 'reversed'
      OR rp.reversal_status <> 'posted'
      OR rp.original_amount IS DISTINCT FROM rp.reversal_amount
      OR rp.original_currency IS DISTINCT FROM rp.reversal_currency
  UNION ALL
  SELECT 'reversal_journal_mismatch', 'transaction', rlc.reversal_id::text,
         jsonb_build_object(
           'account_id', rlc.account_id,
           'original_entry_side', rlc.original_entry_side,
           'original_amount', rlc.original_amount,
           'reversing_amount', rlc.reversing_amount
         )
    FROM reversal_line_comparison AS rlc
   WHERE rlc.original_amount IS DISTINCT FROM rlc.reversing_amount
  UNION ALL
  SELECT 'invalid_transaction_state', 'transaction', t.transaction_id::text,
         jsonb_build_object(
           'transaction_type', t.transaction_type,
           'status', t.status,
           'posted_at', t.posted_at,
           'reversal_of_transaction_id', t.reversal_of_transaction_id
         )
    FROM ledger.transactions AS t
   WHERE t.status = 'pending'
      OR (t.status = 'reversed' AND NOT EXISTS (
            SELECT 1 FROM ledger.transactions AS r
             WHERE r.reversal_of_transaction_id = t.transaction_id
                AND r.transaction_type = 'reversal'
                AND r.status = 'posted'
          ))
      OR (t.transaction_type = 'reversal' AND (
            t.status <> 'posted'
            OR NOT EXISTS (
              SELECT 1 FROM ledger.transactions AS original
               WHERE original.transaction_id = t.reversal_of_transaction_id
                 AND original.status = 'reversed'
                 AND original.amount = t.amount
                 AND original.currency_code = t.currency_code
            )
          ))
$function$;

CREATE OR REPLACE PROCEDURE ledger.rebuild_account_balances()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $procedure$
DECLARE
  v_account_count bigint;
BEGIN
  PERFORM a.account_id
    FROM ledger.accounts AS a
   ORDER BY a.account_id
   FOR UPDATE;

  IF EXISTS (
    SELECT 1 FROM ledger.audit_integrity() AS finding
     WHERE finding.finding_type NOT IN (
       'projection_mismatch', 'projection_missing', 'projected_negative_wallet'
     )
  ) THEN
    RAISE EXCEPTION 'cannot rebuild projection while ledger integrity findings exist'
      USING ERRCODE = '23514';
  END IF;

  WITH derived AS (
    SELECT a.account_id,
           COALESCE(sum(
             CASE WHEN le.entry_side = a.normal_side
               THEN le.amount ELSE -le.amount END
           ) FILTER (WHERE t.status IN ('posted', 'reversed')), 0)::numeric(20,4)
             AS expected_balance
      FROM ledger.accounts AS a
      LEFT JOIN ledger.ledger_entries AS le ON le.account_id = a.account_id
      LEFT JOIN ledger.transactions AS t ON t.transaction_id = le.transaction_id
     GROUP BY a.account_id, a.normal_side
  )
  INSERT INTO ledger.account_balances (account_id, posted_balance, updated_at)
  SELECT derived.account_id, derived.expected_balance, clock_timestamp()
    FROM derived
  ON CONFLICT (account_id) DO UPDATE
    SET posted_balance = EXCLUDED.posted_balance,
        updated_at = EXCLUDED.updated_at;
  GET DIAGNOSTICS v_account_count = ROW_COUNT;

  IF EXISTS (SELECT 1 FROM ledger.audit_integrity()) THEN
    RAISE EXCEPTION 'projection rebuild verification failed'
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO ledger.audit_logs (
    entity_type, entity_id, action, details
  ) VALUES (
    'account_balance_projection', 0, 'balance_projection_rebuilt',
    jsonb_build_object('accounts_rebuilt', v_account_count)
  );
END
$procedure$;

REVOKE ALL ON FUNCTION ledger.audit_integrity() FROM PUBLIC;
REVOKE ALL ON PROCEDURE ledger.rebuild_account_balances() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.audit_integrity() TO ledgerx_runtime;

INSERT INTO ledger.account_balances (account_id)
SELECT a.account_id
  FROM ledger.accounts AS a
ON CONFLICT (account_id) DO NOTHING;

CREATE OR REPLACE VIEW ledger.v_refund_analysis AS
SELECT capture.transaction_id AS capture_transaction_id,
       capture.transaction_ref AS capture_reference,
       capture.currency_code,
       capture.amount AS captured_amount,
       count(refund.refund_id) FILTER (WHERE refund_tx.status = 'posted') AS refund_count,
       COALESCE(sum(refund.amount) FILTER (WHERE refund_tx.status = 'posted'),
                0)::numeric(20,4) AS refunded_amount,
       CASE WHEN capture.status = 'reversed' THEN 0::numeric(20,4)
            ELSE capture.amount - COALESCE(
              sum(refund.amount) FILTER (WHERE refund_tx.status = 'posted'), 0
            )
       END AS remaining_refundable_amount,
       capture.status AS capture_status,
       count(refund.refund_id) AS historical_refund_count,
       COALESCE(sum(refund.amount), 0)::numeric(20,4) AS historical_refund_amount,
       count(refund.refund_id) FILTER (WHERE refund_tx.status = 'reversed')
         AS reversed_refund_count
  FROM ledger.transactions AS capture
  LEFT JOIN ledger.refunds AS refund
    ON refund.original_transaction_id = capture.transaction_id
  LEFT JOIN ledger.transactions AS refund_tx
    ON refund_tx.transaction_id = refund.refund_transaction_id
 WHERE capture.transaction_type = 'capture'
 GROUP BY capture.transaction_id, capture.transaction_ref, capture.currency_code,
          capture.amount, capture.status;

CREATE VIEW ledger.v_refund_history AS
SELECT refund.refund_id,
       refund.original_transaction_id AS capture_transaction_id,
       capture.transaction_ref AS capture_reference,
       refund.refund_transaction_id,
       refund_tx.transaction_ref AS refund_reference,
       refund_tx.status AS refund_status,
       reversal.transaction_id AS reversal_transaction_id,
       reversal.transaction_ref AS reversal_reference,
       refund.amount,
       refund.currency_code,
       refund.created_at
  FROM ledger.refunds AS refund
  JOIN ledger.transactions AS capture
    ON capture.transaction_id = refund.original_transaction_id
  JOIN ledger.transactions AS refund_tx
    ON refund_tx.transaction_id = refund.refund_transaction_id
  LEFT JOIN ledger.transactions AS reversal
    ON reversal.reversal_of_transaction_id = refund.refund_transaction_id
   AND reversal.transaction_type = 'reversal';

GRANT SELECT ON ledger.v_refund_history TO ledgerx_runtime;
