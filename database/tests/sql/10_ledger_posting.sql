-- Balanced postings, amount validation, multi-currency rules, idempotency (single session).
BEGIN;
SELECT plan(32);

CREATE TEMP TABLE fx AS SELECT t.mk_user('alice') AS u;
ALTER TABLE fx ADD ws uuid, ADD cash uuid, ADD bank uuid, ADD salary uuid, ADD food uuid, ADD usd_bank uuid, ADD usd_inc uuid, ADD jpy_a uuid, ADD jpy_b uuid, ADD raw_entry uuid;
UPDATE fx SET ws = t.mk_ws(u, 'personal', 'INR');
UPDATE fx SET cash = t.acct(ws,'1000'), bank = t.acct(ws,'1100'), salary = t.acct(ws,'4000'), food = t.acct(ws,'5010'),
  usd_bank = t.mk_account(u, ws, '1150', 'asset', 'USD'), usd_inc = t.mk_account(u, ws, '4150', 'income', 'USD'),
  jpy_a = t.mk_account(u, ws, '1160', 'asset', 'JPY'), jpy_b = t.mk_account(u, ws, '4160', 'income', 'JPY');

-- 1. balanced entries ------------------------------------------------------------------------
SELECT is(t.replayed(t.post(u, ws, t.lines(t.dr(cash,'1000.10'), t.cr(salary,'1000.10')))), false, 'balanced entry posts') FROM fx;
SELECT is(t.balance(cash), 1000.10, 'asset balance reflects the posting exactly') FROM fx;
SELECT is(t.balance(salary), 1000.10, 'income balance reflects the posting exactly') FROM fx;
SELECT matches(t.post(u, ws, t.lines(t.dr(cash,'100'), t.cr(salary,'99.99')))->>'error', 'not balanced', 'unbalanced entry is rejected with a clear message') FROM fx;
SELECT is(t.code(t.post(u, ws, t.lines(t.dr(cash,'100'), t.cr(salary,'99.99')))), 'LX422', 'unbalanced entry fails with LX422') FROM fx;

-- decimal exactness: ten postings of 0.10 sum to exactly 1.00 (no float drift)
DO $$ DECLARE r fx; BEGIN SELECT * INTO r FROM fx; FOR i IN 1..10 LOOP PERFORM t.post(r.u, r.ws, t.lines(t.dr(r.bank,'0.10'), t.cr(r.salary,'0.10'))); END LOOP; END $$;
SELECT is(t.balance(bank), 1.00, 'ten postings of 0.10 sum to exactly 1.00') FROM fx;

-- 2. amount validation ------------------------------------------------------------------------
SELECT is(t.code(t.post(u, ws, jsonb_build_array(jsonb_build_object('account_id', cash, 'debit', v), t.cr(salary,'5')))), 'LX422',
          format('invalid amount %L is rejected', v))
  FROM fx, unnest(ARRAY['0','-5','NaN','Infinity','1e3','1,000','']) AS v;
SELECT is(t.code(t.post(u, ws, jsonb_build_array(jsonb_build_object('account_id', cash, 'debit','5','credit','5'), t.cr(salary,'5')))), 'LX422', 'a line cannot carry both debit and credit') FROM fx;
SELECT is(t.code(t.post(u, ws, jsonb_build_array(t.dr(cash,'5')))), 'LX422', 'a single-line entry is rejected') FROM fx;
SELECT is(t.code(t.post(u, ws, jsonb_build_array(t.dr(cash,'5'), jsonb_build_object('account_id','not-a-uuid','credit','5')))), 'LX422', 'malformed account id is rejected') FROM fx;

-- 3. currencies -----------------------------------------------------------------------------
SELECT is(t.replayed(t.post(u, ws, t.lines(t.dr(cash,'100'), t.cr(salary,'100'), t.dr(usd_bank,'10'), t.cr(usd_inc,'10')))), false,
          'a multi-currency entry that balances in EACH currency posts') FROM fx;
SELECT matches(t.post(u, ws, t.lines(t.dr(cash,'100'), t.cr(usd_inc,'100')))->>'error', 'not balanced in', 'equal numbers in different currencies do NOT balance') FROM fx;
SELECT is((SELECT income FROM lx.v_monthly_cashflow WHERE workspace_id = ws AND currency = 'INR' AND month = '2026-11-01'), 1101.10, 'reporting keeps INR separate (1000.10 + 10 x 0.10 + 100)') FROM fx;
SELECT is((SELECT income FROM lx.v_monthly_cashflow WHERE workspace_id = ws AND currency = 'USD'), 10.00, 'reporting keeps USD separate (never summed with INR)') FROM fx;
SELECT is(t.code(t.post(u, ws, jsonb_build_array(jsonb_build_object('account_id', cash, 'debit','5','currency','USD'), t.cr(salary,'5')))), 'LX422', 'declared currency must equal the account currency') FROM fx;
SELECT is(t.code(t.post(u, ws, t.lines(t.dr(cash,'10.005'), t.cr(salary,'10.005')))), 'LX422', 'INR (2 minor units) rejects 3 decimals') FROM fx;
SELECT is(t.code(t.post(u, ws, t.lines(t.dr(jpy_a,'10.5'), t.cr(jpy_b,'10.5')))), 'LX422', 'JPY (0 minor units) rejects decimals') FROM fx;
SELECT is(t.replayed(t.post(u, ws, t.lines(t.dr(jpy_a,'10'), t.cr(jpy_b,'10')))), false, 'JPY accepts whole units') FROM fx;

-- schema-level: a direct insert (bypassing the API) cannot use a currency different from the account's
UPDATE fx SET raw_entry = (SELECT id FROM (SELECT gen_random_uuid() AS id) g);
INSERT INTO lx.journal_entries (id, workspace_id, entry_date, description, created_by) SELECT raw_entry, ws, '2026-11-01', 'raw', u FROM fx;
SELECT throws_ok(format($f$INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit) VALUES (%L,%L,1,%L,'USD',1)$f$, ws, raw_entry, cash),
                 '23503', NULL, 'composite FK rejects a line whose currency differs from its account') FROM fx;

-- 4. idempotency (sequential; races are tested in tests/multisession) ----------------------------
CREATE TEMP TABLE idem AS SELECT gen_random_uuid()::text AS k, t.post(u, ws, t.lines(t.dr(cash,'50'), t.cr(salary,'50')), 'idem-key-0001-fixed') AS first FROM fx;
SELECT is(t.entry_id(t.post(u, ws, t.lines(t.dr(cash,'50'), t.cr(salary,'50')), 'idem-key-0001-fixed')), t.entry_id(first), 'same key + same payload returns the original entry') FROM idem, fx;
SELECT is(t.replayed(t.post(u, ws, t.lines(t.dr(cash,'50'), t.cr(salary,'50')), 'idem-key-0001-fixed')), true, 'the replay is flagged as replayed') FROM fx;
SELECT is((SELECT count(*)::int FROM lx.idempotency_keys WHERE key = 'idem-key-0001-fixed'), 1, 'exactly one idempotency record exists') ;
SELECT is(t.replayed(t.post(u, ws, t.lines(t.dr(cash,'50.00'), t.cr(salary,'50.0')), 'idem-key-0001-fixed')), true, 'equivalent decimal spellings are the same request') FROM fx;
SELECT is(t.code(t.post(u, ws, t.lines(t.dr(cash,'51'), t.cr(salary,'51')), 'idem-key-0001-fixed')), 'LX409', 'same key with a different payload is a conflict') FROM fx;
SELECT is(t.code(t.post(u, ws, t.lines(t.dr(cash,'5'), t.cr(salary,'4')), 'idem-key-0002-fixed')), 'LX422', 'a failed post is rejected...') FROM fx;
SELECT is(t.replayed(t.post(u, ws, t.lines(t.dr(cash,'5'), t.cr(salary,'5')), 'idem-key-0002-fixed')), false, '...and does not consume its idempotency key') FROM fx;

SELECT * FROM finish();
ROLLBACK;
