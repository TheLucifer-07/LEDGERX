#!/usr/bin/env bash
# Diagnose WHY queries are slow under RLS before changing any policy.  Output: docs/evidence/rls-diagnosis.txt
# Experiments that alter a policy run inside BEGIN ... ROLLBACK, so nothing is committed.
. "$(dirname "$0")/lib.sh"
require_server
SEED="${BENCH_SEED:-ledgerx}"; OUT="$ROOT/docs/evidence/rls-diagnosis.txt"
uid() { admin_psql -qAt -c "SELECT bench.uid('$1', '$SEED', '$2')"; }
WS=$(uid ws 2); USR=$(uid user 2-0)
Q1=$(cat "$ROOT/benchmarks/queries/rls/q1_workspace_totals.sql"); Q3=$(cat "$ROOT/benchmarks/queries/rls/q3_recent_entries.sql")
{
echo "# RLS diagnosis — $(admin_psql -qAt -c 'SELECT version()')"
echo "# migrations applied: $(admin_psql -qAt -c "SELECT string_agg(version, ',' ORDER BY version) FROM lx.schema_migrations")"
echo "# dataset: $(head -1 "$ROOT/benchmarks/dataset.txt")"
echo "# context: personal workspace owner (workspace $WS)"
admin_psql -qAt <<SQL
\echo
\echo '== D1. Policy predicate currently on lx.journal_lines'
SELECT qual FROM pg_policies WHERE schemaname='lx' AND tablename='journal_lines';
\echo
\echo '== D2. Plan under RLS (runtime role + verified context) — Q1 workspace totals'
BEGIN; SET LOCAL ROLE ledgerx_runtime; SELECT lx.set_context('$USR','$WS') \gset
EXPLAIN (ANALYZE, BUFFERS) $Q1;
ROLLBACK;
\echo
\echo '== D3. Same question without RLS, explicit workspace filter (what the indexes can do)'
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*), sum(debit), sum(credit) FROM lx.journal_lines WHERE workspace_id = '$WS';
\echo
\echo '== D4. How often is each helper function called for ONE execution of Q1?'
SELECT pg_stat_reset() \gset
BEGIN; SET LOCAL track_functions = 'all'; SET LOCAL ROLE ledgerx_runtime; SELECT lx.set_context('$USR','$WS') \gset
SELECT count(*) AS lines_in_table FROM (SELECT 1 FROM lx.journal_lines) s \gset
RESET ROLE;
SELECT pg_stat_force_next_flush() \gset
COMMIT;
SELECT funcname, calls FROM pg_stat_user_functions WHERE schemaname='lx' AND funcname IN ('has_ws_access','is_member_of','can_see_private','ctx_workspace','ctx_user') ORDER BY calls DESC, funcname;
SELECT 'rows in journal_lines (all tenants): ' || count(*) FROM lx.journal_lines;
\echo
\echo '== D5. HYPOTHESIS TEST (rolled back): evaluate the context once per query via sub-selects (InitPlans)'
BEGIN;
ALTER POLICY lines_select ON lx.journal_lines USING (
  workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.is_member_of((SELECT lx.ctx_workspace())))
  AND (private_owner_id IS NULL OR private_owner_id = (SELECT lx.ctx_user())));
SET LOCAL ROLE ledgerx_runtime; SELECT lx.set_context('$USR','$WS') \gset
EXPLAIN (ANALYZE, BUFFERS) $Q1;
ROLLBACK;
\echo
\echo '== D6. Policy after the experiment (must be unchanged: the experiment was rolled back)'
SELECT qual FROM pg_policies WHERE schemaname='lx' AND tablename='journal_lines';
SQL
} 2>&1 | tee "$OUT"
