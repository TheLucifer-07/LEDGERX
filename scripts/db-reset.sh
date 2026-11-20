#!/usr/bin/env bash
# Drop and recreate $LEDGERX_DB, bootstrap roles, apply migrations. DESTROYS the database.
. "$(dirname "$0")/lib.sh"
require_server
maint_psql -q -c "DROP DATABASE IF EXISTS \"$LEDGERX_DB\" WITH (FORCE)" -c "CREATE DATABASE \"$LEDGERX_DB\"" >/dev/null
"$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/migrate.sh"
