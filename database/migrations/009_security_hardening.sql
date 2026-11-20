-- 009_security_hardening.sql : findings of the security audit (see docs/SECURITY.md).
--
-- F1  SECURITY DEFINER functions ran with search_path = "lx, pg_catalog": lx was searched before
--     pg_catalog and pg_temp was implicitly searched FIRST. Every definer function now pins
--     "pg_catalog, pg_temp" (pg_temp explicitly last); all object references are schema-qualified.
-- F2  PUBLIC (and therefore the runtime role) could create TEMPORARY objects. Revoked in
--     bootstrap/00_roles.sql; this migration verifies the posture and fails closed if it is absent.

DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'lx' AND p.prosecdef
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, pg_temp', f.sig);
  END LOOP;
END $$;

-- Trigger functions that are not SECURITY DEFINER are pinned as well (defence in depth).
ALTER FUNCTION lx.trg_immutable()     SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lx.trg_account_guard() SET search_path = pg_catalog, pg_temp;

-- Fail-closed posture checks: abort the migration if the bootstrap lockdown is missing.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
              WHERE d.datname = current_database() AND a.grantee = 0
                AND a.privilege_type IN ('TEMPORARY', 'CONNECT')) THEN
    RAISE EXCEPTION 'PUBLIC still holds CONNECT/TEMPORARY on this database: run database/bootstrap/00_roles.sql';
  END IF;
  IF has_database_privilege('ledgerx_runtime', current_database(), 'TEMPORARY') THEN
    RAISE EXCEPTION 'ledgerx_runtime may create temporary objects';
  END IF;
  IF has_schema_privilege('public', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'PUBLIC may create objects in schema public';
  END IF;
END $$;
