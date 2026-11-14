#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -z "${LEDGERX_DATABASE_URL:-}" && ! -f .env ]]; then
  printf 'Missing .env. Copy .env.example to .env and set a local password.\n' >&2
  exit 1
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [[ -z "${LEDGERX_DATABASE_URL:-}" ]]; then
  docker compose up -d --wait db
fi
"$ROOT_DIR/scripts/migrate.sh"
"$ROOT_DIR/scripts/seed.sh"
