# Testing

Two layers with different guarantees, plus an audit and a benchmark harness. All results below are from real runs; raw output is committed in `docs/evidence/`.

| Layer | Command | Assertions | What it proves | What it cannot prove |
|---|---|---:|---|---|
| **SQL tests** — pgTAP 1.3.4, each file inside `BEGIN … ROLLBACK` | `make test-sql` | **202** | Single-session logic: posting, validation, currencies, idempotency semantics, immutability, reversals, transfers, projection drift/rebuild, tenant isolation, family privacy, role limits, security posture, policy equivalence | Concurrency, real `COMMIT` behaviour, connection reuse. A rolled-back test says nothing about races. |
| **Multi-session tests** — Bash + real parallel `psql` connections as `ledgerx_runtime` | `make test-multisession` | **38** | Races (12 concurrent identical posts; 8 concurrent reversals; 40 opposing-order posts; rebuild racing live postings), deferred balance trigger at a real COMMIT, TRUNCATE/line-append protection, context non-leakage on a reused connection, real-login escalation attempts, migration idempotency/checksums | Load or throughput (see PERFORMANCE.md) |
| **Security audit** | `make audit` | catalog report | Ownership, PUBLIC grants, runtime privileges, definer `search_path`, RLS policies | — |

Per-file SQL assertions: `10_ledger_posting` 32 · `11_immutability` 14 · `12_reversals_transfers_projection` 26 · `20_tenant_isolation` 55 · `21_family_privacy` 33 · `30_security_audit` 29 · `50_rls_policy_equivalence` 13.

## Design notes
* pgTAP is genuinely used: `third_party/pgtap/pgtap-1.3.4.sql` is the upstream source processed exactly as its Makefile does for PostgreSQL ≥ 10, installed with plain `psql -f` into schema `tap` of the test database. Every file declares an explicit plan; the runner also fails if a plan and the executed count differ.
* Statements under test run as the **real application roles** (`SET LOCAL ROLE ledgerx_runtime` + `lx.set_context`) via helper functions in `database/tests/helpers`; assertions run as the administrator because pgTAP needs temp tables, which the application roles must not have.
* `SET CONSTRAINTS ALL IMMEDIATE` is used to force the deferred balance trigger inside rolled-back tests; the same behaviour is *also* tested with real COMMITs in the multi-session suite.
* A Phase-1 test that cannot be done faithfully in a rolled-back superuser session (`SET ROLE`, which is checked against the *session* user; `TRUNCATE`, blocked by pending trigger events) was moved to the multi-session suite instead of being faked.
* **Mutation checks** (performed manually while developing): opening `journal_lines`/`journal_entries` policies with `USING (true)` made tests fail in the tenant, family and equivalence suites; dropping the deferred balance trigger failed 4 multi-session assertions. The equivalence test contains its own negative control (a leaky policy must change the fingerprint).
* Test results are only claimed where produced by these scripts on PostgreSQL 17.5 (native build) with psql 16.15 as the client. `docker-compose.yml` was **not executed** in the author's environment.
