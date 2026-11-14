-- Purpose: independently scan financial invariants and rebuild the balance projection.

CREATE FUNCTION ledger.audit_integrity()
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
     GROUP BY r.original_transaction_id
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
   WHERE eb.account_kind IN ('customer_wallet', 'merchant_wallet')
     AND eb.expected_balance < 0
  UNION ALL
  SELECT 'over_refund', 'transaction', rt.original_transaction_id::text,
         jsonb_build_object(
           'refunded_amount', rt.refunded_amount,
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
      OR refund_tx.status <> 'posted'
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

CREATE PROCEDURE ledger.rebuild_account_balances()
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
       'projection_mismatch', 'projected_negative_wallet'
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
  UPDATE ledger.account_balances AS ab
     SET posted_balance = derived.expected_balance,
         updated_at = clock_timestamp()
    FROM derived
   WHERE ab.account_id = derived.account_id;
  GET DIAGNOSTICS v_account_count = ROW_COUNT;

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
