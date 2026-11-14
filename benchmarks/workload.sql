\set ON_ERROR_STOP on
\timing on

CREATE TEMP TABLE benchmark_transactions AS
SELECT g::bigint AS transaction_id,
       (timestamp with time zone '2025-01-01 00:00:00+00'
         + g * interval '1 second') AS created_at,
       CASE WHEN g % 20 = 0 THEN 'refund' ELSE 'transfer' END::text AS transaction_type,
       1.00::numeric(20,4) AS amount,
       'USD'::text AS currency_code
  FROM generate_series(1, :scale::bigint) AS g;

CREATE TEMP TABLE benchmark_entries AS
SELECT t.transaction_id,
       CASE WHEN t.transaction_id % 100 = 0 THEN 1 ELSE 2 END::bigint AS account_id,
       'credit'::text AS entry_side,
       t.amount,
       t.currency_code
  FROM benchmark_transactions AS t
UNION ALL
SELECT t.transaction_id,
       3::bigint AS account_id,
       'debit'::text AS entry_side,
       t.amount,
       t.currency_code
  FROM benchmark_transactions AS t;

ANALYZE benchmark_transactions;
ANALYZE benchmark_entries;

\echo 'BEFORE INDEX: one account activity and running total'
EXPLAIN (ANALYZE, BUFFERS, SUMMARY)
SELECT t.created_at, t.transaction_id, t.transaction_type, e.amount,
       sum(e.amount) OVER (ORDER BY t.created_at, t.transaction_id) AS running_total
  FROM benchmark_entries AS e
  JOIN benchmark_transactions AS t USING (transaction_id)
 WHERE e.account_id = 1
 ORDER BY t.created_at, t.transaction_id;

CREATE INDEX benchmark_entries_account_transaction_idx
    ON benchmark_entries (account_id, transaction_id);
ANALYZE benchmark_entries;

\echo 'AFTER INDEX: same account activity and running total'
EXPLAIN (ANALYZE, BUFFERS, SUMMARY)
SELECT t.created_at, t.transaction_id, t.transaction_type, e.amount,
       sum(e.amount) OVER (ORDER BY t.created_at, t.transaction_id) AS running_total
  FROM benchmark_entries AS e
  JOIN benchmark_transactions AS t USING (transaction_id)
 WHERE e.account_id = 1
 ORDER BY t.created_at, t.transaction_id;
