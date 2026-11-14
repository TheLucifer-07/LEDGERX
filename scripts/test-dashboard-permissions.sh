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
  psql -X -v ON_ERROR_STOP=1 "$LEDGERX_DATABASE_URL" \
    -f "$ROOT_DIR/tests/dashboard_read_only.sql"
else
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
    psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
    -f /dev/stdin < "$ROOT_DIR/tests/dashboard_read_only.sql"
fi
printf 'Dashboard read-only role assertions passed.\n'
