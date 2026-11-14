package com.ledgerx.dashboard;

import java.time.LocalDate;
import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.http.HttpStatus;

@Service
@Transactional(readOnly = true)
public class LedgerReadService {
    private final NamedParameterJdbcTemplate jdbc;
    private static final int MAX_PAGE_SIZE = 100;
    private static final Map<String, String> TRANSACTION_SORTS = Map.of(
            "created_at", "t.created_at", "amount", "t.amount", "status", "t.status",
            "type", "t.transaction_type", "reference", "t.transaction_ref", "currency", "t.currency_code");
    private static final Map<String, String> ACCOUNT_SORTS = Map.of(
            "account_code", "a.account_code", "kind", "a.account_kind", "status", "a.status",
            "balance", "ab.posted_balance", "created_at", "a.created_at");

    public LedgerReadService(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Map<String, Object> health() {
        return jdbc.queryForMap("""
                SELECT 'ok' AS status, current_setting('server_version') AS postgres_version,
                       current_user AS database_role, transaction_timestamp() AS checked_at
                """, Map.of());
    }

    public Map<String, Object> summary(LocalDate from, LocalDate to) {
        MapSqlParameterSource params = dates(from, to);
        Map<String, Object> tx = jdbc.queryForMap("""
                SELECT count(*) FILTER (WHERE t.status IN ('posted', 'reversed')) AS total_transactions,
                       count(*) FILTER (WHERE t.status = 'posted') AS posted_transactions
                  FROM ledger.transactions t
                 WHERE (CAST(:from_date AS date) IS NULL OR t.created_at >= CAST(:from_date AS date))
                   AND (CAST(:to_date AS date) IS NULL OR t.created_at < CAST(:to_date AS date) + INTERVAL '1 day')
                """, params);
        List<Map<String, Object>> volumes = jdbc.queryForList("""
                SELECT t.currency_code, COALESCE(sum(t.amount), 0)::numeric(20,4) AS posted_volume
                  FROM ledger.transactions t
                 WHERE t.status = 'posted'
                   AND (CAST(:from_date AS date) IS NULL OR t.posted_at >= CAST(:from_date AS date))
                   AND (CAST(:to_date AS date) IS NULL OR t.posted_at < CAST(:to_date AS date) + INTERVAL '1 day')
                 GROUP BY t.currency_code ORDER BY t.currency_code
                """, params);
        Map<String, Object> accounts = jdbc.queryForMap("""
                SELECT count(*) AS total_accounts,
                       count(*) FILTER (WHERE status = 'open') AS active_accounts
                  FROM ledger.accounts
                """, Map.of());
        Map<String, Object> settlements = jdbc.queryForMap("""
                SELECT count(*) AS total_batches,
                       COALESCE(sum(exception_count), 0) AS reconciliation_exceptions
                  FROM ledger.v_settlement_batch_summary
                """, Map.of());
        Integer integrityCount = jdbc.getJdbcTemplate().queryForObject(
                "SELECT count(*) FROM ledger.audit_integrity()", Integer.class);
        Map<String, Object> result = new HashMap<>();
        result.put("transactions", tx);
        result.put("posted_volume_by_currency", volumes);
        result.put("accounts", accounts);
        result.put("settlements", settlements);
        result.put("integrity_finding_count", integrityCount == null ? 0 : integrityCount);
        result.put("date_range", Map.of("from", valueOrEmpty(from), "to", valueOrEmpty(to)));
        return result;
    }

    public Map<String, Object> transactionVolume(LocalDate from, LocalDate to) {
        return Map.of("items", jdbc.queryForList("""
                SELECT transaction_date, currency_code, transaction_type,
                       transaction_count, posted_count, reversed_count, gross_amount
                  FROM ledger.v_daily_transaction_volume
                 WHERE (CAST(:from_date AS date) IS NULL OR transaction_date >= CAST(:from_date AS date))
                   AND (CAST(:to_date AS date) IS NULL OR transaction_date <= CAST(:to_date AS date))
                 ORDER BY transaction_date, currency_code, transaction_type
                """, dates(from, to)));
    }

    public Map<String, Object> transactionDistribution(LocalDate from, LocalDate to) {
        MapSqlParameterSource params = dates(from, to);
        return Map.of(
                "by_status", jdbc.queryForList("""
                        SELECT status, count(*) AS transaction_count
                          FROM ledger.transactions
                         WHERE (CAST(:from_date AS date) IS NULL OR created_at >= CAST(:from_date AS date))
                           AND (CAST(:to_date AS date) IS NULL OR created_at < CAST(:to_date AS date) + INTERVAL '1 day')
                         GROUP BY status ORDER BY status
                        """, params),
                "by_type", jdbc.queryForList("""
                        SELECT transaction_type, count(*) AS transaction_count
                          FROM ledger.transactions
                         WHERE (CAST(:from_date AS date) IS NULL OR created_at >= CAST(:from_date AS date))
                           AND (CAST(:to_date AS date) IS NULL OR created_at < CAST(:to_date AS date) + INTERVAL '1 day')
                         GROUP BY transaction_type ORDER BY transaction_type
                        """, params));
    }

    public Map<String, Object> currencies() {
        return Map.of("items", jdbc.queryForList("""
                SELECT currency_code, name, minor_unit
                  FROM ledger.currencies
                 WHERE active
                 ORDER BY currency_code
                """, Map.of()));
    }

    public Map<String, Object> transactions(int page, int size, String search, String status,
                                            String type, String currency, LocalDate from,
                                            LocalDate to, String sort, String direction) {
        validatePage(page, size);
        String sortColumn = TRANSACTION_SORTS.getOrDefault(sort, "t.created_at");
        String order = "asc".equalsIgnoreCase(direction) ? "ASC" : "DESC";
        MapSqlParameterSource params = pageParams(page, size)
                .addValue("search", like(search))
                .addValue("status", blankToNull(status))
                .addValue("type", blankToNull(type))
                .addValue("currency", blankToNull(currency))
                .addValues(dates(from, to).getValues());
        String where = """
                WHERE (CAST(:search AS text) IS NULL OR t.transaction_ref ILIKE :search
                       OR sa.account_code ILIKE :search OR da.account_code ILIKE :search)
                  AND (CAST(:status AS text) IS NULL OR t.status = :status)
                  AND (CAST(:type AS text) IS NULL OR t.transaction_type = :type)
                  AND (CAST(:currency AS text) IS NULL OR t.currency_code = :currency)
                  AND (CAST(:from_date AS date) IS NULL OR t.created_at >= CAST(:from_date AS date))
                  AND (CAST(:to_date AS date) IS NULL OR t.created_at < CAST(:to_date AS date) + INTERVAL '1 day')
                """;
        String fromSql = """
                FROM ledger.transactions t
                JOIN ledger.accounts sa ON sa.account_id = t.source_account_id
                JOIN ledger.accounts da ON da.account_id = t.destination_account_id
                """;
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT t.transaction_id, t.transaction_ref, t.transaction_type, t.status,
                       t.amount, t.currency_code, t.source_account_id, sa.account_code AS source_account_code,
                       t.destination_account_id, da.account_code AS destination_account_code,
                       t.reversal_of_transaction_id, t.created_at, t.posted_at
                """ + fromSql + where + " ORDER BY " + sortColumn + " " + order
                + " NULLS LAST LIMIT :limit OFFSET :offset", params);
        Long total = jdbc.queryForObject("SELECT count(*) " + fromSql + where, params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> transaction(long id) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT t.transaction_id, t.transaction_ref, t.transaction_type, t.status,
                       t.amount, t.currency_code, t.source_account_id, sa.account_code AS source_account_code,
                       t.destination_account_id, da.account_code AS destination_account_code,
                       t.reversal_of_transaction_id, t.request_reference, t.created_at, t.posted_at,
                       parent.transaction_ref AS reversed_transaction_ref
                  FROM ledger.transactions t
                  JOIN ledger.accounts sa ON sa.account_id = t.source_account_id
                  JOIN ledger.accounts da ON da.account_id = t.destination_account_id
                  LEFT JOIN ledger.transactions parent
                    ON parent.transaction_id = t.reversal_of_transaction_id
                 WHERE t.transaction_id = :id
                """, Map.of("id", id));
        return oneOrNotFound(rows, "Transaction");
    }

    public Map<String, Object> accounts(int page, int size, String search, String status,
                                        String kind, String currency, String sort, String direction) {
        validatePage(page, size);
        String sortColumn = ACCOUNT_SORTS.getOrDefault(sort, "a.account_code");
        String order = "desc".equalsIgnoreCase(direction) ? "DESC" : "ASC";
        MapSqlParameterSource params = pageParams(page, size)
                .addValue("search", like(search)).addValue("status", blankToNull(status))
                .addValue("kind", blankToNull(kind)).addValue("currency", blankToNull(currency));
        String fromSql = """
                FROM ledger.accounts a
                LEFT JOIN ledger.customers c ON c.customer_id = a.customer_id
                JOIN ledger.account_balances ab ON ab.account_id = a.account_id
                """;
        String where = """
                WHERE (CAST(:search AS text) IS NULL OR a.account_code ILIKE :search
                       OR c.customer_ref ILIKE :search OR c.display_name ILIKE :search)
                  AND (CAST(:status AS text) IS NULL OR a.status = :status)
                  AND (CAST(:kind AS text) IS NULL OR a.account_kind = :kind)
                  AND (CAST(:currency AS text) IS NULL OR a.currency_code = :currency)
                """;
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT a.account_id, a.account_code, a.account_kind, a.normal_side,
                       a.currency_code, a.status, a.created_at, c.customer_ref,
                       c.display_name AS customer_name, c.status AS customer_status,
                       ab.posted_balance, ab.updated_at AS balance_updated_at
                """ + fromSql + where + " ORDER BY " + sortColumn + " " + order
                + " LIMIT :limit OFFSET :offset", params);
        Long total = jdbc.queryForObject("SELECT count(*) " + fromSql + where, params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> account(long id) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT a.account_id, a.account_code, a.account_kind, a.normal_side,
                       a.currency_code, a.status, a.created_at, c.customer_ref,
                       c.display_name AS customer_name, c.status AS customer_status,
                       ab.posted_balance, ab.updated_at AS balance_updated_at
                  FROM ledger.accounts a
                  LEFT JOIN ledger.customers c ON c.customer_id = a.customer_id
                  JOIN ledger.account_balances ab ON ab.account_id = a.account_id
                 WHERE a.account_id = :id
                """, Map.of("id", id));
        return oneOrNotFound(rows, "Account");
    }

    public Map<String, Object> accountActivity(long id, int page, int size) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size).addValue("id", id);
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT account_id, account_code, account_kind, currency_code, transaction_id,
                       transaction_ref, transaction_type, transaction_status, ledger_entry_id,
                       entry_side, amount, normalized_delta, posted_at, running_normal_balance
                  FROM ledger.v_account_activity
                 WHERE account_id = :id
                 ORDER BY posted_at DESC, ledger_entry_id DESC
                 LIMIT :limit OFFSET :offset
                """, params);
        Long total = jdbc.queryForObject(
                "SELECT count(*) FROM ledger.v_account_activity WHERE account_id = :id", params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> ledgerEntries(int page, int size, String search,
                                             String side, String currency, LocalDate from,
                                             LocalDate to) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size).addValue("search", like(search))
                .addValue("side", blankToNull(side)).addValue("currency", blankToNull(currency))
                .addValues(dates(from, to).getValues());
        String fromSql = """
                FROM ledger.ledger_entries le
                JOIN ledger.transactions t ON t.transaction_id = le.transaction_id
                JOIN ledger.accounts a ON a.account_id = le.account_id
                """;
        String where = """
                WHERE (CAST(:search AS text) IS NULL OR t.transaction_ref ILIKE :search OR a.account_code ILIKE :search)
                  AND (CAST(:side AS text) IS NULL OR le.entry_side = :side)
                  AND (CAST(:currency AS text) IS NULL OR le.currency_code = :currency)
                  AND (CAST(:from_date AS date) IS NULL OR t.posted_at >= CAST(:from_date AS date))
                  AND (CAST(:to_date AS date) IS NULL OR t.posted_at < CAST(:to_date AS date) + INTERVAL '1 day')
                """;
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT le.ledger_entry_id, le.transaction_id, t.transaction_ref,
                       t.transaction_type, t.status AS transaction_status, le.account_id,
                       a.account_code, le.entry_side, le.amount, le.currency_code, le.created_at,
                       t.posted_at
                """ + fromSql + where
                + " ORDER BY t.posted_at DESC NULLS LAST, le.ledger_entry_id DESC LIMIT :limit OFFSET :offset",
                params);
        Long total = jdbc.queryForObject("SELECT count(*) " + fromSql + where, params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> journal(long id) {
        Map<String, Object> transaction = transaction(id);
        List<Map<String, Object>> entries = jdbc.queryForList("""
                SELECT le.ledger_entry_id, le.account_id, a.account_code, a.account_kind,
                       a.normal_side, a.currency_code AS account_currency_code,
                       le.entry_side, le.amount, le.currency_code, le.created_at
                  FROM ledger.ledger_entries le
                  JOIN ledger.accounts a ON a.account_id = le.account_id
                 WHERE le.transaction_id = :id
                 ORDER BY le.ledger_entry_id
                """, Map.of("id", id));
        Map<String, Object> totals = jdbc.queryForMap("""
                SELECT count(*) AS line_count,
                       COALESCE(sum(amount) FILTER (WHERE entry_side = 'debit'), 0)::numeric(20,4) AS debit_total,
                       COALESCE(sum(amount) FILTER (WHERE entry_side = 'credit'), 0)::numeric(20,4) AS credit_total,
                       count(DISTINCT currency_code) AS currency_count
                  FROM ledger.ledger_entries WHERE transaction_id = :id
                """, Map.of("id", id));
        Object debit = totals.get("debit_total");
        Object credit = totals.get("credit_total");
        boolean balanced = debit instanceof BigDecimal debitValue && credit instanceof BigDecimal creditValue
                && debitValue.compareTo(creditValue) == 0
                && ((Number) totals.get("line_count")).longValue() >= 2
                && ((Number) totals.get("currency_count")).longValue() == 1;
        List<Map<String, Object>> findings = jdbc.queryForList("""
                SELECT finding_type, entity_type, entity_id, details::text AS details
                  FROM ledger.audit_integrity()
                 WHERE finding_type = 'unbalanced_journal'
                   AND entity_type = 'transaction' AND entity_id = :id
                """, Map.of("id", Long.toString(id)));
        return Map.of("transaction", transaction, "entries", entries, "audit_findings", findings,
                "totals", Map.of("line_count", totals.get("line_count"), "debit_total", debit,
                        "credit_total", credit, "currency_count", totals.get("currency_count"),
                        "balanced", balanced && findings.isEmpty()));
    }

    public Map<String, Object> refunds(int page, int size, String search, String status) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size).addValue("search", like(search))
                .addValue("status", blankToNull(status));
        String fromSql = "FROM ledger.v_refund_history h JOIN ledger.v_refund_analysis a ON a.capture_transaction_id = h.capture_transaction_id";
        String where = "WHERE (CAST(:search AS text) IS NULL OR h.capture_reference ILIKE :search OR h.refund_reference ILIKE :search) AND (CAST(:status AS text) IS NULL OR h.refund_status = :status)";
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT h.refund_id, h.capture_transaction_id, h.capture_reference,
                       h.refund_transaction_id, h.refund_reference, h.refund_status,
                       h.reversal_transaction_id, h.reversal_reference, h.amount, h.currency_code,
                       h.created_at, a.captured_amount, a.refunded_amount,
                       a.remaining_refundable_amount, a.historical_refund_amount,
                       a.reversed_refund_count
                """ + fromSql + " " + where
                + " ORDER BY h.created_at DESC, h.refund_id DESC LIMIT :limit OFFSET :offset", params);
        Long total = jdbc.queryForObject("SELECT count(*) " + fromSql + " " + where, params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> settlements(int page, int size, String search, String status,
                                           String currency) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size).addValue("search", like(search))
                .addValue("status", blankToNull(status)).addValue("currency", blankToNull(currency));
        String where = "WHERE (CAST(:search AS text) IS NULL OR external_batch_ref ILIKE :search OR source_name ILIKE :search) AND (CAST(:status AS text) IS NULL OR status = :status) AND (CAST(:currency AS text) IS NULL OR currency_code = :currency)";
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT settlement_batch_id, external_batch_ref, source_name, statement_date,
                       window_start, window_end, currency_code, status, latest_run_id,
                       latest_run_number, expected_gross_total, external_gross_total, exception_count
                  FROM ledger.v_settlement_batch_summary
                """ + where + " ORDER BY statement_date DESC, settlement_batch_id DESC LIMIT :limit OFFSET :offset", params);
        Long total = jdbc.queryForObject("SELECT count(*) FROM ledger.v_settlement_batch_summary " + where, params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> settlementItems(long id, int page, int size) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size).addValue("id", id);
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT si.settlement_item_id, si.external_ref, si.external_amount, si.flow,
                       si.currency_code, si.external_at, si.internal_reference,
                       sm.transaction_id, t.transaction_ref, t.amount AS internal_amount,
                       t.currency_code AS internal_currency_code, t.status AS transaction_status,
                       CASE WHEN sm.transaction_id IS NOT NULL THEN 'matched' ELSE 'unmatched' END AS match_status
                  FROM ledger.settlement_items si
                  LEFT JOIN ledger.settlement_matches sm ON sm.settlement_item_id = si.settlement_item_id
                  LEFT JOIN ledger.transactions t ON t.transaction_id = sm.transaction_id
                 WHERE si.settlement_batch_id = :id
                 ORDER BY si.external_at NULLS LAST, si.settlement_item_id
                 LIMIT :limit OFFSET :offset
                """, params);
        Long total = jdbc.queryForObject("SELECT count(*) FROM ledger.settlement_items WHERE settlement_batch_id = :id", params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> reconciliationRuns(int page, int size) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size);
        String fromSql = """
                FROM ledger.reconciliation_runs r
                JOIN ledger.settlement_batches b USING (settlement_batch_id)
                LEFT JOIN ledger.reconciliation_results rr USING (reconciliation_run_id)
                """;
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT r.reconciliation_run_id, r.settlement_batch_id, b.external_batch_ref,
                       r.run_number, r.started_at, r.completed_at,
                       count(rr.reconciliation_result_id) AS item_count,
                       count(*) FILTER (WHERE rr.result_type = 'matched') AS matched_count,
                       count(*) FILTER (WHERE rr.result_type = 'missing_internal') AS missing_internal_count,
                       count(*) FILTER (WHERE rr.result_type = 'missing_external') AS missing_external_count,
                       count(*) FILTER (WHERE rr.result_type = 'amount_mismatch') AS amount_mismatch_count,
                       count(*) FILTER (WHERE rr.result_type = 'currency_mismatch') AS currency_mismatch_count
                """ + fromSql + " GROUP BY r.reconciliation_run_id, b.external_batch_ref"
                + " ORDER BY r.started_at DESC, r.reconciliation_run_id DESC LIMIT :limit OFFSET :offset", params);
        Long total = jdbc.queryForObject("SELECT count(*) FROM ledger.reconciliation_runs", params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> reconciliationExceptions(int page, int size, String type, String search) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size).addValue("type", blankToNull(type))
                .addValue("search", like(search));
        String where = "WHERE (CAST(:type AS text) IS NULL OR result_type = :type) AND (CAST(:search AS text) IS NULL OR external_batch_ref ILIKE :search OR transaction_ref ILIKE :search OR external_ref ILIKE :search)";
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT settlement_batch_id, external_batch_ref, run_number,
                       reconciliation_result_id, result_type, transaction_id, transaction_ref,
                       settlement_item_id, external_ref, expected_amount, external_amount,
                       expected_currency_code, external_currency_code, expected_flow,
                       external_flow, evaluated_at
                  FROM ledger.v_reconciliation_exceptions
                """ + where + " ORDER BY evaluated_at DESC, reconciliation_result_id DESC LIMIT :limit OFFSET :offset", params);
        Long total = jdbc.queryForObject("SELECT count(*) FROM ledger.v_reconciliation_exceptions " + where, params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> unsettledTransactions(int page, int size) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size);
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT transaction_id, transaction_ref, transaction_type, amount,
                       currency_code, posted_at, elapsed_since_posting
                  FROM ledger.v_unsettled_transactions
                 ORDER BY posted_at, transaction_id LIMIT :limit OFFSET :offset
                """, params);
        Long total = jdbc.queryForObject("SELECT count(*) FROM ledger.v_unsettled_transactions", params, Long.class);
        return pageResult(rows, page, size, total);
    }

    public Map<String, Object> integrityFindings(int page, int size) {
        validatePage(page, size);
        MapSqlParameterSource params = pageParams(page, size);
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT finding_type, entity_type, entity_id,
                       finding_type || ':' || entity_type || ':' || entity_id AS finding_key,
                       details::text AS details
                  FROM ledger.audit_integrity()
                 ORDER BY finding_type, entity_type, entity_id
                 LIMIT :limit OFFSET :offset
                """, params);
        Long total = jdbc.getJdbcTemplate().queryForObject("SELECT count(*) FROM ledger.audit_integrity()", Long.class);
        return pageResult(rows, page, size, total);
    }

    private static MapSqlParameterSource dates(LocalDate from, LocalDate to) {
        if (from != null && to != null && to.isBefore(from)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "The end date must be on or after the start date.");
        }
        return new MapSqlParameterSource().addValue("from_date", from).addValue("to_date", to);
    }

    private static void validatePage(int page, int size) {
        if (page < 0 || page > 1_000_000) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Page must be between 0 and 1000000.");
        }
        if (size < 1 || size > MAX_PAGE_SIZE) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Page size must be between 1 and 100.");
        }
    }

    private static MapSqlParameterSource pageParams(int page, int size) {
        return new MapSqlParameterSource().addValue("limit", size).addValue("offset", (long) page * size);
    }

    private static Map<String, Object> pageResult(List<Map<String, Object>> items, int page, int size, Long count) {
        long total = count == null ? 0 : count;
        return Map.of("items", items, "page", page, "size", size, "total", total,
                "pages", total == 0 ? 0 : (total + size - 1) / size);
    }

    private static Map<String, Object> oneOrNotFound(List<Map<String, Object>> rows, String label) {
        if (rows.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, label + " was not found.");
        }
        return rows.getFirst();
    }

    private static String like(String value) {
        return value == null || value.isBlank() ? null : "%" + value.trim() + "%";
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private static String valueOrEmpty(LocalDate date) {
        return date == null ? "" : date.toString();
    }
}
