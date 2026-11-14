-- Purpose: expose useful, read-only summaries over the authoritative records.

CREATE VIEW ledger.v_daily_transaction_volume AS
SELECT (t.posted_at AT TIME ZONE 'UTC')::date AS transaction_date,
       t.currency_code,
       t.transaction_type,
       count(*) AS transaction_count,
       count(*) FILTER (WHERE t.status = 'posted') AS posted_count,
       count(*) FILTER (WHERE t.status = 'reversed') AS reversed_count,
       sum(t.amount) AS gross_amount
  FROM ledger.transactions AS t
 WHERE t.status IN ('posted', 'reversed')
 GROUP BY (t.posted_at AT TIME ZONE 'UTC')::date,
          t.currency_code, t.transaction_type;

CREATE VIEW ledger.v_monthly_transaction_summary AS
SELECT date_trunc('month', t.posted_at AT TIME ZONE 'UTC')::date AS month_start,
       t.currency_code,
       t.transaction_type,
       count(*) AS transaction_count,
       sum(t.amount) AS gross_amount,
       count(*) FILTER (WHERE t.status = 'reversed') AS reversed_original_count
  FROM ledger.transactions AS t
 WHERE t.status IN ('posted', 'reversed')
 GROUP BY date_trunc('month', t.posted_at AT TIME ZONE 'UTC')::date,
          t.currency_code, t.transaction_type;

CREATE VIEW ledger.v_monthly_transaction_rank AS
WITH volume_by_type AS (
  SELECT date_trunc('month', t.posted_at AT TIME ZONE 'UTC')::date AS month_start,
         t.currency_code,
         t.transaction_type,
         count(*) AS transaction_count,
         sum(t.amount) AS gross_amount
    FROM ledger.transactions AS t
   WHERE t.status IN ('posted', 'reversed')
   GROUP BY date_trunc('month', t.posted_at AT TIME ZONE 'UTC')::date,
            t.currency_code, t.transaction_type
)
SELECT month_start,
       currency_code,
       transaction_type,
       transaction_count,
       gross_amount,
       rank() OVER (
         PARTITION BY month_start, currency_code ORDER BY gross_amount DESC
       ) AS gross_amount_rank,
       dense_rank() OVER (
         PARTITION BY month_start, currency_code ORDER BY transaction_count DESC
       ) AS transaction_count_rank
  FROM volume_by_type;

CREATE VIEW ledger.v_account_activity AS
SELECT a.account_id,
       a.account_code,
       a.account_kind,
       a.currency_code,
       t.transaction_id,
       t.transaction_ref,
       t.transaction_type,
       t.status AS transaction_status,
       le.ledger_entry_id,
       le.entry_side,
       le.amount,
       CASE WHEN le.entry_side = a.normal_side THEN le.amount ELSE -le.amount END
         AS normalized_delta,
       t.posted_at,
       sum(CASE WHEN le.entry_side = a.normal_side
                THEN le.amount ELSE -le.amount END)
         OVER (
           PARTITION BY a.account_id
           ORDER BY t.posted_at, le.ledger_entry_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
         ) AS running_normal_balance
  FROM ledger.ledger_entries AS le
  JOIN ledger.accounts AS a ON a.account_id = le.account_id
  JOIN ledger.transactions AS t ON t.transaction_id = le.transaction_id
 WHERE t.status IN ('posted', 'reversed');

CREATE VIEW ledger.v_refund_analysis AS
SELECT capture.transaction_id AS capture_transaction_id,
       capture.transaction_ref AS capture_reference,
       capture.currency_code,
       capture.amount AS captured_amount,
       count(refund.refund_id) AS refund_count,
       COALESCE(sum(refund.amount), 0)::numeric(20,4) AS refunded_amount,
       CASE WHEN capture.status = 'reversed' THEN 0::numeric(20,4)
            ELSE capture.amount - COALESCE(sum(refund.amount), 0)
       END AS remaining_refundable_amount,
       capture.status AS capture_status
  FROM ledger.transactions AS capture
  LEFT JOIN ledger.refunds AS refund
    ON refund.original_transaction_id = capture.transaction_id
 WHERE capture.transaction_type = 'capture'
 GROUP BY capture.transaction_id, capture.transaction_ref, capture.currency_code,
          capture.amount, capture.status;

CREATE VIEW ledger.v_settlement_batch_summary AS
WITH ranked_runs AS (
  SELECT r.*,
         row_number() OVER (
           PARTITION BY r.settlement_batch_id ORDER BY r.run_number DESC
         ) AS run_rank
    FROM ledger.reconciliation_runs AS r
)
SELECT b.settlement_batch_id,
       b.external_batch_ref,
       b.source_name,
       b.statement_date,
       b.window_start,
       b.window_end,
       b.currency_code,
       b.status,
       lr.reconciliation_run_id AS latest_run_id,
       lr.run_number AS latest_run_number,
       COALESCE(sum(rr.expected_amount), 0)::numeric(20,4) AS expected_gross_total,
       COALESCE(sum(rr.external_amount), 0)::numeric(20,4) AS external_gross_total,
       count(rr.reconciliation_result_id) FILTER (
         WHERE rr.result_type <> 'matched'
       ) AS exception_count
  FROM ledger.settlement_batches AS b
  LEFT JOIN ranked_runs AS lr
    ON lr.settlement_batch_id = b.settlement_batch_id AND lr.run_rank = 1
  LEFT JOIN ledger.reconciliation_results AS rr
    ON rr.reconciliation_run_id = lr.reconciliation_run_id
 GROUP BY b.settlement_batch_id, b.external_batch_ref, b.source_name,
          b.statement_date, b.window_start, b.window_end, b.currency_code,
          b.status, lr.reconciliation_run_id, lr.run_number;

CREATE VIEW ledger.v_reconciliation_exceptions AS
SELECT b.settlement_batch_id,
       b.external_batch_ref,
       run.run_number,
       result.reconciliation_result_id,
       result.result_type,
       result.transaction_id,
       tx.transaction_ref,
       result.settlement_item_id,
       item.external_ref,
       result.expected_amount,
       result.external_amount,
       result.expected_currency_code,
       result.external_currency_code,
       result.expected_flow,
       result.external_flow,
       result.evaluated_at
  FROM ledger.reconciliation_results AS result
  JOIN ledger.reconciliation_runs AS run
    ON run.reconciliation_run_id = result.reconciliation_run_id
  JOIN ledger.settlement_batches AS b
    ON b.settlement_batch_id = run.settlement_batch_id
  LEFT JOIN ledger.transactions AS tx
    ON tx.transaction_id = result.transaction_id
  LEFT JOIN ledger.settlement_items AS item
    ON item.settlement_item_id = result.settlement_item_id
 WHERE result.result_type <> 'matched';

CREATE VIEW ledger.v_unsettled_transactions AS
SELECT t.transaction_id,
       t.transaction_ref,
       t.transaction_type,
       t.amount,
       t.currency_code,
       t.posted_at,
       current_timestamp - t.posted_at AS elapsed_since_posting
  FROM ledger.transactions AS t
 WHERE t.status = 'posted'
   AND t.transaction_type IN ('capture', 'refund')
   AND NOT EXISTS (
     SELECT 1 FROM ledger.settlement_matches AS sm
      WHERE sm.transaction_id = t.transaction_id
   );

COMMENT ON VIEW ledger.v_daily_transaction_volume IS
  'UTC daily transaction counts and gross amounts by currency and operation type.';
COMMENT ON VIEW ledger.v_account_activity IS
  'Posted ledger lines with normal-side deltas and deterministic running account balances.';
COMMENT ON VIEW ledger.v_unsettled_transactions IS
  'Posted captures and refunds that have no one-to-one external statement match.';

REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM PUBLIC;
GRANT SELECT ON ledger.v_daily_transaction_volume TO ledgerx_runtime;
GRANT SELECT ON ledger.v_monthly_transaction_summary TO ledgerx_runtime;
GRANT SELECT ON ledger.v_monthly_transaction_rank TO ledgerx_runtime;
GRANT SELECT ON ledger.v_account_activity TO ledgerx_runtime;
GRANT SELECT ON ledger.v_refund_analysis TO ledgerx_runtime;
GRANT SELECT ON ledger.v_settlement_batch_summary TO ledgerx_runtime;
GRANT SELECT ON ledger.v_reconciliation_exceptions TO ledgerx_runtime;
GRANT SELECT ON ledger.v_unsettled_transactions TO ledgerx_runtime;
