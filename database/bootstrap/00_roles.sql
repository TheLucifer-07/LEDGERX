-- 00_roles.sql : one-time role and database-privilege bootstrap. Run by an administrator
-- (superuser or database owner) BEFORE the migrations:
--   psql -d <db> -v dbname=<db> -v migrator_pw=... -v runtime_pw=... -f database/bootstrap/00_roles.sql
-- Idempotent. Passwords come from psql variables and are never stored in the repository.
--
-- Role model
--   ledgerx_migrator  owns every lx.* object and applies migrations. Not used by applications.
--   ledgerx_runtime   the only role applications/tests connect with. Owns nothing, NOBYPASSRLS,
--                     SELECT-only on protected tables, EXECUTE only on the public API functions.
\set ON_ERROR_STOP on

SELECT format('CREATE ROLE ledgerx_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledgerx_migrator') \gexec
SELECT format('CREATE ROLE ledgerx_runtime LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledgerx_runtime') \gexec
SELECT format('ALTER ROLE ledgerx_migrator PASSWORD %L', :'migrator_pw') \gexec
SELECT format('ALTER ROLE ledgerx_runtime PASSWORD %L', :'runtime_pw') \gexec
ALTER ROLE ledgerx_migrator NOSUPERUSER NOBYPASSRLS;
ALTER ROLE ledgerx_runtime  NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB;

-- Runaway-session protection for the application role (role-level defaults).
ALTER ROLE ledgerx_runtime SET statement_timeout = '15s';
ALTER ROLE ledgerx_runtime SET idle_in_transaction_session_timeout = '20s';

-- Database-level lockdown. By default PUBLIC may CONNECT and create TEMPORARY tables;
-- temporary objects are a classic search_path-shadowing vector for SECURITY DEFINER code.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'dbname') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO ledgerx_migrator, ledgerx_runtime', :'dbname') \gexec
SELECT format('GRANT CREATE ON DATABASE %I TO ledgerx_migrator', :'dbname') \gexec
REVOKE ALL ON SCHEMA public FROM PUBLIC;
