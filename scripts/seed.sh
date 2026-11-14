#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${LEDGERX_DATABASE_URL:-}" && ! -f "$ROOT_DIR/.env" ]]; then
  printf 'Missing .env. Run scripts/setup.sh after copying .env.example.\n' >&2
  exit 1
fi

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env"
  set +a
fi

if [[ -n "${LEDGERX_DATABASE_URL:-}" ]]; then
  psql -X -v ON_ERROR_STOP=1 "$LEDGERX_DATABASE_URL" \
    < "$ROOT_DIR/seeds/reference_data.sql"
else
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
    psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
    < "$ROOT_DIR/seeds/reference_data.sql"
fi
