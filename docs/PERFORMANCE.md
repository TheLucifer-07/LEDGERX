# Performance engineering — RLS

All numbers on this page were produced by `make bench-rls` (scripts `bench-rls.sh`, `diagnose-rls.sh`, `bench-compare.sh`); raw plans are in `benchmarks/before`, `benchmarks/after`, and `docs/evidence/rls-diagnosis.txt`.

## Methodology
* **Dataset:** deterministic synthetic ledger (`bench.generate(12, 10000, 'ledgerx')`): 12 workspaces (family/student/personal/business), 120,000 entries, 240,000 lines; dataset fingerprint `md5` of all lines = `f901bd13b2cd0e6cf7c6f4135b25508d`, **identical across two independent generations**. Generation re-verifies balance and referential integrity before returning.
* **Environment:** PostgreSQL 17.5 (native x86-64 build), 1 vCPU (Intel Xeon 2.1 GHz), 4 GB RAM, Ubuntu 24.04 VM, default server settings (`shared_buffers=128MB`, `work_mem=4MB`). A single vCPU means parallel query never contributed. This is a small VM, not production hardware; compare ratios, not absolute times.
* **Procedure:** for each context × query: 1 discarded warm-up + 5 timed runs of `EXPLAIN (ANALYZE, BUFFERS)`, warm cache, executed as the real `ledgerx_runtime` role after `lx.set_context`. Reported: median with min–max.
* **Contexts:** A = owner of a personal workspace; B = a family-workspace *member* with private accounts (the most complex predicate).
* **Order of work:** diagnose → measure baseline → change → measure again → prove security equivalence. The baseline was captured with migrations 001–009; migration 010 did not exist yet.

## Diagnosis (before changing anything)
`docs/evidence/rls-diagnosis.txt`:
* Q1 (a per-workspace aggregate) under RLS: **3,766.9 ms**, a *sequential scan of all 240,000 lines* (`Rows Removed by Filter: 220000`).
* The same question with an explicit `workspace_id` filter and no RLS: **7.7 ms** with an index scan — so the indexes were fine; the policy was hiding the predicate.
* `pg_stat_user_functions`: `lx.has_ws_access` was called **231,432 times for that one query** — once per row examined. A `SECURITY DEFINER` function cannot be inlined, is not leakproof, and its argument cannot become an index condition.
* The inlined `ctx_user()` helper also ran a regex on every row (visible in the plan's `Filter`).
* **Hypothesis test** (rolled-back transaction, nothing committed): evaluating the context once per query through scalar sub-selects (InitPlans) → **6.4 ms**, `Index Cond: workspace_id = (InitPlan 1).col1`. The policy was verified unchanged afterwards.

## The change (migration 010)
Replace per-row calls with once-per-query facts: `workspace_id = (SELECT lx.ctx_workspace()) AND (SELECT lx.ctx_has_access()) AND …`; set-returning helpers for the `workspaces` and `users` policies. No policy was weakened: **`50_rls_policy_equivalence.sql` computes, for every member, for no context, and for members probing foreign workspaces, a fingerprint of exactly which rows each of 9 protected relations exposes under the old and the new predicates, and requires them to be identical** (with a negative control showing a leaky policy is detected). The entire isolation and family-privacy suites also pass unchanged on the new policies.

## Results
```
label: after   date: 2026-11-20T07:05:48Z
postgres: PostgreSQL 17.5 on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 7.5.0-3ubuntu1~18.04) 7.5.0, 64-bit
cpu: Intel(R) Xeon(R) Processor @ 2.10GHz  cores: 1  mem: 3992 MB
os: Ubuntu 24.04.5 LTS  kernel: 6.18.44-fc-v726
shared_buffers = 128MB
work_mem = 4MB
effective_cache_size = 4GB
max_parallel_workers_per_gather = 2
random_page_cost = 4
jit = on
method: warm cache; 1 discarded warm-up + 5 timed runs per (context, query); EXPLAIN (ANALYZE, BUFFERS); role=ledgerx_runtime; parallel query left at server default
dataset: workspaces=12 entries_per_workspace=10000 seed=ledgerx  (generated+verified+analyzed in 7s)
rows workspaces 12
rows users 18
rows account_balances 117
rows accounts 141
rows journal_entries 120000
rows journal_lines 240000
fingerprint md5(all lines, ordered by id) f901bd13b2cd0e6cf7c6f4135b25508d
size account_balances 64 kB
size accounts 136 kB
size journal_entries 38 MB
size journal_lines 78 MB
```

Median of 5 timed runs (after 1 discarded warm-up) of EXPLAIN (ANALYZE, BUFFERS), executed as the real `ledgerx_runtime` role with a verified tenant context. Times in milliseconds.

| Context | Query | Before (ms) | After (ms) | Speed-up | After min–max (ms) |
|---|---|--:|--:|--:|---|
| A_personal_owner | q1_workspace_totals | 4050.872 | 6.521 | **621.2×** | 6.478–6.897 |
| B_family_member | q1_workspace_totals | 5078.630 | 9.508 | **534.1×** | 9.334–10.346 |
| A_personal_owner | q2_account_ledger | 1303.643 | 13.333 | **97.8×** | 11.716–16.230 |
| B_family_member | q2_account_ledger | 1772.421 | 10.524 | **168.4×** | 10.337–11.097 |
| A_personal_owner | q3_recent_entries | 2018.166 | 0.299 | **6749.7×** | 0.268–0.332 |
| B_family_member | q3_recent_entries | 2576.705 | 0.350 | **7362.0×** | 0.300–0.439 |
| A_personal_owner | q4_monthly_cashflow | 2239.508 | 32.524 | **68.9×** | 31.550–32.848 |
| B_family_member | q4_monthly_cashflow | 3335.500 | 33.735 | **98.9×** | 33.602–33.895 |
| A_personal_owner | q5_account_balances | 3.526 | 0.520 | **6.8×** | 0.501–0.538 |
| B_family_member | q5_account_balances | 5.800 | 0.622 | **9.3×** | 0.588–0.641 |
| A_personal_owner | q6_directory | 3.427 | 0.730 | **4.7×** | 0.659–0.901 |
| B_family_member | q6_directory | 4.676 | 1.012 | **4.6×** | 0.986–1.028 |

### Lower bound: the same questions with no RLS and an explicit `workspace_id` filter (administrator)

| Query | No-RLS reference (ms) | RLS before (ms) | RLS after (ms) | after ÷ reference |
|---|--:|--:|--:|--:|
| q1_workspace_totals | 5.570 | 4050.872 | 6.521 | 1.2× |
| q2_account_ledger | 11.250 | 1303.643 | 13.333 | 1.2× |
| q3_recent_entries | 0.027 | 2018.166 | 0.299 | 11.1× |

### Control: queries that migration 010 does not touch (no RLS involved) — run-to-run variation between the two sessions

| Query | Run 1 median (ms) | Run 2 median (ms) | Difference |
|---|--:|--:|--:|
| q1_workspace_totals | 5.605 | 5.570 | -1% |
| q2_account_ledger | 9.776 | 11.250 | +15% |
| q3_recent_entries | 0.025 | 0.027 | +8% |

### Reading the results honestly
* The old policies cost time proportional to *all tenants'* rows (a sequential scan); the new ones scale with the *current tenant's* rows. The speed-ups therefore grow with table size and are specific to this dataset; the 7,000× on Q3 is a `LIMIT 50` query that now walks an index for 50 rows versus filtering 120,000.
* After the fix, tenant queries are within ~1.2× of the hand-written no-RLS equivalent for Q1/Q2. Q3 remains ~0.27 ms slower than the reference: the plan shows `InitPlan 2` (the membership check) costing ≈ 0.25 ms, a fixed per-query price of the safety check.
* The **control** table shows the noise floor: queries untouched by the migration varied −1 % to +15 % between two sessions. Differences smaller than that should not be read as signal.
* Single warm-cache VM, synthetic data, 5 runs per cell. Not a throughput benchmark, and no claim is made about other hardware.

## Not yet measured / next
* Q4 (monthly cash-flow aggregation, ~33 ms over one tenant's 20k lines) is now dominated by aggregation, not RLS — a candidate for covering/partial indexes or a materialised view (Phase 2–3), to be decided only with `EXPLAIN` evidence.
* A scratch probe during review suggested contention on hot accounts' projection rows under parallel posting; this has **not** been measured properly and no concurrency mechanism will be added without measured evidence (Phase 3).
