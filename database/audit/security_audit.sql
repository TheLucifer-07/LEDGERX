-- Read-only security posture report. Run by scripts/audit.sh as the administrator.
\pset border 1
\pset null '-'
\echo '== 1. PostgreSQL version and roles'
SELECT version();
SELECT rolname, rolsuper AS super, rolbypassrls AS bypassrls, rolcreaterole AS createrole, rolcreatedb AS createdb, rolcanlogin AS login
  FROM pg_roles WHERE rolname IN ('ledgerx_migrator','ledgerx_runtime') ORDER BY 1;
SELECT r.rolname, c.setconfig FROM pg_db_role_setting c JOIN pg_roles r ON r.oid = c.setrole WHERE r.rolname = 'ledgerx_runtime';

\echo '== 2. PUBLIC privileges (must be empty)'
SELECT 'database' AS object, d.datname AS name, a.privilege_type FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname = current_database() AND a.grantee = 0
UNION ALL SELECT 'schema', n.nspname, a.privilege_type FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a WHERE n.nspname IN ('lx','public') AND a.grantee = 0
UNION ALL SELECT 'function', p.proname, 'EXECUTE' FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lx' AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0))
UNION ALL SELECT 'relation', c.relname, a.privilege_type FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a WHERE n.nspname = 'lx' AND a.grantee = 0;

\echo '== 3. Ownership of lx objects'
SELECT pg_get_userbyid(relowner) AS owner, CASE relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'S' THEN 'sequence' WHEN 'i' THEN 'index' ELSE relkind::text END AS kind, count(*)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'lx' GROUP BY 1,2 ORDER BY 1,2;
SELECT pg_get_userbyid(proowner) AS owner, 'function' AS kind, count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lx' GROUP BY 1;

\echo '== 4. Runtime role: table/view privileges'
SELECT c.relname AS relation, c.relkind AS k,
       CASE WHEN has_table_privilege('ledgerx_runtime', c.oid, 'SELECT') THEN 'table-wide' WHEN has_any_column_privilege('ledgerx_runtime', c.oid, 'SELECT') THEN 'column-level' ELSE 'none' END AS "SELECT",
       has_table_privilege('ledgerx_runtime', c.oid, 'INSERT') AS ins, has_table_privilege('ledgerx_runtime', c.oid, 'UPDATE') AS upd,
       has_table_privilege('ledgerx_runtime', c.oid, 'DELETE') AS del, c.relrowsecurity AS rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'lx' AND c.relkind IN ('r','v') ORDER BY 1;

\echo '== 5. Runtime role: executable functions'
SELECT p.proname AS function, p.prosecdef AS definer, p.provolatile AS vol FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'lx' AND has_function_privilege('ledgerx_runtime', p.oid, 'EXECUTE') ORDER BY 1;

\echo '== 6. SECURITY DEFINER functions: owner and search_path'
SELECT p.proname AS function, pg_get_userbyid(p.proowner) AS owner, coalesce((SELECT c FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'), 'NOT PINNED') AS search_path
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lx' AND p.prosecdef ORDER BY 1;
\echo '-- non-definer functions without a pinned search_path (expected: three inlinable SQL helpers)'
SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'lx' AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) c WHERE c LIKE 'search_path=%') ORDER BY 1;

\echo '== 7. Row-level security policies'
SELECT tablename, policyname, cmd, roles::text, qual FROM pg_policies WHERE schemaname = 'lx' ORDER BY 1,2;
\echo '-- lx tables WITHOUT row-level security (expected: reference + migration tables only)'
SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'lx' AND relkind = 'r' AND NOT relrowsecurity ORDER BY 1;

\echo '== 8. Temporary-object protection'
SELECT has_database_privilege('ledgerx_runtime', current_database(), 'TEMPORARY') AS runtime_can_create_temp,
       has_database_privilege('ledgerx_runtime', current_database(), 'CREATE') AS runtime_can_create_schema,
       has_schema_privilege('ledgerx_runtime', 'lx', 'CREATE') AS runtime_can_create_in_lx,
       has_schema_privilege('ledgerx_runtime', 'public', 'CREATE') AS runtime_can_create_in_public;
