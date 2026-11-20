#!/usr/bin/env bash
# Build benchmarks/rls-comparison.md from two results.tsv files:  bench-compare.sh before after
. "$(dirname "$0")/lib.sh"
B="$ROOT/benchmarks/${1:?before}"; A="$ROOT/benchmarks/${2:?after}"; OUT="$ROOT/benchmarks/rls-comparison.md"
awk -F'\t' -v OFS='\t' 'NR==FNR { if (FNR>1) b[$1"|"$2]=$4; next } FNR>1 { k=$1"|"$2; if (k in b) print $1, $2, b[k], $4, $5, $6 }' "$B/results.tsv" "$A/results.tsv" > "$ROOT/benchmarks/.cmp.tsv"
{
  echo "# RLS benchmark: before vs after migration 010"
  echo
  echo '```'; sed -n '1,4p;/^shared_buffers/,/^jit/p;/^method/p;/^dataset/,$p' "$A/environment.txt"; echo '```'
  echo
  echo "Median of 5 timed runs (after 1 discarded warm-up) of EXPLAIN (ANALYZE, BUFFERS), executed as the real \`ledgerx_runtime\` role with a verified tenant context. Times in milliseconds."
  echo
  echo "| Context | Query | Before (ms) | After (ms) | Speed-up | After min–max (ms) |"
  echo "|---|---|--:|--:|--:|---|"
  awk -F'\t' '$1 != "A_reference_noRLS" { printf "| %s | %s | %.3f | %.3f | **%.1f×** | %.3f–%.3f |\n", $1, $2, $3, $4, ($4>0 ? $3/$4 : 0), $5, $6 }' "$ROOT/benchmarks/.cmp.tsv"
  echo
  echo "### Lower bound: the same questions with no RLS and an explicit \`workspace_id\` filter (administrator)"
  echo
  echo "| Query | No-RLS reference (ms) | RLS before (ms) | RLS after (ms) | after ÷ reference |"
  echo "|---|--:|--:|--:|--:|"
  awk -F'\t' 'NR==FNR { if (FNR>1 && $1=="A_reference_noRLS") r[$2]=$4; next } $1=="A_personal_owner" && ($2 in r) { printf "| %s | %.3f | %.3f | %.3f | %.1f× |\n", $2, r[$2], $3, $4, $4/r[$2] }' "$A/results.tsv" "$ROOT/benchmarks/.cmp.tsv"
  echo
  echo "### Control: queries that migration 010 does not touch (no RLS involved) — run-to-run variation between the two sessions"
  echo
  echo "| Query | Run 1 median (ms) | Run 2 median (ms) | Difference |"
  echo "|---|--:|--:|--:|"
  awk -F'\t' '$1 == "A_reference_noRLS" { printf "| %s | %.3f | %.3f | %+.0f%% |\n", $2, $3, $4, ($4-$3)/$3*100 }' "$ROOT/benchmarks/.cmp.tsv"
} > "$OUT"
rm -f "$ROOT/benchmarks/.cmp.tsv"
cat "$OUT"
