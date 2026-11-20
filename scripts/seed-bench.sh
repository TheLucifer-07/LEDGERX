#!/usr/bin/env bash
# Load the deterministic benchmark dataset:  ./scripts/seed-bench.sh [workspaces=20] [entries_per_workspace=25000] [seed=ledgerx]
# Requires an EMPTY ledger (fresh database) and a superuser connection. Writes benchmarks/dataset.txt.
. "$(dirname "$0")/lib.sh"
require_server
W="${1:-20}"; E="${2:-25000}"; SEED="${3:-ledgerx}"
if [ "$(admin_psql -qAt -c 'SELECT count(*) FROM lx.workspaces')" != "0" ]; then echo "database already contains data; run make db-reset first" >&2; exit 1; fi
admin_psql -q -f "$ROOT/database/seeds/bench_generator.sql" >/dev/null
start=$(date +%s)
admin_psql -q -c "SELECT bench.generate($W, $E, '$SEED')" >/dev/null
admin_psql -q -c 'VACUUM (ANALYZE) lx.users, lx.workspaces, lx.workspace_members, lx.accounts, lx.journal_entries, lx.journal_lines, lx.account_balances, lx.audit_events' >/dev/null
secs=$(( $(date +%s) - start ))
{
  echo "dataset: workspaces=$W entries_per_workspace=$E seed=$SEED  (generated+verified+analyzed in ${secs}s)"
  admin_psql -qAt -F ' ' -c "SELECT 'rows', 'workspaces', count(*) FROM lx.workspaces UNION ALL SELECT 'rows','users',count(*) FROM lx.users UNION ALL SELECT 'rows','accounts',count(*) FROM lx.accounts UNION ALL SELECT 'rows','journal_entries',count(*) FROM lx.journal_entries UNION ALL SELECT 'rows','journal_lines',count(*) FROM lx.journal_lines UNION ALL SELECT 'rows','account_balances',count(*) FROM lx.account_balances"
  admin_psql -qAt -F ' ' -c "SELECT 'fingerprint', 'md5(all lines, ordered by id)', md5(string_agg(id::text || ':' || debit::text || ':' || credit::text, ',' ORDER BY id)) FROM lx.journal_lines"
  admin_psql -qAt -F ' ' -c "SELECT 'size', relname, pg_size_pretty(pg_total_relation_size(c.oid)) FROM pg_class c WHERE relnamespace = 'lx'::regnamespace AND relname IN ('journal_lines','journal_entries','accounts','account_balances') ORDER BY relname"
} | tee "$ROOT/benchmarks/dataset.txt"
