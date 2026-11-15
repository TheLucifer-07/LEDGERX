import { HttpError } from '../utils/http-error.js'

const transactionSorts = {
  created_at: 't.created_at', amount: 't.amount', status: 't.status',
  type: 't.transaction_type', reference: 't.transaction_ref', currency: 't.currency_code',
}
const accountSorts = {
  account_code: 'a.account_code', kind: 'a.account_kind', status: 'a.status',
  balance: 'ab.posted_balance', created_at: 'a.created_at',
}

export function createLedgerReadService(pool) {
  async function page(sql, countSql, values, pageNumber, pageSize) {
    const offset = pageNumber * pageSize
    const [itemsResult, countResult] = await Promise.all([
      pool.query(sql, [...values, pageSize, offset]),
      pool.query(countSql, values),
    ])
    const total = Number(countResult.rows[0]?.total ?? 0)
    return { items: itemsResult.rows, page: pageNumber, size: pageSize, total, pages: total === 0 ? 0 : Math.ceil(total / pageSize) }
  }

  async function one(sql, values, label) {
    const result = await pool.query(sql, values)
    if (!result.rowCount) throw new HttpError(404, 'not_found', `${label} was not found.`)
    return result.rows[0]
  }

  return {
    async health() {
      await pool.query('SELECT 1')
      return { status: 'ok' }
    },

    async summary({ from, to }) {
      const values = [from, to]
      const [transactions, volumes, accounts, settlements, integrity] = await Promise.all([
        pool.query(`
          SELECT count(*) FILTER (WHERE status IN ('posted', 'reversed')) AS total_transactions,
                 count(*) FILTER (WHERE status = 'posted') AS posted_transactions
            FROM ledger.transactions
           WHERE ($1::date IS NULL OR created_at >= $1::date)
             AND ($2::date IS NULL OR created_at < $2::date + INTERVAL '1 day')`, values),
        pool.query(`
          SELECT currency_code, COALESCE(sum(amount), 0)::numeric(20,4) AS posted_volume
            FROM ledger.transactions
           WHERE status = 'posted'
             AND ($1::date IS NULL OR posted_at >= $1::date)
             AND ($2::date IS NULL OR posted_at < $2::date + INTERVAL '1 day')
           GROUP BY currency_code ORDER BY currency_code`, values),
        pool.query(`SELECT count(*) AS total_accounts, count(*) FILTER (WHERE status = 'open') AS active_accounts FROM ledger.accounts`),
        pool.query(`SELECT count(*) AS total_batches, COALESCE(sum(exception_count), 0) AS reconciliation_exceptions FROM ledger.v_settlement_batch_summary`),
        pool.query(`SELECT count(*) AS total FROM ledger.audit_integrity()`),
      ])
      return {
        transactions: mapCounts(transactions.rows[0], ['total_transactions', 'posted_transactions']),
        posted_volume_by_currency: volumes.rows,
        accounts: mapCounts(accounts.rows[0], ['total_accounts', 'active_accounts']),
        settlements: mapCounts(settlements.rows[0], ['total_batches', 'reconciliation_exceptions']),
        integrity_finding_count: Number(integrity.rows[0].total),
        date_range: { from: from ?? '', to: to ?? '' },
      }
    },

    async transactionVolume({ from, to }) {
      const result = await pool.query(`
        SELECT transaction_date, currency_code, transaction_type, transaction_count,
               posted_count, reversed_count, gross_amount
          FROM ledger.v_daily_transaction_volume
         WHERE ($1::date IS NULL OR transaction_date >= $1::date)
           AND ($2::date IS NULL OR transaction_date <= $2::date)
         ORDER BY transaction_date, currency_code, transaction_type`, [from, to])
      return { items: result.rows.map((row) => mapCounts(row, ['transaction_count', 'posted_count', 'reversed_count'])) }
    },

    async transactionDistribution({ from, to }) {
      const values = [from, to]
      const [statuses, types] = await Promise.all([
        pool.query(`SELECT status, count(*) AS transaction_count FROM ledger.transactions
          WHERE ($1::date IS NULL OR created_at >= $1::date)
            AND ($2::date IS NULL OR created_at < $2::date + INTERVAL '1 day')
          GROUP BY status ORDER BY status`, values),
        pool.query(`SELECT transaction_type, count(*) AS transaction_count FROM ledger.transactions
          WHERE ($1::date IS NULL OR created_at >= $1::date)
            AND ($2::date IS NULL OR created_at < $2::date + INTERVAL '1 day')
          GROUP BY transaction_type ORDER BY transaction_type`, values),
      ])
      return {
        by_status: statuses.rows.map((row) => mapCounts(row, ['transaction_count'])),
        by_type: types.rows.map((row) => mapCounts(row, ['transaction_count'])),
      }
    },

    async currencies() {
      const result = await pool.query(`SELECT currency_code, name, minor_unit FROM ledger.currencies WHERE active ORDER BY currency_code`)
      return { items: result.rows }
    },

    async transactions({ page: pageNumber, size, search, status, type, currency, from, to, sort, direction }) {
      const values = [like(search), status, type, currency, from, to]
      const fromSql = `FROM ledger.transactions t
        JOIN ledger.accounts sa ON sa.account_id = t.source_account_id
        JOIN ledger.accounts da ON da.account_id = t.destination_account_id`
      const where = `WHERE ($1::text IS NULL OR t.transaction_ref ILIKE $1 OR sa.account_code ILIKE $1 OR da.account_code ILIKE $1)
        AND ($2::text IS NULL OR t.status = $2)
        AND ($3::text IS NULL OR t.transaction_type = $3)
        AND ($4::text IS NULL OR t.currency_code = $4)
        AND ($5::date IS NULL OR t.created_at >= $5::date)
        AND ($6::date IS NULL OR t.created_at < $6::date + INTERVAL '1 day')`
      const sql = `SELECT t.transaction_id, t.transaction_ref, t.transaction_type, t.status,
        t.amount, t.currency_code, t.source_account_id, sa.account_code AS source_account_code,
        t.destination_account_id, da.account_code AS destination_account_code,
        t.reversal_of_transaction_id, t.created_at, t.posted_at
        ${fromSql} ${where} ORDER BY ${transactionSorts[sort] || transactionSorts.created_at} ${direction} NULLS LAST LIMIT $7 OFFSET $8`
      return page(sql, `SELECT count(*) AS total ${fromSql} ${where}`, values, pageNumber, size)
    },

    async transaction(id) {
      return one(`SELECT t.transaction_id, t.transaction_ref, t.transaction_type, t.status,
        t.amount, t.currency_code, t.source_account_id, sa.account_code AS source_account_code,
        t.destination_account_id, da.account_code AS destination_account_code,
        t.reversal_of_transaction_id, t.request_reference, t.created_at, t.posted_at,
        parent.transaction_ref AS reversed_transaction_ref
        FROM ledger.transactions t
        JOIN ledger.accounts sa ON sa.account_id = t.source_account_id
        JOIN ledger.accounts da ON da.account_id = t.destination_account_id
        LEFT JOIN ledger.transactions parent ON parent.transaction_id = t.reversal_of_transaction_id
        WHERE t.transaction_id = $1`, [id], 'Transaction')
    },

    async accounts({ page: pageNumber, size, search, status, kind, currency, sort, direction }) {
      const values = [like(search), status, kind, currency]
      const fromSql = `FROM ledger.accounts a
        LEFT JOIN ledger.customers c ON c.customer_id = a.customer_id
        JOIN ledger.account_balances ab ON ab.account_id = a.account_id`
      const where = `WHERE ($1::text IS NULL OR a.account_code ILIKE $1 OR c.customer_ref ILIKE $1 OR c.display_name ILIKE $1)
        AND ($2::text IS NULL OR a.status = $2)
        AND ($3::text IS NULL OR a.account_kind = $3)
        AND ($4::text IS NULL OR a.currency_code = $4)`
      const sql = `SELECT a.account_id, a.account_code, a.account_kind, a.normal_side,
        a.currency_code, a.status, a.created_at, c.customer_ref, c.display_name AS customer_name,
        c.status AS customer_status, ab.posted_balance, ab.updated_at AS balance_updated_at
        ${fromSql} ${where} ORDER BY ${accountSorts[sort] || accountSorts.account_code} ${direction} LIMIT $5 OFFSET $6`
      return page(sql, `SELECT count(*) AS total ${fromSql} ${where}`, values, pageNumber, size)
    },

    async account(id) {
      return one(`SELECT a.account_id, a.account_code, a.account_kind, a.normal_side,
        a.currency_code, a.status, a.created_at, c.customer_ref, c.display_name AS customer_name,
        c.status AS customer_status, ab.posted_balance, ab.updated_at AS balance_updated_at
        FROM ledger.accounts a LEFT JOIN ledger.customers c ON c.customer_id = a.customer_id
        JOIN ledger.account_balances ab ON ab.account_id = a.account_id WHERE a.account_id = $1`, [id], 'Account')
    },

    async accountActivity({ id, page: pageNumber, size }) {
      const values = [id]
      return page(`SELECT account_id, account_code, account_kind, currency_code, transaction_id,
        transaction_ref, transaction_type, transaction_status, ledger_entry_id, entry_side, amount,
        normalized_delta, posted_at, running_normal_balance
        FROM ledger.v_account_activity WHERE account_id = $1
        ORDER BY posted_at DESC, ledger_entry_id DESC LIMIT $2 OFFSET $3`,
      `SELECT count(*) AS total FROM ledger.v_account_activity WHERE account_id = $1`, values, pageNumber, size)
    },

    async ledgerEntries({ page: pageNumber, size, search, side, currency, from, to }) {
      const values = [like(search), side, currency, from, to]
      const fromSql = `FROM ledger.ledger_entries le
        JOIN ledger.transactions t ON t.transaction_id = le.transaction_id
        JOIN ledger.accounts a ON a.account_id = le.account_id`
      const where = `WHERE ($1::text IS NULL OR t.transaction_ref ILIKE $1 OR a.account_code ILIKE $1)
        AND ($2::text IS NULL OR le.entry_side = $2)
        AND ($3::text IS NULL OR le.currency_code = $3)
        AND ($4::date IS NULL OR t.posted_at >= $4::date)
        AND ($5::date IS NULL OR t.posted_at < $5::date + INTERVAL '1 day')`
      const sql = `SELECT le.ledger_entry_id, le.transaction_id, t.transaction_ref,
        t.transaction_type, t.status AS transaction_status, le.account_id, a.account_code,
        le.entry_side, le.amount, le.currency_code, le.created_at, t.posted_at
        ${fromSql} ${where} ORDER BY t.posted_at DESC NULLS LAST, le.ledger_entry_id DESC LIMIT $6 OFFSET $7`
      return page(sql, `SELECT count(*) AS total ${fromSql} ${where}`, values, pageNumber, size)
    },

    async journal(id) {
      const transaction = await this.transaction(id)
      const [entries, totals, findings] = await Promise.all([
        pool.query(`SELECT le.ledger_entry_id, le.account_id, a.account_code, a.account_kind,
          a.normal_side, a.currency_code AS account_currency_code, le.entry_side, le.amount,
          le.currency_code, le.created_at FROM ledger.ledger_entries le
          JOIN ledger.accounts a ON a.account_id = le.account_id
          WHERE le.transaction_id = $1 ORDER BY le.ledger_entry_id`, [id]),
        pool.query(`SELECT count(*) AS line_count,
          COALESCE(sum(amount) FILTER (WHERE entry_side = 'debit'), 0)::numeric(20,4) AS debit_total,
          COALESCE(sum(amount) FILTER (WHERE entry_side = 'credit'), 0)::numeric(20,4) AS credit_total,
          count(DISTINCT currency_code) AS currency_count,
          COALESCE(sum(amount) FILTER (WHERE entry_side = 'debit'), 0) =
            COALESCE(sum(amount) FILTER (WHERE entry_side = 'credit'), 0) AS debit_credit_match
          FROM ledger.ledger_entries WHERE transaction_id = $1`, [id]),
        pool.query(`SELECT finding_type, entity_type, entity_id, details::text AS details
          FROM ledger.audit_integrity() WHERE finding_type = 'unbalanced_journal'
          AND entity_type = 'transaction' AND entity_id = $1`, [String(id)]),
      ])
      const totalsRow = totals.rows[0]
      const balanced = Number(totalsRow.line_count) >= 2 && Number(totalsRow.currency_count) === 1
        && totalsRow.debit_credit_match && findings.rows.length === 0
      return {
        transaction,
        entries: entries.rows,
        audit_findings: findings.rows,
        totals: {
          line_count: Number(totalsRow.line_count),
          debit_total: totalsRow.debit_total,
          credit_total: totalsRow.credit_total,
          currency_count: Number(totalsRow.currency_count),
          balanced,
        },
      }
    },

    async refunds({ page: pageNumber, size, search, status }) {
      const values = [like(search), status]
      const fromSql = `FROM ledger.v_refund_history h
        JOIN ledger.v_refund_analysis a ON a.capture_transaction_id = h.capture_transaction_id`
      const where = `WHERE ($1::text IS NULL OR h.capture_reference ILIKE $1 OR h.refund_reference ILIKE $1)
        AND ($2::text IS NULL OR h.refund_status = $2)`
      const sql = `SELECT h.refund_id, h.capture_transaction_id, h.capture_reference,
        h.refund_transaction_id, h.refund_reference, h.refund_status, h.reversal_transaction_id,
        h.reversal_reference, h.amount, h.currency_code, h.created_at, a.captured_amount,
        a.refunded_amount, a.remaining_refundable_amount, a.historical_refund_amount, a.reversed_refund_count
        ${fromSql} ${where} ORDER BY h.created_at DESC, h.refund_id DESC LIMIT $3 OFFSET $4`
      return page(sql, `SELECT count(*) AS total ${fromSql} ${where}`, values, pageNumber, size)
    },

    async settlements({ page: pageNumber, size, search, status, currency }) {
      const values = [like(search), status, currency]
      const where = `WHERE ($1::text IS NULL OR external_batch_ref ILIKE $1 OR source_name ILIKE $1)
        AND ($2::text IS NULL OR status = $2) AND ($3::text IS NULL OR currency_code = $3)`
      const sql = `SELECT settlement_batch_id, external_batch_ref, source_name, statement_date,
        window_start, window_end, currency_code, status, latest_run_id, latest_run_number,
        expected_gross_total, external_gross_total, exception_count
        FROM ledger.v_settlement_batch_summary ${where}
        ORDER BY statement_date DESC, settlement_batch_id DESC LIMIT $4 OFFSET $5`
      return page(sql, `SELECT count(*) AS total FROM ledger.v_settlement_batch_summary ${where}`, values, pageNumber, size)
    },

    async settlementItems({ id, page: pageNumber, size }) {
      const values = [id]
      return page(`SELECT si.settlement_item_id, si.external_ref, si.external_amount, si.flow,
        si.currency_code, si.external_at, si.internal_reference, sm.transaction_id, t.transaction_ref,
        t.amount AS internal_amount, t.currency_code AS internal_currency_code,
        t.status AS transaction_status,
        CASE WHEN sm.transaction_id IS NOT NULL THEN 'matched' ELSE 'unmatched' END AS match_status
        FROM ledger.settlement_items si
        LEFT JOIN ledger.settlement_matches sm ON sm.settlement_item_id = si.settlement_item_id
        LEFT JOIN ledger.transactions t ON t.transaction_id = sm.transaction_id
        WHERE si.settlement_batch_id = $1 ORDER BY si.external_at NULLS LAST, si.settlement_item_id
        LIMIT $2 OFFSET $3`,
      `SELECT count(*) AS total FROM ledger.settlement_items WHERE settlement_batch_id = $1`, values, pageNumber, size)
    },

    async reconciliationRuns({ page: pageNumber, size }) {
      const sql = `SELECT r.reconciliation_run_id, r.settlement_batch_id, b.external_batch_ref,
        r.run_number, r.started_at, r.completed_at, count(rr.reconciliation_result_id) AS item_count,
        count(*) FILTER (WHERE rr.result_type = 'matched') AS matched_count,
        count(*) FILTER (WHERE rr.result_type = 'missing_internal') AS missing_internal_count,
        count(*) FILTER (WHERE rr.result_type = 'missing_external') AS missing_external_count,
        count(*) FILTER (WHERE rr.result_type = 'amount_mismatch') AS amount_mismatch_count,
        count(*) FILTER (WHERE rr.result_type = 'currency_mismatch') AS currency_mismatch_count
        FROM ledger.reconciliation_runs r
        JOIN ledger.settlement_batches b USING (settlement_batch_id)
        LEFT JOIN ledger.reconciliation_results rr USING (reconciliation_run_id)
        GROUP BY r.reconciliation_run_id, b.external_batch_ref
        ORDER BY r.started_at DESC, r.reconciliation_run_id DESC LIMIT $1 OFFSET $2`
      const result = await page(sql, `SELECT count(*) AS total FROM ledger.reconciliation_runs`, [], pageNumber, size)
      result.items = result.items.map((row) => mapCounts(row, ['item_count', 'matched_count', 'missing_internal_count', 'missing_external_count', 'amount_mismatch_count', 'currency_mismatch_count']))
      return result
    },

    async reconciliationExceptions({ page: pageNumber, size, type, search }) {
      const values = [type, like(search)]
      const where = `WHERE ($1::text IS NULL OR result_type = $1)
        AND ($2::text IS NULL OR external_batch_ref ILIKE $2 OR transaction_ref ILIKE $2 OR external_ref ILIKE $2)`
      const sql = `SELECT settlement_batch_id, external_batch_ref, run_number, reconciliation_result_id,
        result_type, transaction_id, transaction_ref, settlement_item_id, external_ref,
        expected_amount, external_amount, expected_currency_code, external_currency_code,
        expected_flow, external_flow, evaluated_at FROM ledger.v_reconciliation_exceptions
        ${where} ORDER BY evaluated_at DESC, reconciliation_result_id DESC LIMIT $3 OFFSET $4`
      return page(sql, `SELECT count(*) AS total FROM ledger.v_reconciliation_exceptions ${where}`, values, pageNumber, size)
    },

    async unsettledTransactions({ page: pageNumber, size }) {
      const sql = `SELECT transaction_id, transaction_ref, transaction_type, amount, currency_code,
        posted_at, elapsed_since_posting FROM ledger.v_unsettled_transactions
        ORDER BY posted_at, transaction_id LIMIT $1 OFFSET $2`
      return page(sql, `SELECT count(*) AS total FROM ledger.v_unsettled_transactions`, [], pageNumber, size)
    },

    async integrityFindings({ page: pageNumber, size }) {
      const sql = `SELECT finding_type, entity_type, entity_id,
        finding_type || ':' || entity_type || ':' || entity_id AS finding_key, details::text AS details
        FROM ledger.audit_integrity() ORDER BY finding_type, entity_type, entity_id LIMIT $1 OFFSET $2`
      return page(sql, `SELECT count(*) AS total FROM ledger.audit_integrity()`, [], pageNumber, size)
    },
  }
}

function like(value) {
  return value ? `%${value}%` : null
}

function mapCounts(row, fields) {
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [
    key,
    fields.includes(key) && value !== null ? Number(value) : value,
  ]))
}
