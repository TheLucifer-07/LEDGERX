-- 008_reporting_views.sql : reporting views. security_invoker => RLS of the caller applies.
-- Money is never summed across currencies: every view groups by currency.

CREATE VIEW lx.v_account_balances WITH (security_invoker = true) AS
SELECT a.workspace_id, a.id AS account_id, a.code, a.name, a.class, a.subtype, a.currency,
       a.owner_user_id, a.is_active,
       coalesce(b.debit_total, 0)  AS debit_total,
       coalesce(b.credit_total, 0) AS credit_total,
       CASE WHEN a.class IN ('asset','expense')
            THEN coalesce(b.debit_total, 0) - coalesce(b.credit_total, 0)
            ELSE coalesce(b.credit_total, 0) - coalesce(b.debit_total, 0) END AS balance
FROM lx.accounts a
LEFT JOIN lx.account_balances b ON b.workspace_id = a.workspace_id AND b.account_id = a.id;

-- Income / expense per month and currency, derived from the ledger itself.
-- Transfers (asset<->asset / liability) never touch income or expense accounts,
-- and reversals offset their originals, so neither distorts the result.
CREATE VIEW lx.v_monthly_cashflow WITH (security_invoker = true) AS
SELECT e.workspace_id, date_trunc('month', e.entry_date)::date AS month, l.currency,
       coalesce(sum(l.credit - l.debit) FILTER (WHERE a.class = 'income'), 0)  AS income,
       coalesce(sum(l.debit - l.credit) FILTER (WHERE a.class = 'expense'), 0) AS expense,
       coalesce(sum(l.credit - l.debit) FILTER (WHERE a.class = 'income'), 0)
     - coalesce(sum(l.debit - l.credit) FILTER (WHERE a.class = 'expense'), 0) AS net
FROM lx.journal_lines l
JOIN lx.journal_entries e ON e.id = l.entry_id AND e.workspace_id = l.workspace_id
JOIN lx.accounts a ON a.id = l.account_id AND a.workspace_id = l.workspace_id
WHERE a.class IN ('income','expense')
GROUP BY e.workspace_id, date_trunc('month', e.entry_date), l.currency;

CREATE VIEW lx.v_category_spend WITH (security_invoker = true) AS
SELECT e.workspace_id, date_trunc('month', e.entry_date)::date AS month, a.id AS account_id,
       a.name AS account_name, a.class, l.currency, sum(l.debit - l.credit) AS amount
FROM lx.journal_lines l
JOIN lx.journal_entries e ON e.id = l.entry_id AND e.workspace_id = l.workspace_id
JOIN lx.accounts a ON a.id = l.account_id AND a.workspace_id = l.workspace_id
WHERE a.class = 'expense'
GROUP BY e.workspace_id, date_trunc('month', e.entry_date), a.id, a.name, a.class, l.currency;

GRANT SELECT ON lx.v_account_balances, lx.v_monthly_cashflow, lx.v_category_spend TO ledgerx_runtime;
