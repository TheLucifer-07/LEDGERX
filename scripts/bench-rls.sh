#!/usr/bin/env bash
# Repeatable RLS benchmark.  ./scripts/bench-rls.sh <label> [repetitions=7]
# For each context x query: 1 discarded warm-up + N timed runs of EXPLAIN (ANALYZE, BUFFERS) as the
# real ledgerx_runtime role with a verified tenant context (the way an application would run it).
# Results: benchmarks/<label>/{environment.txt,results.tsv,plans/*.txt}
. "$(dirname "$0")/lib.sh"
require_server
LABEL="${1:?usage: bench-rls.sh <label> [reps]}"; REPS="${2:-7}"; SEED="${BENCH_SEED:-ledgerx}"
OUT="$ROOT/benchmarks/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT/plans"
QDIR="$ROOT/benchmarks/queries/rls"
uid() { admin_psql -qAt -c "SELECT bench.uid('$1', '$SEED', '$2')"; }

WS_A=$(uid ws 2); USER_A=$(uid user 2-0)           # personal workspace, owner
WS_B=$(uid ws 4); USER_B=$(uid user 4-1)           # family workspace, member with private accounts (most complex predicate)
CASH_A=$(uid acct "2:1000:")

{
  echo "label: $LABEL   date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "postgres: $(admin_psql -qAt -c 'SELECT version()')"
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)  cores: $(nproc)  mem: $(free -m | awk '/Mem:/{print $2" MB"}')"
  echo "os: $(. /etc/os-release; echo "$PRETTY_NAME")  kernel: $(uname -r)"
  for s in shared_buffers work_mem effective_cache_size max_parallel_workers_per_gather random_page_cost jit; do echo "$s = $(admin_psql -qAt -c "SHOW $s")"; done
  echo "migrations applied: $(admin_psql -qAt -c "SELECT string_agg(version, ',' ORDER BY version) FROM lx.schema_migrations")"
  echo "method: warm cache; 1 discarded warm-up + $REPS timed runs per (context, query); EXPLAIN (ANALYZE, BUFFERS); role=ledgerx_runtime; parallel query left at server default"
  cat "$ROOT/benchmarks/dataset.txt" 2>/dev/null
} > "$OUT/environment.txt"

printf "context\tquery\truns\tmedian_ms\tmin_ms\tmax_ms\tshared_hit\tshared_read\tscans\n" > "$OUT/results.tsv"

run_one() { # context-name user ws query-file mode(rls|ref)
  local ctx=$1 usr=$2 ws=$3 qf=$4 mode=$5 q name script
  name=$(basename "$qf" .sql); name=${name%.ref}
  q=$(sed -e "s/__WS__/$ws/g" -e "s/__CASH__/$CASH_A/g" "$qf")
  script="$OUT/.script.sql"; : > "$script"
  for i in $(seq 0 "$REPS"); do
    if [ "$mode" = rls ]; then
      printf "BEGIN;\nSELECT lx.set_context('%s','%s');\nEXPLAIN (ANALYZE, BUFFERS) %s;\nROLLBACK;\n" "$usr" "$ws" "$q" >> "$script"
    else
      printf "EXPLAIN (ANALYZE, BUFFERS) %s;\n" "$q" >> "$script"
    fi
  done
  if [ "$mode" = rls ]; then runtime_psql -qAt -f "$script" > "$OUT/.raw" 2>&1; else admin_psql -qAt -f "$script" > "$OUT/.raw" 2>&1; fi
  grep -q "Execution Time" "$OUT/.raw" || { echo "benchmark failed for $ctx/$name:"; head -5 "$OUT/.raw"; exit 1; }
  # split into runs, drop the first (warm-up)
  awk -v out="$OUT/plans/${ctx}_${name}" 'BEGIN{r=0} /^ *(Planning Time|Execution Time)/{ } {print > "/dev/null"} 
    /^(Aggregate|Limit|Sort|Index|Seq|Bitmap|Nested|Hash|Merge|Gather|Subquery|Result|WindowAgg|GroupAggregate|HashAggregate|Unique|Append|ProjectSet|CTE|Materialize|Parallel|Finalize|Partial|Incremental)/ || /^ *->/ || /Time:/ || /Buffers:/ || /Filter:|Index Cond|Hash Cond|Join Filter|InitPlan|SubPlan|Rows Removed|Heap Fetches|Workers|Sort Method|Planning|Memory/ {print > out ".all"}' "$OUT/.raw"
  mapfile -t times < <(grep -E "^ *Execution Time" "$OUT/.raw" | sed -E 's/.*: ([0-9.]+) ms/\1/' | tail -n "$REPS")
  # last run's full plan as evidence
  awk 'BEGIN{n=0} /^(Aggregate|Limit|Sort|Index|Seq|Bitmap|Nested|Hash|Merge|Gather|Subquery|Result|WindowAgg|GroupAggregate|HashAggregate|Unique|Append|Finalize)/{n++} {a[n]=a[n] $0 "\n"} END{printf "%s", a[n]}' "$OUT/.raw" > "$OUT/plans/${ctx}_${name}.txt"
  rm -f "$OUT/plans/${ctx}_${name}.all"
  local sorted med min max hit read scans
  sorted=$(printf "%s\n" "${times[@]}" | sort -n)
  med=$(echo "$sorted" | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
  min=$(echo "$sorted" | head -1); max=$(echo "$sorted" | tail -1)
  hit=$(grep -m1 -oE 'shared hit=[0-9]+' "$OUT/plans/${ctx}_${name}.txt" | cut -d= -f2 || true); read=$(grep -m1 -oE 'read=[0-9]+' "$OUT/plans/${ctx}_${name}.txt" | cut -d= -f2 || true)
  scans=$(grep -oE '(Parallel )?(Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan)' "$OUT/plans/${ctx}_${name}.txt" | sort | uniq -c | awk '{c=$1; $1=""; printf "%s%s x%s", (s++?"; ":""), substr($0,2), c}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$ctx" "$name" "${#times[@]}" "$med" "$min" "$max" "${hit:-0}" "${read:-0}" "$scans" >> "$OUT/results.tsv"
  printf "  %-14s %-22s median %9s ms  (min %s, max %s)\n" "$ctx" "$name" "$med" "$min" "$max"
}

echo "== $LABEL: ${REPS} timed runs per query"
for qf in "$QDIR"/q?_*.sql; do case "$qf" in *.ref.sql) continue;; esac
  run_one A_personal_owner "$USER_A" "$WS_A" "$qf" rls
  run_one B_family_member  "$USER_B" "$WS_B" "$qf" rls
done
for qf in "$QDIR"/q?_*.ref.sql; do run_one A_reference_noRLS "" "$WS_A" "$qf" ref; done
rm -f "$OUT/.script.sql" "$OUT/.raw"
echo "wrote $OUT/results.tsv"
