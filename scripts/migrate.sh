#!/usr/bin/env bash
# Apply pending migrations in filename order, each in its own transaction, as ledgerx_migrator.
# Applied versions are skipped; an edited, already-applied migration is an error (checksum).
#   MIGRATE_TO=008 ./scripts/migrate.sh      apply up to and including version 008
#   MIGRATIONS_DIR=... ./scripts/migrate.sh  use another directory (used by the migration tests)
. "$(dirname "$0")/lib.sh"
DIR="${MIGRATIONS_DIR:-$ROOT/database/migrations}"
exec 9>"${TMPDIR:-/tmp}/ledgerx-migrate-$LEDGERX_DB.lock"; flock 9   # one runner at a time on this host

migrator_psql -q <<'SQL' >/dev/null
CREATE SCHEMA IF NOT EXISTS lx;
CREATE TABLE IF NOT EXISTS lx.schema_migrations (
  version text PRIMARY KEY, name text NOT NULL, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now());
SQL

applied=0; skipped=0
for f in $(ls "$DIR"/[0-9][0-9][0-9]_*.sql | sort); do
  name=$(basename "$f"); version=${name:0:3}
  if [ -n "${MIGRATE_TO:-}" ] && [[ "$version" > "$MIGRATE_TO" ]]; then break; fi
  sum=$(sha256sum "$f" | cut -d' ' -f1)
  existing=$(migrator_psql -qAt -c "SELECT checksum FROM lx.schema_migrations WHERE version = '$version'")
  if [ -n "$existing" ]; then
    if [ "$existing" != "$sum" ]; then echo "ERROR: migration $name was modified after it was applied (checksum mismatch)" >&2; exit 1; fi
    skipped=$((skipped+1)); continue
  fi
  echo "applying $name"
  { echo "BEGIN;"; cat "$f"; echo; echo "INSERT INTO lx.schema_migrations (version, name, checksum) VALUES ('$version', '$name', '$sum');"; echo "COMMIT;"; } \
    | migrator_psql -q >/dev/null || { echo "ERROR: migration $name failed (rolled back)" >&2; exit 1; }
  applied=$((applied+1))
done
echo "migrations: applied=$applied already-applied=$skipped"
