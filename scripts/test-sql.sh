#!/usr/bin/env bash
# Ordinary SQL correctness tests (pgTAP). Each file runs inside BEGIN ... ROLLBACK, so these tests
# prove SINGLE-SESSION behaviour only. Concurrency and committed-transaction behaviour is covered
# by scripts/test-multisession.sh. Writes the raw TAP stream to docs/evidence/sql-tests.tap.
. "$(dirname "$0")/lib.sh"
require_server
FILTER="${1:-}"
admin_psql -q -c 'CREATE SCHEMA IF NOT EXISTS tap' >/dev/null
if [ "$(admin_psql -qAt -c "SELECT to_regprocedure('tap.plan(integer)') IS NOT NULL")" != "t" ]; then
  { echo "SET search_path = tap;"; cat "$ROOT/third_party/pgtap/pgtap-1.3.4.sql"; } | admin_psql -q >/dev/null
fi
admin_psql -q -f "$ROOT/database/tests/helpers/helpers.sql" >/dev/null
# bench generator is used by the policy-equivalence test
admin_psql -q -f "$ROOT/database/seeds/bench_generator.sql" >/dev/null

OUT="$ROOT/docs/evidence/sql-tests.tap"; : > "$OUT"
total=0; failed=0; files=0
{
  echo "# LedgerX SQL tests (pgTAP 1.3.4) — $(admin_psql -qAt -c 'SELECT version()')"
  echo "# database=$LEDGERX_DB  run=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee -a "$OUT"
for f in "$ROOT"/database/tests/sql/*.sql; do
  name=$(basename "$f")
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi
  files=$((files+1))
  echo "# --- $name" | tee -a "$OUT"
  res=$(admin_psql -qAt -v VERBOSITY=terse -c 'SET search_path = tap, public' -f "$f" 2>&1) || { echo "$res" | tee -a "$OUT"; echo "not ok - $name aborted with an SQL error" | tee -a "$OUT"; failed=$((failed+1)); continue; }
  echo "$res" | grep -E "^(ok|not ok|#|1\.\.|    )" | tee -a "$OUT"
  n=$(echo "$res" | grep -cE '^(not )?ok ' || true); nf=$(echo "$res" | grep -cE '^not ok ' || true)
  planline=$(echo "$res" | grep -E '^1\.\.[0-9]+$' | head -1 | sed 's/1\.\.//')
  total=$((total+n)); failed=$((failed+nf))
  if [ "${planline:-x}" != "$n" ]; then echo "not ok - $name: plan ${planline:-none} != executed $n" | tee -a "$OUT"; failed=$((failed+1)); fi
done
echo "# SUMMARY files=$files assertions=$total failed=$failed" | tee -a "$OUT"
[ "$failed" -eq 0 ] && [ "$total" -gt 0 ]
