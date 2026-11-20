#!/usr/bin/env bash
# Create the two roles and lock down database-level privileges. Idempotent.
. "$(dirname "$0")/lib.sh"
require_server
admin_psql -q -v dbname="$LEDGERX_DB" -v migrator_pw="$MIGRATOR_PASSWORD" -v runtime_pw="$RUNTIME_PASSWORD" \
  -f "$ROOT/database/bootstrap/00_roles.sql" >/dev/null
echo "bootstrap complete for database $LEDGERX_DB"
