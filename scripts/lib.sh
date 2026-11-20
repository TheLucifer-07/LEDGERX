# shellcheck shell=bash
# Shared helpers. Source this file; do not execute it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
: "${PGHOST:=localhost}" "${PGPORT:=5432}" "${PGUSER:=postgres}"
: "${LEDGERX_DB:=ledgerx}" "${MIGRATOR_PASSWORD:=ledgerx_migrator_dev}" "${RUNTIME_PASSWORD:=ledgerx_runtime_dev}"
export PGHOST PGPORT PGUSER LEDGERX_DB MIGRATOR_PASSWORD RUNTIME_PASSWORD
export PGCONNECT_TIMEOUT=10
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"

# admin (superuser) connection to the LedgerX database / to the maintenance database
admin_psql()  { psql -X -v ON_ERROR_STOP=1 -d "$LEDGERX_DB" "$@"; }
maint_psql()  { psql -X -v ON_ERROR_STOP=1 -d postgres "$@"; }
# connections as the application roles
migrator_psql() { PGUSER=ledgerx_migrator PGPASSWORD="$MIGRATOR_PASSWORD" psql -X -v ON_ERROR_STOP=1 -d "$LEDGERX_DB" "$@"; }
runtime_psql()  { PGUSER=ledgerx_runtime  PGPASSWORD="$RUNTIME_PASSWORD"  psql -X -v ON_ERROR_STOP=1 -d "$LEDGERX_DB" "$@"; }

require_server() {
  if ! maint_psql -qAt -c 'SELECT 1' >/dev/null 2>&1; then
    echo "Cannot connect to PostgreSQL at $PGHOST:$PGPORT as $PGUSER. Start it (make up) or set PG* variables." >&2
    exit 1
  fi
  local major; major=$(maint_psql -qAt -c "SHOW server_version_num" | cut -c1-2)
  if [ "$major" -lt 17 ]; then echo "PostgreSQL 17+ required (found server_version_num=$(maint_psql -qAt -c 'SHOW server_version_num'))." >&2; exit 1; fi
}
