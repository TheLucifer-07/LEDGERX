#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="$ROOT_DIR/database/migrations"

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  printf 'Missing .env. Run scripts/setup.sh after copying .env.example.\n' >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. "$ROOT_DIR/.env"
set +a

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

psql_in_db() {
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
    psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" "$@"
}

psql_in_db -c "CREATE TABLE IF NOT EXISTS public.ledgerx_schema_migrations (
  version text PRIMARY KEY,
  checksum text NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$'),
  applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
)"

shopt -s nullglob
migration_files=("$MIGRATIONS_DIR"/[0-9][0-9][0-9][0-9]_*.sql)
if (( ${#migration_files[@]} == 0 )); then
  printf 'No migrations found in %s.\n' "$MIGRATIONS_DIR" >&2
  exit 1
fi

previous_version=""
for migration_file in "${migration_files[@]}"; do
  filename="$(basename "$migration_file")"
  if [[ ! "$filename" =~ ^([0-9]{4}_[a-z0-9_]+)\.sql$ ]]; then
    printf 'Invalid migration filename: %s\n' "$filename" >&2
    exit 1
  fi
  version="${BASH_REMATCH[1]}"
  if [[ -n "$previous_version" && "$version" == "$previous_version" ]]; then
    printf 'Duplicate migration version: %s\n' "$version" >&2
    exit 1
  fi
  previous_version="$version"
  checksum="$(hash_file "$migration_file")"

  driver_file="$(mktemp)"
  trap 'rm -f "$driver_file"' EXIT
  cat >"$driver_file" <<SQL
BEGIN;
SELECT pg_advisory_xact_lock(739118240067);
DO \$migration_guard\$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.ledgerx_schema_migrations
    WHERE version = '$version' AND checksum <> '$checksum'
  ) THEN
    RAISE EXCEPTION 'Applied migration % has changed checksum', '$version';
  END IF;
END
\$migration_guard\$;
SELECT NOT EXISTS (
  SELECT 1 FROM public.ledgerx_schema_migrations WHERE version = '$version'
) AS needs_apply \\gset
\\if :needs_apply
SQL
  if [[ "$version" != "0001_platform_roles" ]]; then
    printf 'SET LOCAL ROLE ledgerx_owner;\n' >>"$driver_file"
  fi
  cat "$migration_file" >>"$driver_file"
  cat >>"$driver_file" <<SQL
RESET ROLE;
INSERT INTO public.ledgerx_schema_migrations (version, checksum)
VALUES ('$version', '$checksum');
\\endif
COMMIT;
SQL
  psql_in_db <"$driver_file"
  rm -f "$driver_file"
  trap - EXIT
  printf 'Applied or verified migration %s\n' "$version"
done
