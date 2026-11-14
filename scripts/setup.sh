#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  printf 'Missing .env. Copy .env.example to .env and set a local password.\n' >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

docker compose up -d --wait db
"$ROOT_DIR/scripts/migrate.sh"
"$ROOT_DIR/scripts/seed.sh"
