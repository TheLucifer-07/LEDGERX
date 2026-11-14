#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scale="${1:-100000}"
if [[ ! "$scale" =~ ^[0-9]+$ ]] || (( scale < 1 || scale > 1000000 )); then
  printf 'Scale must be an integer from 1 through 1000000.\n' >&2
  exit 2
fi
if [[ ! -f "$ROOT_DIR/.env" ]]; then
  printf 'Missing .env. Run scripts/setup.sh first.\n' >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. "$ROOT_DIR/.env"
set +a

mkdir -p "$ROOT_DIR/benchmarks/results"
output_file="$ROOT_DIR/benchmarks/results/account-activity-${scale}.txt"
{
  printf 'LedgerX isolated synthetic account-activity benchmark\n'
  printf 'Run time UTC: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
  printf 'Host: %s\n' "$(uname -a)"
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
    psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
      -c 'SELECT version();'
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
    psql -X -v ON_ERROR_STOP=1 -v scale="$scale" \
      -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
      < "$ROOT_DIR/benchmarks/workload.sql"
} 2>&1 | tee "$output_file"
printf 'Saved observed plan to %s\n' "$output_file"
