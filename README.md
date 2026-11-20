# LedgerX — a PostgreSQL double-entry ledger with multi-tenant Row-Level Security

> A database-engineering project: the financial rules, security model and reporting layer live **inside PostgreSQL 17**
> (SQL, PL/pgSQL, triggers, RLS). No application server, no ORM — verified by **240 automated assertions**, real concurrent
> sessions, a security audit, and an EXPLAIN-driven performance fix that made the four scan-heavy tenant queries **~70–7,000× faster** on the measured dataset (the two tiny ones 5–9×).

**Status: Phase 1 of 4 complete** — database-only conversion, security hardening, RLS optimisation, test suites.
Phases 2–4 (domain extensions + analytics, concurrency/benchmark deepening + diagrams, final packaging) are listed under [Roadmap](#roadmap).

## The problem
Money software fails in boring, expensive ways: a retried request posts twice, two requests race and lose an update, a "fix" rewrites history,
totals silently mix currencies, one household member can see another's private spending. LedgerX makes those failure modes **impossible or detectable at the database layer**,
so correctness does not depend on every application remembering to do the right thing.

## What it demonstrates
| Area | Implementation | Proof |
|---|---|---|
| **Double-entry integrity** | `NUMERIC(24,6)` money, per-currency balance enforced eagerly *and* by a **deferred constraint trigger** at COMMIT, minor-unit precision per currency, composite FKs tying every line to an account of the same workspace *and* currency | `10_ledger_posting`, multi-session test 5 (real COMMITs) |
| **Immutability & reversals** | triggers block UPDATE/DELETE/TRUNCATE even for the table owner; corrections are reversal entries (one per entry, atomic) | `11_immutability`, `12_reversals…` |
| **Idempotency under races** | request-hash + key claim via `INSERT … ON CONFLICT`; 12 concurrent identical requests ⇒ exactly one entry | multi-session test 1 |
| **Concurrency control** | deterministic lock ordering (no deadlocks in 40 opposing postings), row locks on reversal, shared/exclusive **advisory locks** protecting projection rebuilds while postings run | multi-session tests 2–4 |
| **Multi-tenancy with RLS** | fail-closed policies on every table, transaction-local context validated against membership, private-vs-shared records inside a workspace | `20_tenant_isolation`, `21_family_privacy` |
| **Least privilege** | separate migrator/runtime roles; runtime owns nothing, no BYPASSRLS, no direct writes; `SECURITY DEFINER` API with pinned `search_path`; PUBLIC and TEMP locked down | `30_security_audit`, `make audit` |
| **Query performance** | diagnosed RLS with `EXPLAIN (ANALYZE, BUFFERS)` + `pg_stat_user_functions`, fixed with InitPlans, **proved security-equivalent** | [PERFORMANCE.md](docs/PERFORMANCE.md) |
| **Reproducibility** | numbered checksummed migrations, deterministic seed (identical fingerprint on regeneration), Bash/psql/Make harness, pgTAP vendored | `make test` |

## Measured result: RLS overhead removed (70–7,000× on scan-heavy queries)
Same questions, real `ledgerx_runtime` role, 240,000-line synthetic ledger, median of 5 runs ([full methodology, environment and caveats](docs/PERFORMANCE.md)):

| Query (personal-workspace owner) | Before | After | Speed-up |
|---|--:|--:|--:|
| Workspace totals (aggregate) | 4,050.9 ms | 6.5 ms | 621× |
| Account ledger (join, top 100) | 1,303.6 ms | 13.3 ms | 98× |
| 50 most recent entries | 2,018.2 ms | 0.30 ms | 6,750× |
| Monthly cash-flow view | 2,239.5 ms | 32.5 ms | 69× |

**Root cause (from the evidence, not a guess):** the policy called a `SECURITY DEFINER` function *per row* — **231,432 calls for one query** — which hid the tenant predicate from the planner and forced a sequential scan of every tenant's data.
The fix evaluates the session context once per query; the plan changes to an index scan. A test that compares exactly which rows each of 9 relations exposes to every context under old vs new policies (with a negative control) shows **no change in what anyone can see**.
Caveat: one small VM, warm cache, synthetic data — ratios, not absolutes.

## Quick start
Needs: Bash, `make`, `psql`, and a PostgreSQL **17** server with a superuser. Verified here against PostgreSQL 17.5 with a psql 16.15 client.

```bash
cp .env.example .env        # PGHOST/PGPORT/PGUSER/PGPASSWORD for your admin connection
make test                   # fresh DB -> 10 migrations -> 202 pgTAP assertions -> 38 multi-session assertions
make audit                  # security posture report
make bench-rls              # reproduce the RLS diagnosis + before/after benchmark (several minutes)
```
Docker alternative: `docker compose up -d --wait db && docker compose run --rm tools make test`.
**Note:** the compose file has *not* been executed by the author (no Docker in the build environment); everything else above was.

Try it by hand:
```sql
BEGIN;
SELECT lx.set_context('<user-uuid>', '<workspace-uuid>');           -- trusted caller vouches for identity; DB validates membership
SELECT * FROM lx.post_journal_entry('order-1042', '2026-11-01', 'Groceries',
  '[{"account_id":"<expense>","debit":"800.00"},{"account_id":"<cash>","credit":"800.00"}]');
COMMIT;
SELECT * FROM lx.v_monthly_cashflow;                                -- income/expense per month, per currency
```

## Verification evidence (real output, committed)
```
# LedgerX SQL tests (pgTAP 1.3.4) — PostgreSQL 17.5 …
ok 1 - balanced entry posts … ok 202 - …          # SUMMARY files=7 assertions=202 failed=0
# LedgerX multi-session tests …
ok 1 - exactly one session created the entry       # 12 concurrent sessions, one idempotency key
ok 22 - COMMIT of an unbalanced direct insert is refused (LX422)
                                                   # SUMMARY assertions=38 failed=0
```
Files: [`sql-tests.tap`](docs/evidence/sql-tests.tap) · [`multisession-tests.txt`](docs/evidence/multisession-tests.txt) · [`security-audit.txt`](docs/evidence/security-audit.txt) · [`rls-diagnosis.txt`](docs/evidence/rls-diagnosis.txt) · [`benchmarks/rls-comparison.md`](benchmarks/rls-comparison.md).
Rolled-back SQL tests and real multi-session tests are deliberately **separate** — a rolled-back test cannot prove concurrent behaviour ([TESTING.md](docs/TESTING.md)).

## Database at a glance (schema `lx`)
11 tables + migration log · 3 `security_invoker` views · 30 functions (25 `SECURITY DEFINER`) · 11 triggers · 9 RLS policies · 29 indexes · 22 foreign keys · 26 CHECK constraints · 991 lines of migration SQL.
Entities: users, workspaces (student/personal/family/business/demo), memberships, invitations, accounts (chart of accounts), journal entries/lines, balance projection, idempotency keys, audit events.

## Repository layout
```
database/  bootstrap/ migrations/ (001–010) tests/{helpers,sql,multisession}/ audit/ seeds/
benchmarks/ queries/rls/  before/  after/  rls-comparison.md  dataset.txt
scripts/   Bash harness (migrate, test, audit, seed, benchmark)       Makefile  docker-compose.yml
docs/      ARCHITECTURE  DATABASE_DESIGN  SECURITY  TESTING  PERFORMANCE  evidence/
third_party/pgtap/  vendored pgTAP 1.3.4 (+ license)
```

## Security in one paragraph
PostgreSQL does not authenticate end users here: a trusted caller must vouch for identity via `set_context`, and the database enforces everything *given* that identity.
The audit found and fixed four issues (definer `search_path`, PUBLIC/TEMP privileges, executable internal helpers, per-row RLS cost) and documents the residual risks honestly — see [SECURITY.md](docs/SECURITY.md).

## Roadmap
| Phase | Scope | State |
|---|---|---|
| 1 | Database-only conversion, hardening, RLS optimisation, SQL + concurrency tests | **done** |
| 2 | Categories (recursive CTE roll-ups), budgets, goals, reconciliation, FX, period close, **explicit per-account overdraft policies**, window-function analytics, deterministic personas | planned |
| 3 | Concurrency measurements (hot-row contention — measure before changing anything), pgbench workloads, index/covering/materialised-view experiments, ERD + 5 SVG diagrams | planned |
| 4 | Final verification, polished README, resume bullets, interview prep | planned |

## Limitations
* No diagrams yet (Phase 3) and no domain tables beyond the ledger core (Phase 2). No negative-balance rule exists by design; overdraft policy modelling is Phase 2.
* Benchmarks come from one 1-vCPU VM with synthetic data. `docker-compose.yml` is unexecuted. No compliance or production-readiness claim is made.
* The project was converted from an earlier Node/Next.js prototype; that application layer was removed. Third-party: pgTAP (see its license).
