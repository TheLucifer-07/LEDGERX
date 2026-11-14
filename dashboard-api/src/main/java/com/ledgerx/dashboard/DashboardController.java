package com.ledgerx.dashboard;

import java.time.LocalDate;
import java.util.Map;

import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1")
public class DashboardController {
    private final LedgerReadService reads;

    public DashboardController(LedgerReadService reads) {
        this.reads = reads;
    }

    @GetMapping("/health")
    public Map<String, Object> health() { return reads.health(); }

    @GetMapping("/dashboard/summary")
    public Map<String, Object> summary(@RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
                                       @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to) {
        return reads.summary(from, to);
    }

    @GetMapping("/dashboard/transaction-volume")
    public Map<String, Object> volume(@RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
                                      @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to) {
        return reads.transactionVolume(from, to);
    }

    @GetMapping("/dashboard/transaction-distribution")
    public Map<String, Object> distribution(@RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
                                            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to) {
        return reads.transactionDistribution(from, to);
    }

    @GetMapping("/currencies")
    public Map<String, Object> currencies() { return reads.currencies(); }

    @GetMapping("/transactions")
    public Map<String, Object> transactions(
            @RequestParam(defaultValue = "0") int page, @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String search, @RequestParam(required = false) String status,
            @RequestParam(required = false) String type, @RequestParam(required = false) String currency,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to,
            @RequestParam(defaultValue = "created_at") String sort, @RequestParam(defaultValue = "desc") String direction) {
        return reads.transactions(page, size, search, status, type, currency, from, to, sort, direction);
    }

    @GetMapping("/transactions/{id}")
    public Map<String, Object> transaction(@PathVariable long id) { return reads.transaction(id); }

    @GetMapping("/accounts")
    public Map<String, Object> accounts(
            @RequestParam(defaultValue = "0") int page, @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String search, @RequestParam(required = false) String status,
            @RequestParam(required = false) String kind, @RequestParam(required = false) String currency,
            @RequestParam(defaultValue = "account_code") String sort, @RequestParam(defaultValue = "asc") String direction) {
        return reads.accounts(page, size, search, status, kind, currency, sort, direction);
    }

    @GetMapping("/accounts/{id}")
    public Map<String, Object> account(@PathVariable long id) { return reads.account(id); }

    @GetMapping("/accounts/{id}/activity")
    public Map<String, Object> accountActivity(@PathVariable long id,
            @RequestParam(defaultValue = "0") int page, @RequestParam(defaultValue = "20") int size) {
        return reads.accountActivity(id, page, size);
    }

    @GetMapping("/ledger/entries")
    public Map<String, Object> ledgerEntries(
            @RequestParam(defaultValue = "0") int page, @RequestParam(defaultValue = "25") int size,
            @RequestParam(required = false) String search, @RequestParam(required = false) String side,
            @RequestParam(required = false) String currency,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to) {
        return reads.ledgerEntries(page, size, search, side, currency, from, to);
    }

    @GetMapping("/ledger/journals/{id}")
    public Map<String, Object> journal(@PathVariable long id) { return reads.journal(id); }

    @GetMapping("/refunds")
    public Map<String, Object> refunds(@RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size, @RequestParam(required = false) String search,
            @RequestParam(required = false) String status) { return reads.refunds(page, size, search, status); }

    @GetMapping("/settlements")
    public Map<String, Object> settlements(@RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size, @RequestParam(required = false) String search,
            @RequestParam(required = false) String status, @RequestParam(required = false) String currency) {
        return reads.settlements(page, size, search, status, currency);
    }

    @GetMapping("/settlements/{id}/items")
    public Map<String, Object> settlementItems(@PathVariable long id,
            @RequestParam(defaultValue = "0") int page, @RequestParam(defaultValue = "25") int size) {
        return reads.settlementItems(id, page, size);
    }

    @GetMapping("/reconciliation/runs")
    public Map<String, Object> reconciliationRuns(@RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) { return reads.reconciliationRuns(page, size); }

    @GetMapping("/reconciliation/exceptions")
    public Map<String, Object> reconciliationExceptions(@RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "25") int size, @RequestParam(required = false) String type,
            @RequestParam(required = false) String search) {
        return reads.reconciliationExceptions(page, size, type, search);
    }

    @GetMapping("/reconciliation/unsettled")
    public Map<String, Object> unsettledTransactions(@RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "25") int size) { return reads.unsettledTransactions(page, size); }

    @GetMapping("/integrity/findings")
    public Map<String, Object> integrityFindings(@RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "25") int size) { return reads.integrityFindings(page, size); }
}
