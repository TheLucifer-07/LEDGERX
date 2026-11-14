\set ON_ERROR_STOP on

DO $test$
BEGIN
  BEGIN
    INSERT INTO ledger.currencies (currency_code, name, minor_unit)
    VALUES ('usd', 'Invalid lowercase currency', 2);
    RAISE EXCEPTION 'lowercase currency code was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO ledger.currencies (currency_code, name, minor_unit)
    VALUES ('ZZZ', 'Invalid precision', 5);
    RAISE EXCEPTION 'currency precision above four was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO ledger.accounts (
      customer_id, account_code, account_kind, normal_side, currency_code
    ) VALUES (NULL, 'TEST-INVALID-WALLET', 'customer_wallet', 'credit', 'USD');
    RAISE EXCEPTION 'customer wallet without an owner was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO ledger.accounts (
      customer_id, account_code, account_kind, normal_side, currency_code
    ) VALUES (NULL, 'TEST-MISSING-CURRENCY', 'funding_clearing', 'debit', 'ZZZ');
    RAISE EXCEPTION 'account with a missing currency was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO ledger.transactions (
      transaction_ref, transaction_type, amount, currency_code,
      source_account_id, destination_account_id
    ) VALUES (
      'TEST-NEGATIVE-AMOUNT', 'transfer', -1, 'USD',
      (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1001-USD'),
      (SELECT account_id FROM ledger.accounts WHERE account_code = 'WALLET-1002-USD')
    );
    RAISE EXCEPTION 'negative transaction amount was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  RAISE NOTICE 'schema row constraints: passed';
END
$test$;

BEGIN;

INSERT INTO ledger.transactions (
  transaction_ref, transaction_type, amount, currency_code,
  source_account_id, destination_account_id
)
SELECT 'TEST-SCHEMA-BALANCED', 'deposit', 1.00, 'USD',
       funding.account_id, wallet.account_id
  FROM ledger.accounts AS funding
  CROSS JOIN ledger.accounts AS wallet
 WHERE funding.account_code = 'SYS-FUND-SCHEMA-USD'
   AND wallet.account_code = 'WALLET-SCHEMA-USD';

INSERT INTO ledger.ledger_entries (
  transaction_id, account_id, entry_side, amount, currency_code
)
SELECT t.transaction_id, a.account_id, v.entry_side, 1.00, 'USD'
  FROM ledger.transactions AS t
  CROSS JOIN (VALUES ('SYS-FUND-SCHEMA-USD', 'debit'), ('WALLET-SCHEMA-USD', 'credit'))
       AS v(account_code, entry_side)
  JOIN ledger.accounts AS a ON a.account_code = v.account_code
 WHERE t.transaction_ref = 'TEST-SCHEMA-BALANCED';

UPDATE ledger.transactions
   SET status = 'posted', posted_at = transaction_timestamp()
 WHERE transaction_ref = 'TEST-SCHEMA-BALANCED';

SET CONSTRAINTS ALL IMMEDIATE;

DO $test$
DECLARE
  v_funding_balance numeric(20,4);
  v_wallet_balance numeric(20,4);
BEGIN
  SELECT b.posted_balance INTO v_funding_balance
    FROM ledger.account_balances AS b
    JOIN ledger.accounts AS a USING (account_id)
   WHERE a.account_code = 'SYS-FUND-SCHEMA-USD';
  SELECT b.posted_balance INTO v_wallet_balance
    FROM ledger.account_balances AS b
    JOIN ledger.accounts AS a USING (account_id)
   WHERE a.account_code = 'WALLET-SCHEMA-USD';

  IF v_funding_balance <> 1.00 OR v_wallet_balance <> 1.00 THEN
    RAISE EXCEPTION 'normal-side projection mismatch: funding %, wallet %',
      v_funding_balance, v_wallet_balance;
  END IF;

  BEGIN
    UPDATE ledger.ledger_entries
       SET amount = 0.50
     WHERE transaction_id = (
       SELECT transaction_id FROM ledger.transactions
        WHERE transaction_ref = 'TEST-SCHEMA-BALANCED'
     );
    RAISE EXCEPTION 'ledger entry update was accepted';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;

  BEGIN
    UPDATE ledger.accounts
       SET currency_code = 'JPY'
     WHERE account_code = 'WALLET-SCHEMA-USD';
    RAISE EXCEPTION 'account currency changed after posting';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
END
$test$;

ROLLBACK;

DO $test$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO ledger.transactions (
      transaction_ref, transaction_type, amount, currency_code,
      source_account_id, destination_account_id
    )
    SELECT 'TEST-SCHEMA-UNBALANCED', 'deposit', 1.00, 'USD',
           funding.account_id, wallet.account_id
      FROM ledger.accounts AS funding
      CROSS JOIN ledger.accounts AS wallet
     WHERE funding.account_code = 'SYS-FUND-SCHEMA-USD'
       AND wallet.account_code = 'WALLET-SCHEMA-USD';

    INSERT INTO ledger.ledger_entries (
      transaction_id, account_id, entry_side, amount, currency_code
    )
    SELECT t.transaction_id, a.account_id, 'debit', 1.00, 'USD'
      FROM ledger.transactions AS t
      JOIN ledger.accounts AS a ON a.account_code = 'SYS-FUND-SCHEMA-USD'
     WHERE t.transaction_ref = 'TEST-SCHEMA-UNBALANCED';

    UPDATE ledger.transactions
       SET status = 'posted', posted_at = transaction_timestamp()
     WHERE transaction_ref = 'TEST-SCHEMA-UNBALANCED';

    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'unbalanced journal reached commit validation';
  END IF;
  RAISE NOTICE 'deferred journal balance constraint: passed';
END
$test$;
