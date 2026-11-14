#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
output_file="$(mktemp)"
cleanup() {
  [[ -f "$temp_dir/0001_platform_roles.sql" ]] && unlink "$temp_dir/0001_platform_roles.sql"
  rmdir "$temp_dir"
  unlink "$output_file"
}
trap cleanup EXIT

cp "$ROOT_DIR/database/migrations/0001_platform_roles.sql" \
  "$temp_dir/0001_platform_roles.sql"
printf '\n-- test-only checksum change\n' >> "$temp_dir/0001_platform_roles.sql"

set +e
LEDGERX_MIGRATIONS_DIR="$temp_dir" "$ROOT_DIR/scripts/migrate.sh" \
  >"$output_file" 2>&1
result=$?
set -e
if (( result == 0 )) || ! grep -q 'has changed checksum' "$output_file"; then
  cat "$output_file" >&2
  printf 'Modified applied migration was not rejected.\n' >&2
  exit 1
fi
printf 'Modified applied migration was rejected by checksum verification.\n'
