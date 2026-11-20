-- 004_workspace_api.sql : User provisioning, workspaces, chart seeding, accounts, invitations
-- Part of the LedgerX ledger core. Error codes (custom SQLSTATEs, mapped by callers):
--   LX401 no/invalid tenant context  LX403 forbidden  LX404 not found
--   LX409 conflict / idempotency      LX422 validation  LX423 immutable record

-- ==================================================================== user API
CREATE FUNCTION lx.provision_user(p_auth_user_id uuid, p_email text, p_display_name text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE v_id uuid; v_deleted timestamptz;
BEGIN
  IF p_auth_user_id IS NULL OR p_email IS NULL THEN
    RAISE EXCEPTION 'auth user id and email are required' USING ERRCODE = 'LX422';
  END IF;
  SELECT id, deleted_at INTO v_id, v_deleted FROM lx.users WHERE auth_user_id = p_auth_user_id;
  IF v_id IS NOT NULL THEN
    IF v_deleted IS NOT NULL THEN RAISE EXCEPTION 'account is deleted' USING ERRCODE = 'LX403'; END IF;
    RETURN v_id;
  END IF;
  INSERT INTO lx.users (auth_user_id, email, display_name)
  VALUES (p_auth_user_id, p_email, left(p_display_name, 120)) RETURNING id INTO v_id;
  PERFORM lx._audit(NULL, v_id, 'user.provisioned', 'user', v_id, NULL, '{}');
  RETURN v_id;
END $$;

-- ============================================================== workspace API
CREATE FUNCTION lx.seed_chart(p_ws uuid, p_type text, p_currency char(3)) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
  INSERT INTO lx.accounts (workspace_id, code, name, class, subtype, currency)
  SELECT p_ws, v.code, v.name, v.class, v.subtype, p_currency
  FROM (VALUES
    (ARRAY['student','personal','family','business'], '1000', 'Cash',                   'asset',     'cash'),
    (ARRAY['student','personal','family','business'], '1100', 'Bank Account',           'asset',     'bank'),
    (ARRAY['student','personal','family','business'], '3000', 'Opening Balance Equity', 'equity',    'opening'),
    (ARRAY['business'],                               '1200', 'Accounts Receivable',    'asset',     'receivable'),
    (ARRAY['business'],                               '2000', 'Accounts Payable',       'liability', 'payable'),
    (ARRAY['student'], '4000', 'Allowance',          'income', NULL),
    (ARRAY['student'], '4010', 'Scholarship',        'income', NULL),
    (ARRAY['student'], '4020', 'Part-time Income',   'income', NULL),
    (ARRAY['student'], '4030', 'Gifts',              'income', NULL),
    (ARRAY['student'], '5000', 'Food',               'expense', NULL),
    (ARRAY['student'], '5010', 'Transport',          'expense', NULL),
    (ARRAY['student'], '5020', 'College Fees',       'expense', NULL),
    (ARRAY['student'], '5030', 'Study Materials',    'expense', NULL),
    (ARRAY['student'], '5040', 'Subscriptions',      'expense', NULL),
    (ARRAY['student'], '5900', 'Other Expenses',     'expense', NULL),
    (ARRAY['personal'], '4000', 'Salary',            'income', NULL),
    (ARRAY['personal'], '4010', 'Other Income',      'income', NULL),
    (ARRAY['personal'], '4020', 'Interest',          'income', NULL),
    (ARRAY['personal'], '5000', 'Housing',           'expense', NULL),
    (ARRAY['personal'], '5010', 'Food & Groceries',  'expense', NULL),
    (ARRAY['personal'], '5020', 'Transport',         'expense', NULL),
    (ARRAY['personal'], '5030', 'Utilities',         'expense', NULL),
    (ARRAY['personal'], '5040', 'Health',            'expense', NULL),
    (ARRAY['personal'], '5050', 'Entertainment',     'expense', NULL),
    (ARRAY['personal'], '5900', 'Other Expenses',    'expense', NULL),
    (ARRAY['family'],   '4000', 'Member Contributions', 'income', NULL),
    (ARRAY['family'],   '4010', 'Other Income',      'income', NULL),
    (ARRAY['family'],   '5000', 'Housing',           'expense', NULL),
    (ARRAY['family'],   '5010', 'Groceries',         'expense', NULL),
    (ARRAY['family'],   '5020', 'Utilities',         'expense', NULL),
    (ARRAY['family'],   '5030', 'Education',         'expense', NULL),
    (ARRAY['family'],   '5040', 'Health',            'expense', NULL),
    (ARRAY['family'],   '5050', 'Transport',         'expense', NULL),
    (ARRAY['family'],   '5900', 'Other Expenses',    'expense', NULL),
    (ARRAY['business'], '4000', 'Sales Revenue',     'income', NULL),
    (ARRAY['business'], '4010', 'Other Income',      'income', NULL),
    (ARRAY['business'], '5000', 'Cost of Goods Sold','expense', NULL),
    (ARRAY['business'], '5010', 'Rent',              'expense', NULL),
    (ARRAY['business'], '5020', 'Salaries & Wages',  'expense', NULL),
    (ARRAY['business'], '5030', 'Software & Subscriptions', 'expense', NULL),
    (ARRAY['business'], '5040', 'Marketing',         'expense', NULL),
    (ARRAY['business'], '5900', 'Other Expenses',    'expense', NULL)
  ) AS v(types, code, name, class, subtype)
  WHERE p_type = ANY (v.types)
$$;

CREATE FUNCTION lx.create_workspace(p_type text, p_name text, p_currency char(3)) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE v_user uuid := lx.ctx_user(); v_ws uuid;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'user context is required' USING ERRCODE = 'LX401'; END IF;
  IF p_type IS NULL OR p_type NOT IN ('student','personal','family','business') THEN
    RAISE EXCEPTION 'invalid workspace type' USING ERRCODE = 'LX422';
  END IF;
  IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'workspace name must be 1-120 characters' USING ERRCODE = 'LX422';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM lx.currencies WHERE code = p_currency) THEN
    RAISE EXCEPTION 'unsupported currency' USING ERRCODE = 'LX422';
  END IF;
  IF (SELECT count(*) FROM lx.workspace_members WHERE user_id = v_user AND role = 'owner' AND status = 'active') >= 20 THEN
    RAISE EXCEPTION 'workspace limit reached' USING ERRCODE = 'LX422';
  END IF;
  INSERT INTO lx.workspaces (type, name, base_currency, created_by)
  VALUES (p_type, btrim(p_name), p_currency, v_user) RETURNING id INTO v_ws;
  INSERT INTO lx.workspace_members (workspace_id, user_id, role) VALUES (v_ws, v_user, 'owner');
  PERFORM lx.seed_chart(v_ws, p_type, p_currency);
  PERFORM lx._audit(v_ws, v_user, 'workspace.created', 'workspace', v_ws, NULL,
                    jsonb_build_object('type', p_type, 'currency', p_currency));
  RETURN v_ws;
END $$;

CREATE FUNCTION lx.create_account(p_code text, p_name text, p_class text, p_subtype text,
                                  p_currency char(3), p_private boolean DEFAULT false,
                                  p_parent uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE v_role text; v_ws uuid := lx.ctx_workspace(); v_user uuid := lx.ctx_user();
        v_owner uuid; v_id uuid; par record;
BEGIN
  v_role := lx._require_ws(ARRAY['owner','admin','member'], true);
  IF NOT coalesce(p_private, false) AND v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'only owners and admins may create shared accounts' USING ERRCODE = 'LX403';
  END IF;
  v_owner := CASE WHEN coalesce(p_private, false) THEN v_user END;
  IF p_parent IS NOT NULL THEN
    SELECT class, owner_user_id INTO par FROM lx.accounts
     WHERE workspace_id = v_ws AND id = p_parent AND (owner_user_id IS NULL OR owner_user_id = v_user);
    IF NOT FOUND OR par.class <> p_class OR par.owner_user_id IS DISTINCT FROM v_owner THEN
      RAISE EXCEPTION 'invalid parent account' USING ERRCODE = 'LX422';
    END IF;
  END IF;
  INSERT INTO lx.accounts (workspace_id, code, name, class, subtype, currency, parent_id, owner_user_id)
  VALUES (v_ws, p_code, btrim(p_name), p_class, p_subtype, p_currency, p_parent, v_owner)
  RETURNING id INTO v_id;
  PERFORM lx._audit(v_ws, v_user, 'account.created', 'account', v_id, v_owner,
                    jsonb_build_object('code', p_code, 'class', p_class, 'currency', p_currency));
  RETURN v_id;
END $$;

CREATE FUNCTION lx.create_invitation(p_email text, p_role text)
RETURNS TABLE (invitation_id uuid, token text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lx, pg_catalog AS $$
DECLARE v_ws uuid := lx.ctx_workspace(); v_user uuid := lx.ctx_user(); v_token text; v_id uuid; v_type text;
BEGIN
  PERFORM lx._require_ws(ARRAY['owner','admin'], true);
  SELECT type INTO v_type FROM lx.workspaces WHERE id = v_ws;
  IF v_type NOT IN ('family','business') THEN
    RAISE EXCEPTION 'only family and business workspaces support invitations' USING ERRCODE = 'LX422';
  END IF;
  IF p_role IS NULL OR p_role NOT IN ('admin','member','viewer') THEN
    RAISE EXCEPTION 'invalid role' USING ERRCODE = 'LX422';
  END IF;
  IF p_email IS NULL OR p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'invalid email' USING ERRCODE = 'LX422';
  END IF;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO lx.invitations (workspace_id, email, role, token_hash, invited_by, expires_at)
  VALUES (v_ws, lower(p_email), p_role, sha256(convert_to(v_token, 'UTF8')), v_user, now() + interval '7 days')
  RETURNING id INTO v_id;
  PERFORM lx._audit(v_ws, v_user, 'invitation.created', 'invitation', v_id, NULL,
                    jsonb_build_object('role', p_role));
  RETURN QUERY SELECT v_id, v_token;
END $$;
