# RLS benchmark: before vs after migration 010

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
