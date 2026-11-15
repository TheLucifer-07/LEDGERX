\set ON_ERROR_STOP on
SET SESSION AUTHORIZATION ledgerx_api;
SET default_transaction_read_only = on;
BEGIN READ WRITE;

SELECT user_id, workspace_id, workspace_type, workspace_name, created
  FROM ledger.bootstrap_workspace(
    '10000000-0000-4000-8000-000000000099',
    'student',
    'API Bootstrap Test',
    'INR',
    'Asia/Kolkata'
  ) \gset first_
\echo first created=:first_created workspace=:first_workspace_id type=:first_workspace_type name=:first_workspace_name
SELECT 1 / (CASE WHEN :'first_created'::boolean THEN 1 ELSE 0 END);

SELECT user_id, workspace_id, workspace_type, workspace_name, created
  FROM ledger.bootstrap_workspace(
    '10000000-0000-4000-8000-000000000099',
    'business',
    'Changed Retry Payload',
    'INR',
    'Asia/Kolkata'
  ) \gset retry_
SELECT :'first_workspace_id'::uuid = :'retry_workspace_id'::uuid
       AND :'retry_created'::boolean = false
       AND :'retry_workspace_type' = 'student'
       AND :'retry_workspace_name' = 'API Bootstrap Test' AS retry_is_original \gset
\echo retry created=:retry_created workspace=:retry_workspace_id type=:retry_workspace_type name=:retry_workspace_name
SELECT 1 / (CASE WHEN :'retry_is_original'::boolean THEN 1 ELSE 0 END);

ROLLBACK;
RESET SESSION AUTHORIZATION;
\echo 'Workspace bootstrap creates one starter workspace, returns it on retry, and rolls back cleanly.'
