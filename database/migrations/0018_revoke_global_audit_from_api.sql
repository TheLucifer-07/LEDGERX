-- The general integrity auditor is SECURITY DEFINER and scans all workspaces.
-- It remains an operator/runtime tool, not an authenticated tenant API surface.
REVOKE EXECUTE ON FUNCTION ledger.audit_integrity() FROM ledgerx_api;
