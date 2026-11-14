#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/setup.sh"
set -a
# shellcheck disable=SC1091
. "$ROOT_DIR/.env"
set +a
docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
  psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
  < "$ROOT_DIR/examples/end_to_end_demo.sql"
