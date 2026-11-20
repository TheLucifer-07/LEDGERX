-- Test helpers (schema "t"). Installed into the TEST database only, together with pgTAP (schema "tap").
-- Setup runs as the administrator; statements UNDER TEST run as the real application roles via
-- t.run_as / t.exec_role, so privilege and RLS behaviour is exercised for real. pgTAP assertions run
-- as the administrator because pgTAP needs temporary tables, which the application roles must not have.
CREATE SCHEMA IF NOT EXISTS t;

-- Run a SELECT as ledgerx_runtime with a verified tenant context.
-- Returns {"rows":[...]} or {"error_code":SQLSTATE,"error":message}. NULL user => no context at all.
CREATE OR REPLACE FUNCTION t.run_as(p_user uuid, p_ws uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    SET LOCAL ROLE ledgerx_runtime;
    IF p_user IS NULL THEN
      PERFORM set_config('lx.user_id', '', true);
      PERFORM set_config('lx.workspace_id', '', true);
    ELSE
      PERFORM lx.set_context(p_user, p_ws);
    END IF;
    EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) FROM (%s) q', p_sql) INTO v;
    RESET ROLE;
    RETURN jsonb_build_object('rows', v);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN jsonb_build_object('error_code', SQLSTATE, 'error', SQLERRM);
  END;
END $$;

-- Run any statement as a given role (no context); returns {"ok":true} or the error object.
CREATE OR REPLACE FUNCTION t.exec_role(p_role text, p_sql text, p_user uuid DEFAULT NULL, p_ws uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    IF p_user IS NOT NULL THEN PERFORM lx.set_context(p_user, p_ws); END IF;
    EXECUTE p_sql;
    RESET ROLE;
    RETURN jsonb_build_object('ok', true);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN jsonb_build_object('error_code', SQLSTATE, 'error', SQLERRM);
  END;
END $$;

CREATE OR REPLACE FUNCTION t.code(j jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT j->>'error_code' $$;

-- fixtures (administrator context) ------------------------------------------------------------
CREATE OR REPLACE FUNCTION t.mk_user(p_label text DEFAULT 'u') RETURNS uuid LANGUAGE sql AS $$
  SELECT lx.provision_user(gen_random_uuid(), p_label || '-' || substr(gen_random_uuid()::text, 1, 8) || '@example.test', p_label)
$$;

CREATE OR REPLACE FUNCTION t.mk_ws(p_user uuid, p_type text DEFAULT 'personal', p_cur text DEFAULT 'INR') RETURNS uuid
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM lx.set_context(p_user, NULL);
  RETURN lx.create_workspace(p_type, p_type || ' workspace', p_cur);
END $$;

CREATE OR REPLACE FUNCTION t.add_member(p_ws uuid, p_user uuid, p_role text DEFAULT 'member') RETURNS void LANGUAGE sql AS $$
  INSERT INTO lx.workspace_members (workspace_id, user_id, role) VALUES (p_ws, p_user, p_role)
$$;

CREATE OR REPLACE FUNCTION t.acct(p_ws uuid, p_code text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM lx.accounts WHERE workspace_id = p_ws AND code = p_code AND owner_user_id IS NULL
$$;

-- create an account as the user (administrator-level call of the definer API with context set)
CREATE OR REPLACE FUNCTION t.mk_account(p_user uuid, p_ws uuid, p_code text, p_class text, p_cur text, p_private boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM lx.set_context(p_user, p_ws);
  RETURN lx.create_account(p_code, p_code || ' account', p_class, NULL, p_cur, p_private);
END $$;

CREATE OR REPLACE FUNCTION t.dr(p_account uuid, p_amount text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('account_id', p_account, 'debit', p_amount) $$;
CREATE OR REPLACE FUNCTION t.cr(p_account uuid, p_amount text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('account_id', p_account, 'credit', p_amount) $$;
CREATE OR REPLACE FUNCTION t.lines(VARIADIC p_lines jsonb[]) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$ SELECT to_jsonb(p_lines) $$;

-- post / reverse as the runtime role -----------------------------------------------------------
CREATE OR REPLACE FUNCTION t.post(p_user uuid, p_ws uuid, p_lines jsonb, p_key text DEFAULT NULL,
                                  p_kind text DEFAULT 'standard', p_desc text DEFAULT 'test entry') RETURNS jsonb
LANGUAGE sql AS $$
  SELECT t.run_as(p_user, p_ws, format('SELECT * FROM lx.post_journal_entry(%L, %L, %L, %L::jsonb, %L)',
         coalesce(p_key, gen_random_uuid()::text), '2026-11-01', p_desc, p_lines, p_kind))
$$;

CREATE OR REPLACE FUNCTION t.reverse(p_user uuid, p_ws uuid, p_entry uuid, p_key text DEFAULT NULL, p_reason text DEFAULT 'test reversal') RETURNS jsonb
LANGUAGE sql AS $$
  SELECT t.run_as(p_user, p_ws, format('SELECT * FROM lx.reverse_journal_entry(%L, %L, %L)',
         p_entry, coalesce(p_key, gen_random_uuid()::text), p_reason))
$$;

CREATE OR REPLACE FUNCTION t.entry_id(j jsonb) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT (j->'rows'->0->>'entry_id')::uuid $$;
CREATE OR REPLACE FUNCTION t.replayed(j jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT (j->'rows'->0->>'replayed')::boolean $$;

-- balance of an account according to the ledger view (administrator view, bypasses RLS)
CREATE OR REPLACE FUNCTION t.balance(p_account uuid) RETURNS numeric LANGUAGE sql AS $$
  SELECT balance FROM lx.v_account_balances WHERE account_id = p_account $$;

-- number of rows the runtime role sees in a relation, under a context
CREATE OR REPLACE FUNCTION t.visible(p_user uuid, p_ws uuid, p_relation text, p_where text DEFAULT 'true') RETURNS int
LANGUAGE sql AS $$
  SELECT (t.run_as(p_user, p_ws, format('SELECT count(*)::int AS n FROM %s WHERE %s', p_relation, p_where))->'rows'->0->>'n')::int $$;

-- Like t.run_as but sets the raw settings WITHOUT lx.set_context (simulates a forged context).
CREATE OR REPLACE FUNCTION t.run_forged(p_user text, p_ws text, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    SET LOCAL ROLE ledgerx_runtime;
    PERFORM set_config('lx.user_id', p_user, true);
    PERFORM set_config('lx.workspace_id', p_ws, true);
    EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) FROM (%s) q', p_sql) INTO v;
    RESET ROLE;
    RETURN jsonb_build_object('rows', v);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN jsonb_build_object('error_code', SQLSTATE, 'error', SQLERRM);
  END;
END $$;
