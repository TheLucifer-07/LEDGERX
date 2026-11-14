BEGIN;
SET LOCAL ROLE ledgerx_owner;

INSERT INTO ledger.currencies (currency_code, name, minor_unit, active)
VALUES
  ('USD', 'Fictional US Dollar', 2, true),
  ('JPY', 'Fictional Yen', 0, true),
  ('KWD', 'Fictional Dinar', 3, true)
ON CONFLICT (currency_code) DO NOTHING;

INSERT INTO ledger.customers (customer_ref, display_name, status)
VALUES
  ('CUST-1001', 'Avery Example', 'active'),
  ('CUST-1002', 'Jordan Example', 'active'),
  ('CUST-1003', 'Morgan Example', 'active'),
  ('MERCHANT-2001', 'Northstar Demo Merchant', 'active')
ON CONFLICT (customer_ref) DO NOTHING;

INSERT INTO ledger.accounts (
  customer_id, account_code, account_kind, normal_side, currency_code, status
)
VALUES
  (NULL, 'SYS-FUND-USD', 'funding_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-PAYOUT-USD', 'payout_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-FUND-FINANCIAL-USD', 'funding_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-PAYOUT-FINANCIAL-USD', 'payout_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-FUND-INTEGRITY-USD', 'funding_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-FUND-SCHEMA-USD', 'funding_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-FUND-DEMO-USD', 'funding_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-PAYOUT-DEMO-USD', 'payout_clearing', 'debit', 'USD', 'open'),
  (NULL, 'SYS-FUND-JPY', 'funding_clearing', 'debit', 'JPY', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1001'),
   'WALLET-1001-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1002'),
   'WALLET-1002-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1003'),
   'WALLET-1003-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'MERCHANT-2001'),
   'MERCHANT-2001-USD', 'merchant_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1001'),
   'WALLET-FINANCIAL-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1002'),
   'WALLET-FINANCIAL-RECIPIENT-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'MERCHANT-2001'),
   'MERCHANT-FINANCIAL-USD', 'merchant_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1001'),
   'WALLET-DEMO-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1002'),
   'WALLET-DEMO-RECIPIENT-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'MERCHANT-2001'),
   'MERCHANT-DEMO-USD', 'merchant_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'MERCHANT-2001'),
   'MERCHANT-2001-JPY', 'merchant_wallet', 'credit', 'JPY', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1001'),
   'WALLET-1001-JPY', 'customer_wallet', 'credit', 'JPY', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1003'),
   'WALLET-1003-FROZEN-USD', 'customer_wallet', 'credit', 'USD', 'frozen'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1003'),
   'WALLET-INTEGRITY-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1002'),
   'WALLET-SCHEMA-USD', 'customer_wallet', 'credit', 'USD', 'open'),
  ((SELECT customer_id FROM ledger.customers WHERE customer_ref = 'CUST-1003'),
   'WALLET-REPORTS-USD', 'customer_wallet', 'credit', 'USD', 'open')
ON CONFLICT (account_code) DO NOTHING;

INSERT INTO ledger.account_balances (account_id)
SELECT a.account_id
  FROM ledger.accounts AS a
ON CONFLICT (account_id) DO NOTHING;

COMMIT;
