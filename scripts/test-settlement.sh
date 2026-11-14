#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$ROOT_DIR/.env" ]]; then
  printf 'Missing .env. Run scripts/setup.sh first.\n' >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "$ROOT_DIR/.env"
set +a

"$ROOT_DIR/scripts/setup.sh"
docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
  psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
  < "$ROOT_DIR/tests/settlement_reconciliation.sql"
