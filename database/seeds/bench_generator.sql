-- Deterministic synthetic ledger generator (administrator only; loads data with triggers/FKs bypassed
-- for speed via session_replication_role = replica, then RE-VERIFIES integrity before returning).
--
--   SELECT bench.generate(workspaces, entries_per_workspace, seed);
--
-- Determinism: every id is md5(kind:seed:key)::uuid and every "random" choice is derived from
-- md5(seed:key) — no random(), no clock — so the same arguments always produce identical data.
-- All data is synthetic. Workspace i has type family/student/personal/business for i%4 = 0/1/2/3.
-- Family workspaces have two extra members; member 1 ("bob") owns private accounts and private entries.
CREATE SCHEMA IF NOT EXISTS bench;

CREATE OR REPLACE FUNCTION bench.uid(p_kind text, p_seed text, p_key text) RETURNS uuid
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT md5(p_kind || ':' || p_seed || ':' || p_key)::uuid $$;

CREATE OR REPLACE FUNCTION bench.rnd(p_key text, p_mod int) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT (('x' || substr(md5(p_key), 1, 8))::bit(32)::bigint % p_mod)::int $$;

CREATE OR REPLACE FUNCTION bench.generate(p_workspaces int, p_entries int, p_seed text DEFAULT 'ledgerx') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_bad bigint;
BEGIN
  SET LOCAL session_replication_role = replica;

  INSERT INTO lx.users (id, auth_user_id, email, display_name)
  SELECT bench.uid('user', p_seed, i || '-' || m), bench.uid('auth', p_seed, i || '-' || m),
         'bench' || i || '_' || m || '@example.test', 'Synthetic user ' || i || '.' || m
    FROM generate_series(1, p_workspaces) i, generate_series(0, 2) m WHERE m = 0 OR i % 4 = 0;

  INSERT INTO lx.workspaces (id, type, name, base_currency, created_by)
  SELECT bench.uid('ws', p_seed, i::text), (ARRAY['family','student','personal','business'])[i % 4 + 1],
         'Synthetic workspace ' || i, 'INR', bench.uid('user', p_seed, i || '-0')
    FROM generate_series(1, p_workspaces) i;

  INSERT INTO lx.workspace_members (workspace_id, user_id, role)
  SELECT bench.uid('ws', p_seed, i::text), bench.uid('user', p_seed, i || '-' || m), (ARRAY['owner','member','admin'])[m + 1]
    FROM generate_series(1, p_workspaces) i, generate_series(0, 2) m WHERE m = 0 OR i % 4 = 0;

  -- shared chart for every workspace
  INSERT INTO lx.accounts (id, workspace_id, code, name, class, currency)
  SELECT bench.uid('acct', p_seed, i || ':' || c.code || ':'), bench.uid('ws', p_seed, i::text), c.code, c.name, c.class, 'INR'
    FROM generate_series(1, p_workspaces) i,
         (VALUES ('1000','Cash','asset'), ('1100','Bank','asset'), ('3000','Opening balance','equity'), ('4000','Salary','income'),
                 ('4010','Other income','income'), ('5000','Housing','expense'), ('5010','Food','expense'), ('5020','Transport','expense'),
                 ('5030','Utilities','expense'), ('5040','Health','expense'), ('5050','Entertainment','expense')) AS c(code, name, class);

  -- private accounts of family member 1
  INSERT INTO lx.accounts (id, workspace_id, code, name, class, currency, owner_user_id)
  SELECT bench.uid('acct', p_seed, i || ':' || c.code || ':' || bench.uid('user', p_seed, i || '-1')), bench.uid('ws', p_seed, i::text),
         c.code, c.name, c.class, 'INR', bench.uid('user', p_seed, i || '-1')
    FROM generate_series(1, p_workspaces) i, (VALUES ('P1','Private wallet','asset'), ('P2','Private spending','expense'), ('P3','Private income','income')) AS c(code, name, class)
   WHERE i % 4 = 0;

  CREATE TEMP TABLE bench_e ON COMMIT DROP AS
  SELECT i, n, bench.uid('entry', p_seed, i || ':' || n) AS id, bench.uid('ws', p_seed, i::text) AS ws,
         bench.rnd(p_seed || ':k:' || i || ':' || n, 100) AS k,
         (DATE '2024-01-01' + bench.rnd(p_seed || ':d:' || i || ':' || n, 730)) AS d,
         (bench.rnd(p_seed || ':a:' || i || ':' || n, 99900) + 100)::numeric / 100 AS amt,
         bench.rnd(p_seed || ':c:' || i || ':' || n, 6) AS cat,
         (i % 4 = 0 AND n % 7 = 0) AS priv
    FROM generate_series(1, p_workspaces) i, generate_series(1, p_entries) n;

  ALTER TABLE bench_e ADD kind text, ADD dr text, ADD cr text, ADD descr text, ADD bob uuid, ADD owner uuid;
  UPDATE bench_e SET bob = bench.uid('user', p_seed, i || '-1'), owner = bench.uid('user', p_seed, i || '-0');
  UPDATE bench_e SET
    kind  = CASE WHEN NOT priv AND k BETWEEN 8 AND 11 THEN 'transfer' ELSE 'standard' END,
    descr = CASE WHEN priv THEN CASE WHEN k < 30 THEN 'private income' ELSE 'private spend' END
                 WHEN k < 8 THEN 'income' WHEN k < 12 THEN 'transfer' ELSE 'expense' END,
    dr = CASE WHEN priv THEN CASE WHEN k < 30 THEN 'P1' ELSE 'P2' END
              WHEN k < 8 THEN CASE WHEN k % 2 = 0 THEN '1000' ELSE '1100' END
              WHEN k < 12 THEN '1100' ELSE (5000 + cat * 10)::text END,
    cr = CASE WHEN priv THEN CASE WHEN k < 30 THEN 'P3' ELSE 'P1' END
              WHEN k < 8 THEN '4000' WHEN k < 12 THEN '1000' ELSE CASE WHEN k % 2 = 0 THEN '1000' ELSE '1100' END END;

  INSERT INTO lx.journal_entries (id, workspace_id, entry_date, description, kind, private_owner_id, created_by, metadata)
  SELECT id, ws, d, descr, kind, CASE WHEN priv THEN bob END, CASE WHEN priv THEN bob ELSE owner END, '{}'::jsonb
    FROM bench_e ORDER BY i, n;

  INSERT INTO lx.journal_lines (id, workspace_id, entry_id, line_no, account_id, currency, debit, credit, private_owner_id)
  SELECT bench.uid('line', p_seed, e.id::text || ':' || l.no), e.ws, e.id, l.no,
         bench.uid('acct', p_seed, e.i || ':' || CASE l.no WHEN 1 THEN e.dr ELSE e.cr END || ':' || CASE WHEN e.priv THEN e.bob::text ELSE '' END),
         'INR', CASE l.no WHEN 1 THEN e.amt ELSE 0 END, CASE l.no WHEN 2 THEN e.amt ELSE 0 END, CASE WHEN e.priv THEN e.bob END
    FROM bench_e e CROSS JOIN (VALUES (1), (2)) AS l(no);

  INSERT INTO lx.account_balances (workspace_id, account_id, currency, debit_total, credit_total, line_count, private_owner_id)
  SELECT workspace_id, account_id, currency, sum(debit), sum(credit), count(*), max(private_owner_id::text)::uuid
    FROM lx.journal_lines WHERE workspace_id IN (SELECT DISTINCT ws FROM bench_e) GROUP BY workspace_id, account_id, currency;

  INSERT INTO lx.audit_events (workspace_id, actor_user_id, action, entity_type, details)
  SELECT bench.uid('ws', p_seed, i::text), bench.uid('user', p_seed, i || '-0'), 'workspace.created', 'workspace', '{"synthetic":true}'
    FROM generate_series(1, p_workspaces) i;

  SET LOCAL session_replication_role = origin;

  -- integrity re-verification (triggers were bypassed for speed)
  SELECT count(*) INTO v_bad FROM (SELECT entry_id FROM lx.journal_lines WHERE entry_id IN (SELECT id FROM bench_e)
                                    GROUP BY entry_id, currency HAVING sum(debit) <> sum(credit) OR count(*) < 2) x;
  IF v_bad > 0 THEN RAISE EXCEPTION 'generator produced % unbalanced entries', v_bad; END IF;
  SELECT count(*) INTO v_bad FROM lx.journal_lines l WHERE l.entry_id IN (SELECT id FROM bench_e)
     AND (NOT EXISTS (SELECT 1 FROM lx.accounts a WHERE a.id = l.account_id AND a.workspace_id = l.workspace_id AND a.currency = l.currency
                       AND a.owner_user_id IS NOT DISTINCT FROM l.private_owner_id)
       OR NOT EXISTS (SELECT 1 FROM lx.journal_entries e WHERE e.id = l.entry_id AND e.workspace_id = l.workspace_id
                       AND e.private_owner_id IS NOT DISTINCT FROM l.private_owner_id));
  IF v_bad > 0 THEN RAISE EXCEPTION 'generator produced % lines with broken references/visibility', v_bad; END IF;
END $$;
