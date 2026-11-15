\set ON_ERROR_STOP on
BEGIN;

-- These UUIDs are synthetic test identities, not Supabase accounts.
SELECT ledger.register_authenticated_user('10000000-0000-4000-8000-000000000001') AS user_a \gset
SELECT ledger.create_workspace('personal', 'Tenant Isolation A', 'INR', 'UTC') AS workspace_a \gset
SET CONSTRAINTS ALL IMMEDIATE;
SELECT ledger.register_authenticated_user('10000000-0000-4000-8000-000000000002') AS supabase_b \gset
SELECT ledger.create_workspace('family', 'Tenant Isolation B', 'INR', 'UTC') AS workspace_b \gset
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
SELECT count(*) AS legacy_account_count
  FROM ledger.accounts
 WHERE workspace_id = ledger.legacy_workspace_id() \gset

-- Business-facing references may repeat in different workspaces.
SELECT set_config('app.workspace_id', :'workspace_a', true);
INSERT INTO ledger.customers(workspace_id, customer_ref, display_name)
VALUES (:'workspace_a', 'TENANT-DUPLICATE-REF', 'Synthetic Tenant A');
INSERT INTO ledger.accounts(
  workspace_id, customer_id, account_code, account_kind, normal_side, currency_code
)
SELECT :'workspace_a', customer_id, 'TENANT-DUPLICATE-ACCOUNT',
       'customer_wallet', 'credit', 'INR'
  FROM ledger.customers
 WHERE workspace_id = :'workspace_a'
   AND customer_ref = 'TENANT-DUPLICATE-REF';
SELECT account_id AS account_a FROM ledger.accounts
 WHERE workspace_id = :'workspace_a'
   AND account_code = 'TENANT-DUPLICATE-ACCOUNT' \gset
INSERT INTO ledger.accounts(
  workspace_id, account_code, account_kind, normal_side, currency_code
)
VALUES (:'workspace_a', 'TENANT-DUPLICATE-FUNDING', 'funding_clearing', 'debit', 'INR');
SELECT account_id AS funding_a FROM ledger.accounts
 WHERE workspace_id = :'workspace_a'
   AND account_code = 'TENANT-DUPLICATE-FUNDING' \gset

SELECT set_config('app.workspace_id', :'workspace_b', true);
INSERT INTO ledger.customers(workspace_id, customer_ref, display_name)
VALUES (:'workspace_b', 'TENANT-DUPLICATE-REF', 'Synthetic Tenant B');
INSERT INTO ledger.accounts(
  workspace_id, customer_id, account_code, account_kind, normal_side, currency_code
)
SELECT :'workspace_b', customer_id, 'TENANT-DUPLICATE-ACCOUNT',
       'customer_wallet', 'credit', 'INR'
  FROM ledger.customers
 WHERE workspace_id = :'workspace_b'
   AND customer_ref = 'TENANT-DUPLICATE-REF';
SELECT account_id AS account_b FROM ledger.accounts
 WHERE workspace_id = :'workspace_b'
   AND account_code = 'TENANT-DUPLICATE-ACCOUNT' \gset
INSERT INTO ledger.accounts(
  workspace_id, account_code, account_kind, normal_side, currency_code
)
VALUES (:'workspace_b', 'TENANT-DUPLICATE-FUNDING', 'funding_clearing', 'debit', 'INR');
SELECT account_id AS funding_b FROM ledger.accounts
 WHERE workspace_id = :'workspace_b'
   AND account_code = 'TENANT-DUPLICATE-FUNDING' \gset

DO $cross_tenant_fk_assertion$
BEGIN
  BEGIN
    INSERT INTO ledger.transactions(
      workspace_id, transaction_ref, transaction_type, amount, currency_code,
      source_account_id, destination_account_id
    )
    SELECT a.workspace_id, 'TENANT-CROSS-FK-SHOULD-FAIL', 'transfer', 1.00,
           'INR', a.account_id, b.account_id
      FROM ledger.accounts AS a
      JOIN ledger.accounts AS b
        ON b.account_code = a.account_code
       AND b.account_kind = 'customer_wallet'
       AND b.workspace_id = (
         SELECT workspace_id FROM ledger.workspaces
          WHERE workspace_name = 'Tenant Isolation B'
       )
     WHERE a.account_kind = 'customer_wallet'
       AND a.workspace_id = (
         SELECT workspace_id FROM ledger.workspaces
          WHERE workspace_name = 'Tenant Isolation A'
       );
    RAISE EXCEPTION 'cross-workspace account reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END
$cross_tenant_fk_assertion$;

-- Switch to the restricted runtime role. It has no BYPASSRLS and sees no
-- financial rows until the database validates a member and workspace.
SET SESSION AUTHORIZATION ledgerx_runtime;
SELECT set_config('app.user_id', '', true),
       set_config('app.supabase_user_id', '', true),
       set_config('app.workspace_id', '', true);
SELECT count(*) = 0 AS missing_context_denied FROM ledger.accounts \gset
\if :missing_context_denied
\else
  \echo 'FAIL: missing tenant context exposed account rows'
  SELECT 1 / 0;
\endif

SELECT user_id, membership_role
  FROM ledger.set_request_context(
    '10000000-0000-4000-8000-000000000001', :'workspace_a'
  );
SELECT count(*) = 1 AS tenant_a_only FROM ledger.accounts
 WHERE account_kind = 'customer_wallet' \gset
\if :tenant_a_only
\else
  \echo 'FAIL: tenant A did not see exactly its own account'
  SELECT 1 / 0;
\endif
SELECT ledger.deposit(
  'tenant-shared-scope', 'tenant-shared-key', :'funding_a', :'account_a',
  1.00, 'INR', 'tenant-a-operation'
) AS transaction_a \gset
SELECT ledger.deposit(
  'tenant-shared-scope', 'tenant-shared-key', :'funding_a', :'account_a',
  1.00, 'INR', 'tenant-a-operation'
) AS transaction_a_retry \gset
SELECT ledger.create_settlement_batch(
  'tenant-shared-batch', 'synthetic-source', current_date,
  transaction_timestamp() - interval '1 day',
  transaction_timestamp() + interval '1 day', 'INR'
) AS batch_a \gset
SELECT count(*) = 0 AS tenant_a_cannot_see_b
  FROM ledger.accounts WHERE workspace_id = :'workspace_b' \gset
\if :tenant_a_cannot_see_b
\else
  \echo 'FAIL: tenant A could read tenant B account rows'
  SELECT 1 / 0;
\endif

SELECT set_config('app.attempt_workspace_id', :'workspace_b', true);
DO $wrong_membership_assertion$
BEGIN
  BEGIN
    PERFORM ledger.set_request_context(
      '10000000-0000-4000-8000-000000000001',
      current_setting('app.attempt_workspace_id')::uuid
    );
    RAISE EXCEPTION 'a non-member selected another workspace';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$wrong_membership_assertion$;

SELECT user_id, membership_role
  FROM ledger.set_request_context(
    '10000000-0000-4000-8000-000000000002', :'workspace_b'
  );
SELECT count(*) = 1 AS tenant_b_only FROM ledger.accounts
 WHERE account_kind = 'customer_wallet' \gset
\if :tenant_b_only
\else
  \echo 'FAIL: tenant B did not see exactly its own account'
  SELECT 1 / 0;
\endif
SELECT ledger.deposit(
  'tenant-shared-scope', 'tenant-shared-key', :'funding_b', :'account_b',
  1.00, 'INR', 'tenant-b-operation'
) AS transaction_b \gset
SELECT ledger.create_settlement_batch(
  'tenant-shared-batch', 'synthetic-source', current_date,
  transaction_timestamp() - interval '1 day',
  transaction_timestamp() + interval '1 day', 'INR'
) AS batch_b \gset
SELECT (:'transaction_a'::bigint = :'transaction_a_retry'::bigint)
       AND (:'transaction_a'::bigint <> :'transaction_b'::bigint)
       AS tenant_scoped_idempotency \gset
\if :tenant_scoped_idempotency
\else
  \echo 'FAIL: identical idempotency keys did not resolve independently by tenant'
  SELECT 1 / 0;
\endif
SELECT :'batch_a'::bigint <> :'batch_b'::bigint AS tenant_scoped_batches \gset
\if :tenant_scoped_batches
\else
  \echo 'FAIL: identical external batch references collided across workspaces'
  SELECT 1 / 0;
\endif

RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION ledgerx_api;
SELECT user_id, membership_role
  FROM ledger.set_request_context(
    '10000000-0000-4000-8000-000000000001', :'workspace_a'
  );
SELECT count(*) = 1 AS api_reader_sees_only_member_workspace
  FROM ledger.accounts WHERE account_kind = 'customer_wallet' \gset
\if :api_reader_sees_only_member_workspace
\else
  \echo 'FAIL: workspace API reader did not follow verified member context'
  SELECT 1 / 0;
\endif
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION ledgerx_dashboard;
SELECT set_config('app.user_id', :'user_a', true),
       set_config('app.workspace_id', :'workspace_a', true);
SELECT count(*) = 0 AS dashboard_cannot_impersonate_member
  FROM ledger.accounts \gset
\if :dashboard_cannot_impersonate_member
\else
  \echo 'FAIL: local dashboard role impersonated an application workspace member'
  SELECT 1 / 0;
\endif
SELECT set_config('app.workspace_id', '00000000-0000-4000-8000-000000000001', true);
SELECT count(*) = :'legacy_account_count' AS dashboard_legacy_only
  FROM ledger.accounts \gset
\if :dashboard_legacy_only
\else
  \echo 'FAIL: local dashboard role did not remain confined to legacy records'
  SELECT 1 / 0;
\endif
RESET SESSION AUTHORIZATION;
ROLLBACK;
\echo 'Workspace isolation, legacy dashboard confinement, member checks, tenant-scoped idempotency and settlement references, owner invariants, and composite foreign-key assertions passed.'
