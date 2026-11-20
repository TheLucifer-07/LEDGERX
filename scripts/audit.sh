#!/usr/bin/env bash
# Print the security posture report (read-only) and save it to docs/evidence/security-audit.txt
. "$(dirname "$0")/lib.sh"
require_server
admin_psql -X -q -f "$ROOT/database/audit/security_audit.sql" 2>&1 | tee "$ROOT/docs/evidence/security-audit.txt"
