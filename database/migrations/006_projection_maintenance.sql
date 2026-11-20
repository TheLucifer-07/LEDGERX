-- 006_projection_maintenance.sql : Projection verification and rebuild
-- Part of the LedgerX ledger core. Error codes (custom SQLSTATEs, mapped by callers):
--   LX401 no/invalid tenant context  LX403 forbidden  LX404 not found
--   LX409 conflict / idempotency      LX422 validation  LX423 immutable record

-- ============================================================ projection upkeep
CREATE FUNCTION lx.verify_account_balances()
RETURNS TABLE (account_id uuid, currency char(3), projected_debit numeric, projected_credit numeric,
               ledger_debit numeric, ledger_credit numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
#variable_conflict use_column
DECLARE v_ws uuid := lx.ctx_workspace(); v_user uuid := lx.ctx_user();
BEGIN
  PERFORM lx._require_ws(ARRAY['owner','admin'], false);
  RETURN QUERY
  WITH led AS (
    SELECT l.account_id, l.currency, sum(l.debit) AS d, sum(l.credit) AS c
      FROM lx.journal_lines l WHERE l.workspace_id = v_ws GROUP BY l.account_id, l.currency),
  prj AS (
    SELECT b.account_id, b.currency, b.debit_total AS d, b.credit_total AS c
      FROM lx.account_balances b WHERE b.workspace_id = v_ws)
  SELECT coalesce(prj.account_id, led.account_id), coalesce(prj.currency, led.currency),
         coalesce(prj.d, 0), coalesce(prj.c, 0), coalesce(led.d, 0), coalesce(led.c, 0)
    FROM prj FULL JOIN led ON led.account_id = prj.account_id
    JOIN lx.accounts a ON a.workspace_id = v_ws AND a.id = coalesce(prj.account_id, led.account_id)
   WHERE (a.owner_user_id IS NULL OR a.owner_user_id = v_user)
     AND (coalesce(prj.d, 0) <> coalesce(led.d, 0) OR coalesce(prj.c, 0) <> coalesce(led.c, 0));
END $$;

CREATE FUNCTION lx.rebuild_account_balances() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE v_ws uuid := lx.ctx_workspace(); n bigint;
BEGIN
  PERFORM lx._require_ws(ARRAY['owner','admin'], true);
  PERFORM pg_advisory_xact_lock(hashtextextended('lx:ws:' || v_ws::text, 0));  -- waits for in-flight posters
  DELETE FROM lx.account_balances WHERE workspace_id = v_ws;
  INSERT INTO lx.account_balances (workspace_id, account_id, currency, debit_total, credit_total, line_count, private_owner_id)
  SELECT workspace_id, account_id, currency, sum(debit), sum(credit), count(*), max(private_owner_id::text)::uuid
    FROM lx.journal_lines WHERE workspace_id = v_ws GROUP BY workspace_id, account_id, currency;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM lx._audit(v_ws, lx.ctx_user(), 'projection.rebuilt', 'account_balances', NULL, NULL,
                    jsonb_build_object('rows', n));
  RETURN n;
END $$;
