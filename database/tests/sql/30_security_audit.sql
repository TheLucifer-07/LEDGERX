-- Executable security audit: PUBLIC privileges, runtime-role privileges, ownership, SECURITY DEFINER
-- functions, search_path pinning, temporary-object protection, privilege-escalation attempts.
BEGIN;
SELECT plan(29);

-- 1. PUBLIC ----------------------------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
            WHERE d.datname = current_database() AND a.grantee = 0), 0, 'PUBLIC holds no privilege on the database (no CONNECT, no TEMPORARY)');
SELECT is(has_schema_privilege('public', 'public', 'CREATE'), false, 'PUBLIC cannot create objects in schema public');
SELECT is((SELECT count(*)::int FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
            WHERE n.nspname = 'lx' AND a.grantee = 0), 0, 'PUBLIC has no privilege on schema lx');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'lx' AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0))),
          0, 'PUBLIC can execute no lx function');
SELECT is((SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
            WHERE n.nspname = 'lx' AND c.relkind IN ('r','v','S') AND a.grantee = 0), 0, 'PUBLIC holds no privilege on any lx table, view or sequence');

-- 2. roles & ownership ----------------------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM pg_roles WHERE rolname IN ('ledgerx_migrator','ledgerx_runtime') AND (rolsuper OR rolbypassrls)), 0, 'neither application role is superuser or BYPASSRLS');
SELECT is((SELECT rolcreaterole OR rolcreatedb OR rolreplication FROM pg_roles WHERE rolname = 'ledgerx_runtime'), false, 'runtime role cannot create roles/databases or replicate');
SELECT is((SELECT count(*)::int FROM (
              SELECT relowner FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'lx'
              UNION ALL SELECT proowner FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lx'
              UNION ALL SELECT typowner FROM pg_type ty JOIN pg_namespace n ON n.oid = ty.typnamespace WHERE n.nspname = 'lx' AND ty.typtype <> 'b' AND ty.typrelid = 0) o
            WHERE pg_get_userbyid(o.relowner) <> 'ledgerx_migrator'), 0, 'every lx object is owned by ledgerx_migrator') ;
SELECT is((SELECT count(*)::int FROM pg_class WHERE pg_get_userbyid(relowner) = 'ledgerx_runtime')
        + (SELECT count(*)::int FROM pg_proc WHERE pg_get_userbyid(proowner) = 'ledgerx_runtime'), 0, 'the runtime role owns nothing');

-- 3. runtime-role privileges -------------------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
            WHERE n.nspname = 'lx' AND c.relkind IN ('r','v') AND has_table_privilege('ledgerx_runtime', c.oid, p)), 0, 'runtime holds no write-type privilege on any lx relation');
SELECT is((SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, pg_attribute a
            WHERE n.nspname = 'lx' AND c.relkind IN ('r','v') AND a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
              AND (has_column_privilege('ledgerx_runtime', c.oid, a.attnum, 'INSERT') OR has_column_privilege('ledgerx_runtime', c.oid, a.attnum, 'UPDATE'))), 0, 'runtime holds no column-level INSERT/UPDATE either');
SELECT is((SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'lx' AND c.relkind IN ('r','v') AND has_any_column_privilege('ledgerx_runtime', c.oid, 'SELECT')),
          ARRAY['account_balances','accounts','audit_events','currencies','invitations','journal_entries','journal_lines','users','v_account_balances','v_category_spend','v_monthly_cashflow','workspace_members','workspaces'],
          'the readable relation set is exactly the intended one (no idempotency_keys, no schema_migrations)');
SELECT is((SELECT array_agg(p.proname::text ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'lx' AND has_function_privilege('ledgerx_runtime', p.oid, 'EXECUTE')),
          ARRAY['can_see_private','create_account','create_invitation','create_workspace','ctx_coworker_ids','ctx_has_access','ctx_role','ctx_user','ctx_workspace','has_ws_access','is_member_of','my_workspace_ids','post_journal_entry','provision_user','rebuild_account_balances','resolve_user','reverse_journal_entry','schema_version','set_context','shares_workspace','verify_account_balances'],
          'the executable function set is exactly the public API (+ policy helpers)');
SELECT is((SELECT count(*)::int FROM pg_policy WHERE polrelid IN (SELECT oid FROM pg_class WHERE relnamespace = 'lx'::regnamespace) AND polroles <> ARRAY[(SELECT oid FROM pg_roles WHERE rolname = 'ledgerx_runtime')]), 0, 'every RLS policy is scoped TO ledgerx_runtime only');
SELECT is((SELECT count(*)::int FROM pg_policy WHERE polrelid IN (SELECT oid FROM pg_class WHERE relnamespace = 'lx'::regnamespace) AND polcmd <> 'r'), 0, 'every policy is SELECT-only: there is no policy that permits a write');

-- 4. SECURITY DEFINER functions ------------------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'lx' AND p.prosecdef AND NOT (p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp'])), 0,
          'every SECURITY DEFINER function pins search_path = pg_catalog, pg_temp (pg_temp last)');
SELECT is((SELECT array_agg(p.proname::text ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'lx' AND (p.proconfig IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))),
          ARRAY['can_see_private','ctx_user','ctx_workspace'],
          'the only unpinned functions are three inlinable SQL helpers that call nothing but pg_catalog built-ins');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_roles r ON r.oid = p.proowner
            WHERE n.nspname = 'lx' AND p.prosecdef AND (r.rolsuper OR r.rolbypassrls)), 0, 'no SECURITY DEFINER function runs as a superuser or BYPASSRLS role');

-- 5. temporary-object protection & escalation attempts --------------------------------------------------------------------------
SELECT is(has_database_privilege('ledgerx_runtime', current_database(), 'TEMPORARY'), false, 'runtime role cannot create temporary objects');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'CREATE TEMP TABLE workspace_members (i int)')), '42501', 'attempt: shadow a table with a temp table is denied');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'CREATE TABLE public.workspace_members (i int)')), '42501', 'attempt: create a table in public is denied');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'CREATE FUNCTION lx.ctx_user() RETURNS uuid LANGUAGE sql AS $f$ SELECT NULL::uuid $f$')), '42501', 'attempt: create/replace a function in lx is denied');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'CREATE SCHEMA evil')), '42501', 'attempt: create a schema is denied');
SELECT is((SELECT count(*)::int FROM pg_auth_members WHERE member IN (SELECT oid FROM pg_roles WHERE rolname IN ('ledgerx_runtime','ledgerx_migrator'))), 0, 'neither application role is a member of any other role (no SET ROLE path); real-connection check in tests/multisession');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'ALTER ROLE ledgerx_runtime BYPASSRLS')), '42501', 'attempt: grant itself BYPASSRLS is denied');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'SET session_replication_role = replica')), '42501', 'attempt: disable triggers via session_replication_role is denied');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'ALTER TABLE lx.journal_lines DISABLE TRIGGER ALL')), '42501', 'attempt: disable triggers on a ledger table is denied');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'ALTER TABLE lx.accounts DISABLE ROW LEVEL SECURITY')), '42501', 'attempt: disable RLS is denied');
SELECT is(t.code(t.exec_role('ledgerx_runtime', 'ALTER FUNCTION lx.post_journal_entry(text,date,text,jsonb,text,jsonb) SET search_path = public')), '42501', 'attempt: repoint a definer function''s search_path is denied');

SELECT * FROM finish();
ROLLBACK;
