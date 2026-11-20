-- 003_integrity_triggers.sql : Immutability, tenant/currency/precision guards, balance projection, deferred balance check
-- Part of the LedgerX ledger core. Error codes (custom SQLSTATEs, mapped by callers):
--   LX401 no/invalid tenant context  LX403 forbidden  LX404 not found
--   LX409 conflict / idempotency      LX422 validation  LX423 immutable record

-- ============================================================ integrity triggers
CREATE FUNCTION lx.trg_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% on % is not allowed: ledger records are immutable (post a reversal instead)',
    TG_OP, TG_TABLE_NAME USING ERRCODE = 'LX423';
END $$;

CREATE TRIGGER journal_entries_immutable BEFORE UPDATE OR DELETE ON lx.journal_entries
  FOR EACH ROW EXECUTE FUNCTION lx.trg_immutable();
CREATE TRIGGER journal_entries_no_truncate BEFORE TRUNCATE ON lx.journal_entries
  FOR EACH STATEMENT EXECUTE FUNCTION lx.trg_immutable();
CREATE TRIGGER journal_lines_immutable BEFORE UPDATE OR DELETE ON lx.journal_lines
  FOR EACH ROW EXECUTE FUNCTION lx.trg_immutable();
CREATE TRIGGER journal_lines_no_truncate BEFORE TRUNCATE ON lx.journal_lines
  FOR EACH STATEMENT EXECUTE FUNCTION lx.trg_immutable();
CREATE TRIGGER audit_events_immutable BEFORE UPDATE OR DELETE ON lx.audit_events
  FOR EACH ROW EXECUTE FUNCTION lx.trg_immutable();
CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON lx.audit_events
  FOR EACH STATEMENT EXECUTE FUNCTION lx.trg_immutable();

-- Account identity columns can never change (ledger lines depend on them).
CREATE FUNCTION lx.trg_account_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.id <> OLD.id OR NEW.workspace_id <> OLD.workspace_id OR NEW.currency <> OLD.currency
     OR NEW.class <> OLD.class OR NEW.code <> OLD.code
     OR NEW.owner_user_id IS DISTINCT FROM OLD.owner_user_id THEN
    RAISE EXCEPTION 'account identity (code, class, currency, owner, workspace) is immutable'
      USING ERRCODE = 'LX423';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER accounts_guard BEFORE UPDATE ON lx.accounts
  FOR EACH ROW EXECUTE FUNCTION lx.trg_account_guard();
CREATE TRIGGER accounts_no_delete BEFORE DELETE ON lx.accounts
  FOR EACH ROW EXECUTE FUNCTION lx.trg_immutable();

CREATE FUNCTION lx.trg_line_before_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE e record; a record; mu smallint;
BEGIN
  SELECT created_xid, private_owner_id INTO e
    FROM lx.journal_entries WHERE id = NEW.entry_id AND workspace_id = NEW.workspace_id;
  IF NOT FOUND OR e.created_xid <> pg_current_xact_id() THEN
    RAISE EXCEPTION 'lines may only be added in the transaction that created the entry'
      USING ERRCODE = 'LX423';
  END IF;
  SELECT owner_user_id INTO a FROM lx.accounts WHERE workspace_id = NEW.workspace_id AND id = NEW.account_id;
  IF FOUND THEN
    NEW.private_owner_id := a.owner_user_id;
    IF NEW.private_owner_id IS DISTINCT FROM e.private_owner_id THEN
      RAISE EXCEPTION 'entry visibility must match account ownership (private and shared accounts cannot be mixed)'
        USING ERRCODE = 'LX422';
    END IF;
  END IF;
  SELECT minor_unit INTO mu FROM lx.currencies WHERE code = NEW.currency;
  IF mu IS NULL OR scale(trim_scale(NEW.debit)) > mu OR scale(trim_scale(NEW.credit)) > mu THEN
    RAISE EXCEPTION 'amount has more decimal places than currency % allows', NEW.currency
      USING ERRCODE = 'LX422';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER journal_lines_before_insert BEFORE INSERT ON lx.journal_lines
  FOR EACH ROW EXECUTE FUNCTION lx.trg_line_before_insert();

CREATE FUNCTION lx.trg_line_after_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
BEGIN
  INSERT INTO lx.account_balances AS b
    (workspace_id, account_id, currency, debit_total, credit_total, line_count, private_owner_id)
  VALUES (NEW.workspace_id, NEW.account_id, NEW.currency, NEW.debit, NEW.credit, 1, NEW.private_owner_id)
  ON CONFLICT (workspace_id, account_id) DO UPDATE
    SET debit_total = b.debit_total + EXCLUDED.debit_total,
        credit_total = b.credit_total + EXCLUDED.credit_total,
        line_count = b.line_count + 1,
        updated_at = now();
  RETURN NULL;
END $$;
CREATE TRIGGER journal_lines_after_insert AFTER INSERT ON lx.journal_lines
  FOR EACH ROW EXECUTE FUNCTION lx.trg_line_after_insert();

-- Deferred safety net: evaluated at COMMIT, so it also protects against any direct insert.
CREATE FUNCTION lx.trg_entry_integrity() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE v_cnt int; v_bad record;
BEGIN
  SELECT count(*) INTO v_cnt FROM lx.journal_lines WHERE entry_id = NEW.entry_id;
  IF v_cnt < 2 THEN
    RAISE EXCEPTION 'journal entry % must have at least two lines', NEW.entry_id USING ERRCODE = 'LX422';
  END IF;
  SELECT currency, sum(debit) AS d, sum(credit) AS c INTO v_bad
    FROM lx.journal_lines WHERE entry_id = NEW.entry_id
   GROUP BY currency HAVING sum(debit) <> sum(credit) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'journal entry is not balanced in %: debits % <> credits %', v_bad.currency, v_bad.d, v_bad.c
      USING ERRCODE = 'LX422';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER journal_lines_entry_integrity AFTER INSERT ON lx.journal_lines
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION lx.trg_entry_integrity();
