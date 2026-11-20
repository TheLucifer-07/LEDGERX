# LedgerX — PostgreSQL 17 database engineering project.  `make help` lists targets.
# Requires: bash, psql (client 17 recommended), a reachable PostgreSQL 17 server with a superuser.
# Connection settings come from .env (see .env.example) or the PG* environment variables.
SHELL := /bin/bash
export LEDGERX_DB ?= ledgerx

.PHONY: help up down db-reset migrate test test-sql test-multisession audit seed-bench bench-rls-before bench-rls-after bench-rls clean

help:           ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | column -t -s $$'\t'

up:             ## start PostgreSQL 17 in Docker (docker-compose.yml)
	docker compose up -d --wait db

down:           ## stop and remove the Docker database (and its volume)
	docker compose down -v

db-reset:       ## DROP and recreate LEDGERX_DB, bootstrap roles, apply all migrations
	./scripts/db-reset.sh

migrate:        ## apply pending migrations
	./scripts/migrate.sh

test:           ## full verification: fresh database + SQL tests (pgTAP) + multi-session tests
	LEDGERX_DB=ledgerx_test ./scripts/db-reset.sh
	LEDGERX_DB=ledgerx_test ./scripts/test-sql.sh
	LEDGERX_DB=ledgerx_test ./scripts/test-multisession.sh

test-sql:       ## ordinary SQL correctness tests only (single-session, rolled back)
	./scripts/test-sql.sh

test-multisession: ## concurrency + committed-transaction tests only (real parallel sessions)
	./scripts/test-multisession.sh

audit:          ## print the security posture report
	./scripts/audit.sh

seed-bench:     ## load the deterministic benchmark dataset (12 workspaces x 10,000 entries)
	./scripts/seed-bench.sh 12 10000

bench-rls-before: ## RLS benchmark step 1: schema up to 009, seed, diagnose, measure BEFORE
	LEDGERX_DB=ledgerx_bench MIGRATE_TO=009 ./scripts/db-reset.sh
	LEDGERX_DB=ledgerx_bench ./scripts/seed-bench.sh 12 10000
	LEDGERX_DB=ledgerx_bench ./scripts/diagnose-rls.sh >/dev/null
	LEDGERX_DB=ledgerx_bench ./scripts/bench-rls.sh before 5

bench-rls-after: ## RLS benchmark step 2: apply 010 (RLS optimisation), measure AFTER, write comparison
	LEDGERX_DB=ledgerx_bench ./scripts/migrate.sh
	LEDGERX_DB=ledgerx_bench ./scripts/bench-rls.sh after 5
	./scripts/bench-compare.sh before after

bench-rls: bench-rls-before bench-rls-after ## both steps (several minutes)

clean:          ## remove generated benchmark output (keeps committed evidence)
	rm -rf benchmarks/before benchmarks/after benchmarks/.tmp
