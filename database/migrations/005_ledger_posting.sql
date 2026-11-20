-- 005_ledger_posting.sql : Idempotent posting and reversal of journal entries
-- Part of the LedgerX ledger core. Error codes (custom SQLSTATEs, mapped by callers):
--   LX401 no/invalid tenant context  LX403 forbidden  LX404 not found
--   LX409 conflict / idempotency      LX422 validation  LX423 immutable record

-- ============================================================== ledger posting
CREATE FUNCTION lx._claim_idempotency(p_ws uuid, p_user uuid, p_key text, p_op text, p_hash bytea)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE n int; r record;
BEGIN
  INSERT INTO lx.idempotency_keys (workspace_id, key, user_id, operation, request_hash)
  VALUES (p_ws, p_key, p_user, p_op, p_hash) ON CONFLICT (workspace_id, key) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 1 THEN RETURN NULL; END IF;
  SELECT * INTO r FROM lx.idempotency_keys WHERE workspace_id = p_ws AND key = p_key;
  IF r.user_id <> p_user OR r.operation <> p_op OR r.request_hash <> p_hash THEN
    RAISE EXCEPTION 'idempotency key was already used for a different request' USING ERRCODE = 'LX409';
  END IF;
  IF r.entry_id IS NULL THEN
    RAISE EXCEPTION 'a request with this idempotency key is still in progress' USING ERRCODE = 'LX409';
  END IF;
  RETURN r.entry_id;
END $$;

CREATE FUNCTION lx.post_journal_entry(p_key text, p_date date, p_description text, p_lines jsonb,
                                      p_kind text DEFAULT 'standard', p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (entry_id uuid, replayed boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
#variable_conflict use_column
DECLARE
  v_ws uuid := lx.ctx_workspace(); v_user uuid := lx.ctx_user();
  v_norm jsonb; v_hash bytea; v_existing uuid; v_entry uuid;
  v_priv int; v_shared int; v_bad record;
BEGIN
  PERFORM lx._require_ws(ARRAY['owner','admin','member'], true);
  -- shared lock: many posters run concurrently; projection rebuild takes it exclusively
  PERFORM pg_advisory_xact_lock_shared(hashtextextended('lx:ws:' || v_ws::text, 0));

  IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 200 THEN
    RAISE EXCEPTION 'idempotency key must be 8-200 characters' USING ERRCODE = 'LX422'; END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'entry date is required' USING ERRCODE = 'LX422'; END IF;
  IF p_description IS NULL OR length(btrim(p_description)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'description must be 1-500 characters' USING ERRCODE = 'LX422'; END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('standard','transfer','opening_balance') THEN
    RAISE EXCEPTION 'invalid entry kind' USING ERRCODE = 'LX422'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 2 AND 200 THEN
    RAISE EXCEPTION 'an entry needs 2 to 200 lines' USING ERRCODE = 'LX422'; END IF;

  -- strict amount syntax is enforced below: decimal strings only (rejects NaN, Infinity, exponents)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) e
              WHERE jsonb_typeof(e) <> 'object') THEN
    RAISE EXCEPTION 'malformed line' USING ERRCODE = 'LX422'; END IF;

  BEGIN
    SELECT jsonb_agg(jsonb_build_object(
             'a', (e->>'account_id')::uuid,
             'd', trim_scale(coalesce(nullif(e->>'debit',''),'0')::numeric)::text,
             'c', trim_scale(coalesce(nullif(e->>'credit',''),'0')::numeric)::text,
             'k', nullif(e->>'currency',''),
             'm', e->>'memo') ORDER BY ord)
      INTO v_norm
      FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(e, ord)
     WHERE coalesce(e->>'debit','0')  ~ '^[0-9]{1,18}(\.[0-9]{1,6})?$'
       AND coalesce(e->>'credit','0') ~ '^[0-9]{1,18}(\.[0-9]{1,6})?$';
  EXCEPTION WHEN data_exception THEN
    RAISE EXCEPTION 'malformed line (account id or amount)' USING ERRCODE = 'LX422';
  END;
  IF v_norm IS NULL OR jsonb_array_length(v_norm) <> jsonb_array_length(p_lines) THEN
    RAISE EXCEPTION 'amounts must be plain decimal strings with at most 6 decimals' USING ERRCODE = 'LX422'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_norm) l
              WHERE ((l->>'d')::numeric > 0) = ((l->>'c')::numeric > 0)) THEN
    RAISE EXCEPTION 'each line needs exactly one positive debit or credit' USING ERRCODE = 'LX422'; END IF;

  v_hash := sha256(convert_to(jsonb_build_object('op','post','date',p_date,'desc',btrim(p_description),
                  'kind',p_kind,'lines',v_norm,'meta',coalesce(p_metadata,'{}'::jsonb))::text, 'UTF8'));
  v_existing := lx._claim_idempotency(v_ws, v_user, p_key, 'post', v_hash);
  IF v_existing IS NOT NULL THEN
    RETURN QUERY SELECT v_existing, true; RETURN;
  END IF;

  -- accounts must exist in THIS workspace, be active and visible to the caller
  IF (SELECT count(*) FROM jsonb_array_elements(v_norm) l
        JOIN lx.accounts a ON a.workspace_id = v_ws AND a.id = (l->>'a')::uuid
         AND a.is_active AND (a.owner_user_id IS NULL OR a.owner_user_id = v_user)) <> jsonb_array_length(v_norm) THEN
    RAISE EXCEPTION 'one or more accounts do not exist or are not available' USING ERRCODE = 'LX422'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_norm) l JOIN lx.accounts a ON a.id = (l->>'a')::uuid
              WHERE l->>'k' IS NOT NULL AND l->>'k' <> a.currency::text) THEN
    RAISE EXCEPTION 'line currency does not match the account currency' USING ERRCODE = 'LX422'; END IF;
  IF p_kind = 'transfer' AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_norm) l
        JOIN lx.accounts a ON a.id = (l->>'a')::uuid WHERE a.class NOT IN ('asset','liability')) THEN
    RAISE EXCEPTION 'transfers may only move value between asset/liability accounts' USING ERRCODE = 'LX422'; END IF;

  SELECT count(*) FILTER (WHERE a.owner_user_id IS NOT NULL), count(*) FILTER (WHERE a.owner_user_id IS NULL)
    INTO v_priv, v_shared
    FROM jsonb_array_elements(v_norm) l JOIN lx.accounts a ON a.id = (l->>'a')::uuid;
  IF v_priv > 0 AND v_shared > 0 THEN
    RAISE EXCEPTION 'private and shared accounts cannot be mixed in one entry' USING ERRCODE = 'LX422'; END IF;

  INSERT INTO lx.journal_entries (workspace_id, entry_date, description, kind, private_owner_id, created_by, metadata)
  VALUES (v_ws, p_date, btrim(p_description), p_kind, CASE WHEN v_priv > 0 THEN v_user END, v_user,
          coalesce(p_metadata, '{}'::jsonb))
  RETURNING id INTO v_entry;

  -- deterministic account order => consistent lock order for projection upserts (no deadlocks)
  INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit, credit, memo)
  SELECT v_ws, v_entry, t.ord::int, (t.l->>'a')::uuid, a.currency,
         (t.l->>'d')::numeric, (t.l->>'c')::numeric, t.l->>'m'
    FROM jsonb_array_elements(v_norm) WITH ORDINALITY AS t(l, ord)
    JOIN lx.accounts a ON a.workspace_id = v_ws AND a.id = (t.l->>'a')::uuid
   ORDER BY (t.l->>'a')::uuid, t.ord;

  SELECT currency, sum(debit) AS d, sum(credit) AS c INTO v_bad
    FROM lx.journal_lines WHERE entry_id = v_entry
   GROUP BY currency HAVING sum(debit) <> sum(credit) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'journal entry is not balanced in %: debits % <> credits %', v_bad.currency, v_bad.d, v_bad.c
      USING ERRCODE = 'LX422'; END IF;

  UPDATE lx.idempotency_keys SET entry_id = v_entry WHERE workspace_id = v_ws AND key = p_key;
  PERFORM lx._audit(v_ws, v_user, 'journal.posted', 'journal_entry', v_entry,
                    CASE WHEN v_priv > 0 THEN v_user END, jsonb_build_object('kind', p_kind, 'date', p_date));
  RETURN QUERY SELECT v_entry, false;
END $$;

CREATE FUNCTION lx.reverse_journal_entry(p_entry_id uuid, p_key text, p_reason text, p_date date DEFAULT NULL)
RETURNS TABLE (entry_id uuid, replayed boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
#variable_conflict use_column
DECLARE
  v_ws uuid := lx.ctx_workspace(); v_user uuid := lx.ctx_user(); v_role text;
  v_hash bytea; v_existing uuid; v_new uuid; o record; v_date date := coalesce(p_date, current_date);
BEGIN
  v_role := lx._require_ws(ARRAY['owner','admin','member'], true);
  PERFORM pg_advisory_xact_lock_shared(hashtextextended('lx:ws:' || v_ws::text, 0));
  IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 200 THEN
    RAISE EXCEPTION 'idempotency key must be 8-200 characters' USING ERRCODE = 'LX422'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'a reason (1-500 characters) is required' USING ERRCODE = 'LX422'; END IF;

  v_hash := sha256(convert_to(jsonb_build_object('op','reverse','entry',p_entry_id,
                  'reason',btrim(p_reason),'date',v_date)::text, 'UTF8'));
  v_existing := lx._claim_idempotency(v_ws, v_user, p_key, 'reverse', v_hash);
  IF v_existing IS NOT NULL THEN RETURN QUERY SELECT v_existing, true; RETURN; END IF;

  SELECT * INTO o FROM lx.journal_entries
   WHERE id = p_entry_id AND workspace_id = v_ws
     AND (private_owner_id IS NULL OR private_owner_id = v_user)
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'journal entry not found' USING ERRCODE = 'LX404'; END IF;
  IF v_role = 'member' AND o.private_owner_id IS NULL AND o.created_by <> v_user THEN
    RAISE EXCEPTION 'members may only reverse their own entries' USING ERRCODE = 'LX403'; END IF;
  IF o.kind = 'reversal' THEN
    RAISE EXCEPTION 'a reversal cannot itself be reversed' USING ERRCODE = 'LX422'; END IF;
  IF EXISTS (SELECT 1 FROM lx.journal_entries WHERE workspace_id = v_ws AND reverses_entry_id = o.id) THEN
    RAISE EXCEPTION 'journal entry has already been reversed' USING ERRCODE = 'LX409'; END IF;

  INSERT INTO lx.journal_entries (workspace_id, entry_date, description, kind, reverses_entry_id,
                                  reversal_reason, private_owner_id, created_by, metadata)
  VALUES (v_ws, v_date, 'Reversal of: ' || left(o.description, 480), 'reversal', o.id, btrim(p_reason),
          o.private_owner_id, v_user, jsonb_build_object('reverses', o.id))
  RETURNING id INTO v_new;

  INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit, credit, memo)
  SELECT v_ws, v_new, l.line_no, l.account_id, l.currency, l.credit, l.debit, l.memo
    FROM lx.journal_lines l WHERE l.entry_id = o.id
   ORDER BY l.account_id, l.line_no;

  UPDATE lx.idempotency_keys SET entry_id = v_new WHERE workspace_id = v_ws AND key = p_key;
  PERFORM lx._audit(v_ws, v_user, 'journal.reversed', 'journal_entry', v_new, o.private_owner_id,
                    jsonb_build_object('reverses', o.id));
  RETURN QUERY SELECT v_new, false;
END $$;
