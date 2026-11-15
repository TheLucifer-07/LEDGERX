#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env"
  set +a
fi

if [[ -n "${LEDGERX_DATABASE_URL:-}" ]]; then
  printf 'Dashboard login setup is local-only; provision ledgerx_dashboard separately for an external database.\n' >&2
  exit 2
fi
if [[ -z "${POSTGRES_DASHBOARD_PASSWORD:-}" ]]; then
  printf 'Set POSTGRES_DASHBOARD_PASSWORD in .env before configuring dashboard access.\n' >&2
  exit 1
fi

# The password is passed through the container environment and psql's
# environment reader, never placed in SQL text or printed to the terminal.
docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db sh -eu -c "
  psql -X -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" <<'SQL'
\\getenv dashboard_password POSTGRES_DASHBOARD_PASSWORD
ALTER ROLE ledgerx_dashboard LOGIN PASSWORD :'dashboard_password';
  -- This local read-only login is confined to the old development records.
  -- Authenticated application sessions will use transaction-local context.
  ALTER ROLE ledgerx_dashboard SET app.workspace_id = '00000000-0000-4000-8000-000000000001';
SQL
"
