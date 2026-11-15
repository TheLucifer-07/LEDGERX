-- Purpose: introduce workspace ownership, role permissions, tenant-aware keys,
-- composite foreign keys, and fail-closed row-level security without rewriting
-- any of the already-applied financial migrations.

CREATE TABLE ledger.app_users (
  user_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supabase_user_id uuid NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TABLE ledger.workspaces (
  workspace_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_type text NOT NULL CHECK (workspace_type IN (
    'student', 'personal', 'family', 'business', 'demo', 'legacy'
  )),
  workspace_name text NOT NULL CHECK (
    length(btrim(workspace_name)) BETWEEN 1 AND 120
  ),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended', 'archived')),
  is_public_demo boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT workspaces_public_demo_type_ck
    CHECK (NOT is_public_demo OR workspace_type = 'demo')
);

CREATE TABLE ledger.workspace_memberships (
  membership_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES ledger.workspaces(workspace_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES ledger.app_users(user_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  role text NOT NULL CHECK (role IN (
    'owner', 'administrator', 'analyst', 'auditor', 'member', 'viewer'
  )),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended')),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT workspace_memberships_workspace_user_uq
    UNIQUE (workspace_id, user_id),
  CONSTRAINT workspace_memberships_workspace_membership_uq
    UNIQUE (workspace_id, membership_id)
);
CREATE UNIQUE INDEX workspace_memberships_one_owner_uq
  ON ledger.workspace_memberships(workspace_id)
  WHERE role = 'owner';
CREATE INDEX workspace_memberships_user_active_idx
  ON ledger.workspace_memberships(user_id, workspace_id)
  WHERE status = 'active';

CREATE TABLE ledger.workspace_role_permissions (
  role text NOT NULL CHECK (role IN (
    'owner', 'administrator', 'analyst', 'auditor', 'member', 'viewer'
  )),
  permission text NOT NULL CHECK (length(btrim(permission)) > 0),
  PRIMARY KEY (role, permission)
);

INSERT INTO ledger.workspace_role_permissions(role, permission)
SELECT role_name, permission_name
  FROM (VALUES
    ('owner', ARRAY[
      'workspace.read', 'workspace.settings.manage',
      'workspace.members.read', 'workspace.members.manage',
      'finance.read', 'finance.write', 'finance.import', 'finance.export',
      'reports.read', 'reconciliation.read', 'reconciliation.manage',
      'audit.read', 'ai.use'
    ]),
    ('administrator', ARRAY[
      'workspace.read', 'workspace.settings.manage',
      'workspace.members.read', 'workspace.members.manage',
      'finance.read', 'finance.write', 'finance.import', 'finance.export',
      'reports.read', 'reconciliation.read', 'reconciliation.manage',
      'audit.read', 'ai.use'
    ]),
    ('analyst', ARRAY[
      'workspace.read', 'finance.read', 'reports.read',
      'reconciliation.read'
    ]),
    ('auditor', ARRAY[
      'workspace.read', 'finance.read', 'reports.read',
      'reconciliation.read', 'audit.read'
    ]),
    ('member', ARRAY[
      'workspace.read', 'finance.read', 'finance.write', 'finance.import',
      'finance.export', 'reports.read', 'reconciliation.read', 'ai.use'
    ]),
    ('viewer', ARRAY[
      'workspace.read', 'finance.read', 'reports.read'
    ])
  ) AS role_matrix(role_name, permissions)
 CROSS JOIN LATERAL unnest(permissions) AS permission_list(permission_name);

-- INR is the requested new-workspace default. It was not present in the
-- original transaction-processing reference data, so add the ISO currency row
-- without changing any existing currency or financial record.
INSERT INTO ledger.currencies(currency_code, name, minor_unit, active)
VALUES ('INR', 'Indian Rupee', 2, true)
ON CONFLICT (currency_code) DO NOTHING;

CREATE TABLE ledger.workspace_settings (
  workspace_id uuid PRIMARY KEY REFERENCES ledger.workspaces(workspace_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  default_currency_code text NOT NULL DEFAULT 'INR'
    REFERENCES ledger.currencies(currency_code)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  timezone_name text NOT NULL DEFAULT 'Asia/Kolkata'
    CHECK (length(btrim(timezone_name)) BETWEEN 1 AND 100),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TABLE ledger.workspace_invitations (
  invitation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES ledger.workspaces(workspace_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  invitee_email text NOT NULL CHECK (
    invitee_email = lower(btrim(invitee_email))
      AND length(invitee_email) BETWEEN 3 AND 320
  ),
  role text NOT NULL CHECK (role IN (
    'administrator', 'analyst', 'auditor', 'member', 'viewer'
  )),
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'revoked', 'expired')),
  invited_by_user_id uuid NOT NULL REFERENCES ledger.app_users(user_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  accepted_at timestamptz,
  CONSTRAINT workspace_invitations_acceptance_ck CHECK (
    (status = 'accepted' AND accepted_at IS NOT NULL)
    OR (status <> 'accepted' AND accepted_at IS NULL)
  )
);
CREATE UNIQUE INDEX workspace_invitations_pending_email_uq
  ON ledger.workspace_invitations(workspace_id, invitee_email)
  WHERE status = 'pending';

-- These fixed UUIDs identify system-owned workspaces only. They are not user
-- identities or credentials. Existing records stay private in the legacy one.
INSERT INTO ledger.workspaces (
  workspace_id, workspace_type, workspace_name, is_public_demo
) VALUES
  ('00000000-0000-4000-8000-000000000001', 'legacy', 'Legacy LedgerX Records', false),
  ('00000000-0000-4000-8000-000000000002', 'demo', 'LedgerX Synthetic Demo', true);

INSERT INTO ledger.workspace_settings(workspace_id, default_currency_code, timezone_name)
VALUES
  ('00000000-0000-4000-8000-000000000001', 'INR', 'Asia/Kolkata'),
  ('00000000-0000-4000-8000-000000000002', 'INR', 'Asia/Kolkata');

CREATE FUNCTION ledger.current_workspace_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT COALESCE(
    nullif(current_setting('app.workspace_id', true), '')::uuid,
    CASE WHEN session_user = 'ledgerx_admin'
      THEN '00000000-0000-4000-8000-000000000001'::uuid END
  )
$function$;

CREATE FUNCTION ledger.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid
$function$;

CREATE FUNCTION ledger.current_supabase_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT nullif(current_setting('app.supabase_user_id', true), '')::uuid
$function$;

CREATE FUNCTION ledger.legacy_workspace_id()
RETURNS uuid
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT '00000000-0000-4000-8000-000000000001'::uuid
$function$;

CREATE FUNCTION ledger.default_workspace_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_workspace_id uuid;
BEGIN
  v_workspace_id := ledger.current_workspace_id();
  IF v_workspace_id IS NOT NULL THEN
    RETURN v_workspace_id;
  END IF;

  -- Existing local SQL tests connect as this database administrator. The
  -- restricted application roles must provide transaction-scoped context.
  IF session_user = 'ledgerx_admin' THEN
    RETURN ledger.legacy_workspace_id();
  END IF;
  RETURN NULL;
END
$function$;

-- Assign the already-stored financial history to a private legacy workspace.
ALTER TABLE ledger.customers ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.accounts ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.account_balances ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.transactions ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.ledger_entries ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.idempotency_keys ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.refunds ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.settlement_batches ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.settlement_items ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.settlement_matches ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.reconciliation_runs ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.reconciliation_results ADD COLUMN workspace_id uuid;
ALTER TABLE ledger.audit_logs ADD COLUMN workspace_id uuid;

-- The following ownership-only backfill must not queue financial lifecycle,
-- append-only, balance-projection, or deferred journal triggers. Every
-- original trigger is re-enabled before tenant constraints and RLS are added.
DO $disable_backfill_triggers$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'customers', 'accounts', 'account_balances', 'transactions',
    'ledger_entries', 'idempotency_keys', 'refunds', 'settlement_batches',
    'settlement_items', 'settlement_matches', 'reconciliation_runs',
    'reconciliation_results', 'audit_logs'
  ] LOOP
    EXECUTE format('ALTER TABLE ledger.%I DISABLE TRIGGER USER', v_table);
  END LOOP;
END
$disable_backfill_triggers$;

UPDATE ledger.customers SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.accounts SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.account_balances SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.transactions SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.ledger_entries SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.idempotency_keys SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.refunds SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.settlement_batches SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.settlement_items SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.settlement_matches SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.reconciliation_runs SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.reconciliation_results SET workspace_id = ledger.legacy_workspace_id();
UPDATE ledger.audit_logs SET workspace_id = ledger.legacy_workspace_id();

DO $enable_backfill_triggers$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'customers', 'accounts', 'account_balances', 'transactions',
    'ledger_entries', 'idempotency_keys', 'refunds', 'settlement_batches',
    'settlement_items', 'settlement_matches', 'reconciliation_runs',
    'reconciliation_results', 'audit_logs'
  ] LOOP
    EXECUTE format('ALTER TABLE ledger.%I ENABLE TRIGGER USER', v_table);
  END LOOP;
END
$enable_backfill_triggers$;

DO $set_workspace_defaults$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'customers', 'accounts', 'account_balances', 'transactions',
    'ledger_entries', 'idempotency_keys', 'refunds', 'settlement_batches',
    'settlement_items', 'settlement_matches', 'reconciliation_runs',
    'reconciliation_results', 'audit_logs'
  ] LOOP
    EXECUTE format(
      'ALTER TABLE ledger.%I ALTER COLUMN workspace_id SET DEFAULT ledger.default_workspace_id(), ALTER COLUMN workspace_id SET NOT NULL',
      v_table
    );
  END LOOP;
END
$set_workspace_defaults$;

-- Tenant-scoped business identifiers can now repeat in separate workspaces.
ALTER TABLE ledger.customers DROP CONSTRAINT customers_customer_ref_key;
ALTER TABLE ledger.customers
  ADD CONSTRAINT customers_workspace_customer_ref_uq
  UNIQUE (workspace_id, customer_ref);
ALTER TABLE ledger.accounts DROP CONSTRAINT accounts_account_code_key;
ALTER TABLE ledger.accounts
  ADD CONSTRAINT accounts_workspace_account_code_uq
  UNIQUE (workspace_id, account_code);
ALTER TABLE ledger.transactions DROP CONSTRAINT transactions_transaction_ref_key;
ALTER TABLE ledger.transactions
  ADD CONSTRAINT transactions_workspace_transaction_ref_uq
  UNIQUE (workspace_id, transaction_ref);
ALTER TABLE ledger.idempotency_keys DROP CONSTRAINT idempotency_scope_key_uq;
ALTER TABLE ledger.idempotency_keys
  ADD CONSTRAINT idempotency_workspace_scope_key_uq
  UNIQUE (workspace_id, scope, idempotency_key);
ALTER TABLE ledger.settlement_batches
  DROP CONSTRAINT settlement_batches_external_batch_ref_key;
ALTER TABLE ledger.settlement_batches
  ADD CONSTRAINT settlement_batches_workspace_external_ref_uq
  UNIQUE (workspace_id, external_batch_ref);

-- Composite keys make cross-workspace relationships impossible even for a
-- privileged function that accidentally supplies a foreign tenant's ID.
ALTER TABLE ledger.customers
  ADD CONSTRAINT customers_workspace_id_customer_uq UNIQUE (workspace_id, customer_id);
ALTER TABLE ledger.accounts
  ADD CONSTRAINT accounts_workspace_id_account_uq UNIQUE (workspace_id, account_id),
  ADD CONSTRAINT accounts_workspace_customer_fk
    FOREIGN KEY (workspace_id, customer_id)
    REFERENCES ledger.customers(workspace_id, customer_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.account_balances
  ADD CONSTRAINT account_balances_workspace_account_uq UNIQUE (workspace_id, account_id),
  ADD CONSTRAINT account_balances_workspace_account_fk
    FOREIGN KEY (workspace_id, account_id)
    REFERENCES ledger.accounts(workspace_id, account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.transactions
  ADD CONSTRAINT transactions_workspace_id_transaction_uq UNIQUE (workspace_id, transaction_id),
  ADD CONSTRAINT transactions_workspace_source_account_fk
    FOREIGN KEY (workspace_id, source_account_id)
    REFERENCES ledger.accounts(workspace_id, account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT transactions_workspace_destination_account_fk
    FOREIGN KEY (workspace_id, destination_account_id)
    REFERENCES ledger.accounts(workspace_id, account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT transactions_workspace_reversal_fk
    FOREIGN KEY (workspace_id, reversal_of_transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.ledger_entries
  ADD CONSTRAINT ledger_entries_workspace_transaction_fk
    FOREIGN KEY (workspace_id, transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT ledger_entries_workspace_account_fk
    FOREIGN KEY (workspace_id, account_id)
    REFERENCES ledger.accounts(workspace_id, account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.idempotency_keys
  ADD CONSTRAINT idempotency_workspace_id_key_uq UNIQUE (workspace_id, idempotency_id),
  ADD CONSTRAINT idempotency_workspace_transaction_fk
    FOREIGN KEY (workspace_id, transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.refunds
  ADD CONSTRAINT refunds_workspace_id_refund_uq UNIQUE (workspace_id, refund_id),
  ADD CONSTRAINT refunds_workspace_original_transaction_fk
    FOREIGN KEY (workspace_id, original_transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT refunds_workspace_refund_transaction_fk
    FOREIGN KEY (workspace_id, refund_transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.settlement_batches
  ADD CONSTRAINT settlement_batches_workspace_id_batch_uq
    UNIQUE (workspace_id, settlement_batch_id);
ALTER TABLE ledger.settlement_items
  ADD CONSTRAINT settlement_items_workspace_id_item_uq
    UNIQUE (workspace_id, settlement_item_id),
  ADD CONSTRAINT settlement_items_workspace_batch_fk
    FOREIGN KEY (workspace_id, settlement_batch_id)
    REFERENCES ledger.settlement_batches(workspace_id, settlement_batch_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.settlement_matches
  ADD CONSTRAINT settlement_matches_workspace_item_fk
    FOREIGN KEY (workspace_id, settlement_item_id)
    REFERENCES ledger.settlement_items(workspace_id, settlement_item_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT settlement_matches_workspace_transaction_fk
    FOREIGN KEY (workspace_id, transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.reconciliation_runs
  ADD CONSTRAINT reconciliation_runs_workspace_id_run_uq
    UNIQUE (workspace_id, reconciliation_run_id),
  ADD CONSTRAINT reconciliation_runs_workspace_batch_fk
    FOREIGN KEY (workspace_id, settlement_batch_id)
    REFERENCES ledger.settlement_batches(workspace_id, settlement_batch_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.reconciliation_results
  ADD CONSTRAINT reconciliation_results_workspace_run_fk
    FOREIGN KEY (workspace_id, reconciliation_run_id)
    REFERENCES ledger.reconciliation_runs(workspace_id, reconciliation_run_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT reconciliation_results_workspace_item_fk
    FOREIGN KEY (workspace_id, settlement_item_id)
    REFERENCES ledger.settlement_items(workspace_id, settlement_item_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT reconciliation_results_workspace_transaction_fk
    FOREIGN KEY (workspace_id, transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ledger.audit_logs
  ADD CONSTRAINT audit_logs_workspace_transaction_fk
    FOREIGN KEY (workspace_id, transaction_id)
    REFERENCES ledger.transactions(workspace_id, transaction_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT audit_logs_workspace_account_fk
    FOREIGN KEY (workspace_id, account_id)
    REFERENCES ledger.accounts(workspace_id, account_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX customers_workspace_created_idx
  ON ledger.customers(workspace_id, created_at DESC);
CREATE INDEX accounts_workspace_status_idx
  ON ledger.accounts(workspace_id, status, account_id);
CREATE INDEX transactions_workspace_created_idx
  ON ledger.transactions(workspace_id, created_at DESC, transaction_id DESC);
CREATE INDEX transactions_workspace_posted_idx
  ON ledger.transactions(workspace_id, posted_at DESC)
  WHERE status IN ('posted', 'reversed');
CREATE INDEX ledger_entries_workspace_account_time_idx
  ON ledger.ledger_entries(workspace_id, account_id, created_at, ledger_entry_id);
CREATE INDEX settlement_batches_workspace_date_idx
  ON ledger.settlement_batches(workspace_id, statement_date DESC);
CREATE INDEX audit_logs_workspace_time_idx
  ON ledger.audit_logs(workspace_id, occurred_at DESC);

-- Update old function bodies from catalog definitions so the applied source
-- files remain immutable while ON CONFLICT targets include the new tenant key.
DO $scope_idempotency_function$
DECLARE
  v_definition text;
  v_original text;
BEGIN
  v_definition := pg_get_functiondef(
    'ledger.post_financial_operation(text,text,text,bigint,bigint,numeric,text,text,bigint)'::regprocedure
  );
  v_original := v_definition;
  v_definition := replace(v_definition,
    'scope, idempotency_key, payload_hash',
    'workspace_id, scope, idempotency_key, payload_hash');
  v_definition := replace(v_definition,
    'p_scope, p_idempotency_key, v_hash',
    'ledger.current_workspace_id(), p_scope, p_idempotency_key, v_hash');
  v_definition := replace(v_definition,
    'ON CONFLICT (scope, idempotency_key) DO NOTHING',
    'ON CONFLICT (workspace_id, scope, idempotency_key) DO NOTHING');
  v_definition := replace(v_definition,
    'WHERE ik.scope = p_scope AND ik.idempotency_key = p_idempotency_key;',
    'WHERE ik.workspace_id = ledger.current_workspace_id() AND ik.scope = p_scope AND ik.idempotency_key = p_idempotency_key;');
  IF v_definition = v_original
     OR position('ON CONFLICT (workspace_id, scope, idempotency_key)' IN v_definition) = 0
     OR position('ik.workspace_id = ledger.current_workspace_id()' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'could not tenant-scope the financial idempotency function';
  END IF;
  EXECUTE v_definition;
END
$scope_idempotency_function$;

DO $scope_settlement_function$
DECLARE
  v_definition text;
  v_original text;
BEGIN
  v_definition := pg_get_functiondef(
    'ledger.create_settlement_batch(text,text,date,timestamptz,timestamptz,text)'::regprocedure
  );
  v_original := v_definition;
  v_definition := replace(v_definition,
    'external_batch_ref, source_name, statement_date,',
    'workspace_id, external_batch_ref, source_name, statement_date,');
  v_definition := replace(v_definition,
    'p_external_batch_ref, p_source_name, p_statement_date,',
    'ledger.current_workspace_id(), p_external_batch_ref, p_source_name, p_statement_date,');
  v_definition := replace(v_definition,
    'ON CONFLICT (external_batch_ref) DO NOTHING',
    'ON CONFLICT (workspace_id, external_batch_ref) DO NOTHING');
  v_definition := replace(v_definition,
    'WHERE b.external_batch_ref = p_external_batch_ref;',
    'WHERE b.workspace_id = ledger.current_workspace_id() AND b.external_batch_ref = p_external_batch_ref;');
  IF v_definition = v_original
     OR position('ON CONFLICT (workspace_id, external_batch_ref)' IN v_definition) = 0
     OR position('b.workspace_id = ledger.current_workspace_id()' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'could not tenant-scope the settlement batch function';
  END IF;
  EXECUTE v_definition;
END
$scope_settlement_function$;

CREATE FUNCTION ledger.has_workspace_permission(
  p_workspace_id uuid,
  p_permission text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM ledger.workspace_memberships AS wm
      JOIN ledger.workspace_role_permissions AS rp ON rp.role = wm.role
     WHERE wm.workspace_id = p_workspace_id
       AND wm.user_id = ledger.current_user_id()
       AND wm.status = 'active'
       AND rp.permission = p_permission
  )
$function$;

CREATE FUNCTION ledger.register_authenticated_user(p_supabase_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_user_id uuid;
BEGIN
  IF p_supabase_user_id IS NULL THEN
    RAISE EXCEPTION 'verified Supabase user ID is required' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.supabase_user_id', p_supabase_user_id::text, true);
  INSERT INTO ledger.app_users(supabase_user_id)
  VALUES (p_supabase_user_id)
  ON CONFLICT (supabase_user_id) DO NOTHING
  RETURNING user_id INTO v_user_id;
  IF v_user_id IS NULL THEN
    SELECT u.user_id INTO v_user_id
      FROM ledger.app_users AS u
     WHERE u.supabase_user_id = p_supabase_user_id;
  END IF;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'could not resolve the authenticated LedgerX user'
      USING ERRCODE = '40001';
  END IF;

  PERFORM set_config('app.user_id', v_user_id::text, true);
  PERFORM set_config('app.workspace_id', '', true);
  RETURN v_user_id;
END
$function$;

CREATE FUNCTION ledger.set_request_context(
  p_supabase_user_id uuid,
  p_workspace_id uuid
)
RETURNS TABLE(user_id uuid, membership_role text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_user_id uuid;
  v_role text;
BEGIN
  IF p_supabase_user_id IS NULL OR p_workspace_id IS NULL THEN
    RAISE EXCEPTION 'verified user and active workspace are required'
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.supabase_user_id', p_supabase_user_id::text, true);
  SELECT u.user_id INTO v_user_id
    FROM ledger.app_users AS u
   WHERE u.supabase_user_id = p_supabase_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'authenticated user is not registered in LedgerX'
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.user_id', v_user_id::text, true);
  PERFORM set_config('app.workspace_id', p_workspace_id::text, true);
  SELECT wm.role INTO v_role
    FROM ledger.workspace_memberships AS wm
    JOIN ledger.workspaces AS w ON w.workspace_id = wm.workspace_id
   WHERE wm.workspace_id = p_workspace_id
     AND wm.user_id = v_user_id
     AND wm.status = 'active'
     AND w.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user does not have an active membership in this workspace'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY SELECT v_user_id, v_role;
END
$function$;

CREATE FUNCTION ledger.create_workspace(
  p_workspace_type text,
  p_workspace_name text,
  p_default_currency_code text DEFAULT 'INR',
  p_timezone_name text DEFAULT 'Asia/Kolkata'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_workspace_id uuid := gen_random_uuid();
  v_user_id uuid := ledger.current_user_id();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authenticated LedgerX user context is required'
      USING ERRCODE = '42501';
  END IF;
  IF p_workspace_type NOT IN ('student', 'personal', 'family', 'business') THEN
    RAISE EXCEPTION 'unsupported user workspace type: %', p_workspace_type
      USING ERRCODE = '22023';
  END IF;
  IF p_workspace_name IS NULL OR length(btrim(p_workspace_name)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'workspace name must contain 1 to 120 characters'
      USING ERRCODE = '22023';
  END IF;
  IF p_timezone_name IS NULL OR length(btrim(p_timezone_name)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'timezone name must contain 1 to 100 characters'
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.workspace_id', v_workspace_id::text, true);
  PERFORM set_config('app.workspace_provisioning', 'true', true);
  INSERT INTO ledger.workspaces(workspace_id, workspace_type, workspace_name)
  VALUES (v_workspace_id, p_workspace_type, btrim(p_workspace_name));
  INSERT INTO ledger.workspace_memberships(workspace_id, user_id, role)
  VALUES (v_workspace_id, v_user_id, 'owner');
  PERFORM set_config('app.workspace_provisioning', 'false', true);
  INSERT INTO ledger.workspace_settings(
    workspace_id, default_currency_code, timezone_name
  ) VALUES (
    v_workspace_id, p_default_currency_code, btrim(p_timezone_name)
  );
  RETURN v_workspace_id;
END
$function$;

CREATE FUNCTION ledger.validate_workspace_membership_owner(p_workspace_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
DECLARE
  v_workspace_type text;
  v_owner_count bigint;
BEGIN
  SELECT w.workspace_type INTO v_workspace_type
    FROM ledger.workspaces AS w WHERE w.workspace_id = p_workspace_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  SELECT count(*) INTO v_owner_count
    FROM ledger.workspace_memberships AS wm
   WHERE wm.workspace_id = p_workspace_id AND wm.role = 'owner';

  IF v_workspace_type IN ('student', 'personal', 'family', 'business')
     AND v_owner_count <> 1 THEN
    RAISE EXCEPTION 'workspace % must have exactly one owner membership', p_workspace_id
      USING ERRCODE = '23514';
  END IF;
  IF v_workspace_type IN ('demo', 'legacy') AND v_owner_count <> 0 THEN
    RAISE EXCEPTION 'system workspace % cannot have a user owner', p_workspace_id
      USING ERRCODE = '23514';
  END IF;
END
$function$;

CREATE FUNCTION ledger.check_workspace_owner_from_workspace()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  PERFORM ledger.validate_workspace_membership_owner(NEW.workspace_id);
  RETURN NULL;
END
$function$;

CREATE FUNCTION ledger.check_workspace_owner_from_membership()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    PERFORM ledger.validate_workspace_membership_owner(OLD.workspace_id);
  END IF;
  IF TG_OP <> 'DELETE' THEN
    PERFORM ledger.validate_workspace_membership_owner(NEW.workspace_id);
  END IF;
  RETURN NULL;
END
$function$;

CREATE CONSTRAINT TRIGGER workspaces_owner_membership_check
AFTER INSERT OR UPDATE ON ledger.workspaces
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ledger.check_workspace_owner_from_workspace();
CREATE CONSTRAINT TRIGGER workspace_memberships_owner_check
AFTER INSERT OR UPDATE OR DELETE ON ledger.workspace_memberships
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ledger.check_workspace_owner_from_membership();

CREATE FUNCTION ledger.guard_workspace_id_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
BEGIN
  IF NEW.workspace_id IS DISTINCT FROM OLD.workspace_id THEN
    RAISE EXCEPTION 'financial record workspace ownership is immutable'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;

DO $tenant_identity_triggers$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'customers', 'accounts', 'account_balances', 'transactions',
    'ledger_entries', 'idempotency_keys', 'refunds', 'settlement_batches',
    'settlement_items', 'settlement_matches', 'reconciliation_runs',
    'reconciliation_results', 'audit_logs'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON ledger.%I FOR EACH ROW EXECUTE FUNCTION ledger.guard_workspace_id_change()',
      v_table || '_workspace_id_guard', v_table
    );
  END LOOP;
END
$tenant_identity_triggers$;

CREATE FUNCTION ledger.has_legacy_local_access(p_workspace_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, ledger, pg_temp
AS $function$
  SELECT session_user IN ('ledgerx_dashboard', 'ledgerx_admin')
     AND p_workspace_id = ledger.legacy_workspace_id()
$function$;

-- Policies for identity/workspace metadata. Membership lookup is deliberately
-- self-only here so permission checks never recurse through this table's RLS.
ALTER TABLE ledger.app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.app_users FORCE ROW LEVEL SECURITY;
CREATE POLICY app_users_self_select ON ledger.app_users
  FOR SELECT USING (
    user_id = ledger.current_user_id()
    OR supabase_user_id = ledger.current_supabase_user_id()
  );
CREATE POLICY app_users_self_insert ON ledger.app_users
  FOR INSERT WITH CHECK (
    supabase_user_id = ledger.current_supabase_user_id()
  );

ALTER TABLE ledger.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.workspaces FORCE ROW LEVEL SECURITY;
CREATE POLICY workspaces_member_select ON ledger.workspaces
  FOR SELECT USING (
    workspace_id = ledger.current_workspace_id()
    AND (
      ledger.has_workspace_permission(workspace_id, 'workspace.read')
      OR ledger.has_legacy_local_access(workspace_id)
    )
  );
CREATE POLICY workspaces_provision_insert ON ledger.workspaces
  FOR INSERT WITH CHECK (
    workspace_id = ledger.current_workspace_id()
    AND ledger.current_user_id() IS NOT NULL
    AND current_setting('app.workspace_provisioning', true) = 'true'
    AND workspace_type IN ('student', 'personal', 'family', 'business')
  );
CREATE POLICY workspaces_admin_update ON ledger.workspaces
  FOR UPDATE USING (
    workspace_id = ledger.current_workspace_id()
    AND ledger.has_workspace_permission(workspace_id, 'workspace.settings.manage')
  ) WITH CHECK (
    workspace_id = ledger.current_workspace_id()
    AND ledger.has_workspace_permission(workspace_id, 'workspace.settings.manage')
  );

ALTER TABLE ledger.workspace_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.workspace_memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_memberships_self_select ON ledger.workspace_memberships
  FOR SELECT USING (
    workspace_id = ledger.current_workspace_id()
    AND user_id = ledger.current_user_id()
  );
CREATE POLICY workspace_memberships_owner_provision ON ledger.workspace_memberships
  FOR INSERT WITH CHECK (
    workspace_id = ledger.current_workspace_id()
    AND user_id = ledger.current_user_id()
    AND role = 'owner'
    AND status = 'active'
    AND current_setting('app.workspace_provisioning', true) = 'true'
  );

ALTER TABLE ledger.workspace_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.workspace_role_permissions FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_role_permissions_read ON ledger.workspace_role_permissions
  FOR SELECT USING (true);

ALTER TABLE ledger.workspace_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.workspace_settings FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_settings_member_select ON ledger.workspace_settings
  FOR SELECT USING (
    workspace_id = ledger.current_workspace_id()
    AND (
      ledger.has_workspace_permission(workspace_id, 'workspace.read')
      OR ledger.has_legacy_local_access(workspace_id)
    )
  );
CREATE POLICY workspace_settings_admin_write ON ledger.workspace_settings
  FOR ALL USING (
    workspace_id = ledger.current_workspace_id()
    AND ledger.has_workspace_permission(workspace_id, 'workspace.settings.manage')
  ) WITH CHECK (
    workspace_id = ledger.current_workspace_id()
    AND ledger.has_workspace_permission(workspace_id, 'workspace.settings.manage')
  );

ALTER TABLE ledger.workspace_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.workspace_invitations FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_invitations_manager_access ON ledger.workspace_invitations
  FOR ALL USING (
    workspace_id = ledger.current_workspace_id()
    AND ledger.has_workspace_permission(workspace_id, 'workspace.members.manage')
  ) WITH CHECK (
    workspace_id = ledger.current_workspace_id()
    AND ledger.has_workspace_permission(workspace_id, 'workspace.members.manage')
  );

-- Tenant predicates use both transaction-local context and an active role
-- permission. The local analytics login is explicitly limited to legacy data.
DO $tenant_rls$
DECLARE
  v_table text;
  v_permission text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'customers', 'accounts', 'account_balances', 'transactions',
    'ledger_entries', 'idempotency_keys', 'refunds'
  ] LOOP
    EXECUTE format('ALTER TABLE ledger.%I ENABLE ROW LEVEL SECURITY', v_table);
    EXECUTE format('ALTER TABLE ledger.%I FORCE ROW LEVEL SECURITY', v_table);
    EXECUTE format(
      'CREATE POLICY %I ON ledger.%I FOR SELECT USING (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''finance.read'') OR ledger.has_legacy_local_access(workspace_id)))',
      v_table || '_tenant_read', v_table
    );
    EXECUTE format(
      'CREATE POLICY %I ON ledger.%I FOR INSERT WITH CHECK (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''finance.write'') OR ledger.has_legacy_local_access(workspace_id)))',
      v_table || '_tenant_insert', v_table
    );
    EXECUTE format(
      'CREATE POLICY %I ON ledger.%I FOR UPDATE USING (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''finance.write'') OR ledger.has_legacy_local_access(workspace_id))) WITH CHECK (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''finance.write'') OR ledger.has_legacy_local_access(workspace_id)))',
      v_table || '_tenant_update', v_table
    );
  END LOOP;

  FOREACH v_table IN ARRAY ARRAY[
    'settlement_batches', 'settlement_items', 'settlement_matches',
    'reconciliation_runs', 'reconciliation_results'
  ] LOOP
    EXECUTE format('ALTER TABLE ledger.%I ENABLE ROW LEVEL SECURITY', v_table);
    EXECUTE format('ALTER TABLE ledger.%I FORCE ROW LEVEL SECURITY', v_table);
    EXECUTE format(
      'CREATE POLICY %I ON ledger.%I FOR SELECT USING (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''reconciliation.read'') OR ledger.has_legacy_local_access(workspace_id)))',
      v_table || '_tenant_read', v_table
    );
    EXECUTE format(
      'CREATE POLICY %I ON ledger.%I FOR INSERT WITH CHECK (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''reconciliation.manage'') OR ledger.has_legacy_local_access(workspace_id)))',
      v_table || '_tenant_insert', v_table
    );
    EXECUTE format(
      'CREATE POLICY %I ON ledger.%I FOR UPDATE USING (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''reconciliation.manage'') OR ledger.has_legacy_local_access(workspace_id))) WITH CHECK (workspace_id = ledger.current_workspace_id() AND (ledger.has_workspace_permission(workspace_id, ''reconciliation.manage'') OR ledger.has_legacy_local_access(workspace_id)))',
      v_table || '_tenant_update', v_table
    );
  END LOOP;

  ALTER TABLE ledger.audit_logs ENABLE ROW LEVEL SECURITY;
  ALTER TABLE ledger.audit_logs FORCE ROW LEVEL SECURITY;
  CREATE POLICY audit_logs_reader_access ON ledger.audit_logs
    FOR SELECT USING (
      workspace_id = ledger.current_workspace_id()
      AND (
        ledger.has_workspace_permission(workspace_id, 'audit.read')
        OR ledger.has_legacy_local_access(workspace_id)
      )
    );
  CREATE POLICY audit_logs_writer_insert ON ledger.audit_logs
    FOR INSERT WITH CHECK (
      workspace_id = ledger.current_workspace_id()
      AND (
        ledger.has_workspace_permission(workspace_id, 'finance.write')
        OR ledger.has_legacy_local_access(workspace_id)
      )
    );
END
$tenant_rls$;

-- PostgreSQL 15+ view security-invoker mode makes each report obey the caller's
-- table grants and RLS policy instead of the view owner's privileges.
ALTER VIEW ledger.v_daily_transaction_volume SET (security_invoker = true);
ALTER VIEW ledger.v_monthly_transaction_summary SET (security_invoker = true);
ALTER VIEW ledger.v_monthly_transaction_rank SET (security_invoker = true);
ALTER VIEW ledger.v_account_activity SET (security_invoker = true);
ALTER VIEW ledger.v_refund_analysis SET (security_invoker = true);
ALTER VIEW ledger.v_refund_history SET (security_invoker = true);
ALTER VIEW ledger.v_settlement_batch_summary SET (security_invoker = true);
ALTER VIEW ledger.v_reconciliation_exceptions SET (security_invoker = true);
ALTER VIEW ledger.v_unsettled_transactions SET (security_invoker = true);

REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM PUBLIC;
GRANT SELECT ON ledger.app_users, ledger.workspaces,
  ledger.workspace_memberships, ledger.workspace_role_permissions,
  ledger.workspace_settings, ledger.workspace_invitations
TO ledgerx_runtime;
GRANT SELECT ON ledger.workspace_role_permissions TO ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.current_workspace_id() TO ledgerx_runtime, ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.current_user_id() TO ledgerx_runtime, ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.current_supabase_user_id() TO ledgerx_runtime, ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.legacy_workspace_id() TO ledgerx_runtime, ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.default_workspace_id() TO ledgerx_runtime, ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.has_workspace_permission(uuid, text) TO ledgerx_runtime, ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.has_legacy_local_access(uuid) TO ledgerx_runtime, ledgerx_dashboard;
GRANT EXECUTE ON FUNCTION ledger.register_authenticated_user(uuid) TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.set_request_context(uuid, uuid) TO ledgerx_runtime;
GRANT EXECUTE ON FUNCTION ledger.create_workspace(text, text, text, text) TO ledgerx_runtime;

COMMENT ON TABLE ledger.app_users IS
  'Internal user mapping to a verified Supabase Auth UUID; no email or profile data is duplicated.';
COMMENT ON TABLE ledger.workspaces IS
  'Workspace boundary for student, personal, family, business, synthetic demo, and private legacy records.';
COMMENT ON TABLE ledger.workspace_memberships IS
  'Workspace access and role assignment; a single owner membership is enforced at commit for user workspaces.';
COMMENT ON TABLE ledger.workspace_role_permissions IS
  'Explicit role-to-permission matrix used by row-level security and backend authorization.';
COMMENT ON TABLE ledger.workspace_settings IS
  'Workspace defaults for currency and timezone.';
COMMENT ON TABLE ledger.workspace_invitations IS
  'Workspace invitation state; only a SHA-256 token hash is stored.';
