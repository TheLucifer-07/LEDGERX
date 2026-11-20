#!/usr/bin/env bash
# Multi-session and committed-transaction tests. Unlike database/tests/sql (single session, rolled back),
# every scenario here opens REAL separate connections as ledgerx_runtime and COMMITs real transactions.
# Output is TAP-style; exit status is non-zero if any check fails.
. "$(dirname "$0")/../../../scripts/lib.sh"
require_server
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
n=0; failed=0
ok()  { n=$((n+1)); echo "ok $n - $1"; }
nok() { n=$((n+1)); failed=$((failed+1)); echo "not ok $n - $1"; [ -n "${2:-}" ] && echo "#   $2"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected=[$2] actual=[$3]"; fi; }
count_lines() { cat "$TMP"/out.* 2>/dev/null | grep -c -- "$1" || true; }
par() { local cnt=$1; shift; rm -f "$TMP"/out.*; for i in $(seq 1 "$cnt"); do ( "$@" "$i" > "$TMP/out.$i" 2>&1 || true ) & done; wait; }
admin_val() { admin_psql -qAt -c "$1" | tail -1; }

admin_psql -q -f "$ROOT/database/tests/helpers/helpers.sql" >/dev/null
echo "# LedgerX multi-session tests — $(admin_psql -qAt -c 'SELECT version()')"
echo "# database=$LEDGERX_DB  run=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# committed fixture: one user, one personal workspace, accounts in $CASH $BANK $SAL
new_ws() {
  U=$(admin_val "SELECT t.mk_user('ms')"); WS=$(admin_val "SELECT t.mk_ws('$U')")
  CASH=$(admin_val "SELECT t.acct('$WS','1000')"); BANK=$(admin_val "SELECT t.acct('$WS','1100')"); SAL=$(admin_val "SELECT t.acct('$WS','4000')")
}
rt() { runtime_psql -qAt -v VERBOSITY=sqlstate "$@"; }
post_sql() { # key debit_acct credit_acct amount
  cat <<SQL
BEGIN;
SELECT lx.set_context('$U','$WS');
SELECT 'POSTED|'||entry_id||'|'||replayed FROM lx.post_journal_entry('$1','2026-11-01','multisession',
  jsonb_build_array(jsonb_build_object('account_id','$2','debit','$4'), jsonb_build_object('account_id','$3','credit','$4')));
COMMIT;
SQL
}
integrity() { # prints number of projection mismatches for the fixture workspace
  admin_psql -qAt <<SQL | tail -1
BEGIN; SELECT lx.set_context('$U','$WS'); SELECT count(*) FROM lx.verify_account_balances(); COMMIT;
SQL
}
cash_balance() { admin_val "SELECT balance FROM lx.v_account_balances WHERE account_id='$CASH'"; }

echo "# --- 1. idempotency under a real race (12 concurrent sessions, one key)"
new_ws; KEY="race-key-$(date +%s%N)"
s1() { post_sql "$KEY" "$CASH" "$SAL" 25 | rt; }
par 12 s1
check "exactly one session created the entry" 1 "$(count_lines 'POSTED|.*|f')"
check "eleven sessions received the replay" 11 "$(count_lines 'POSTED|.*|t')"
check "all sessions returned the same entry id" 1 "$(cat "$TMP"/out.* | grep -o 'POSTED|[0-9a-f-]*' | sort -u | wc -l | tr -d ' ')"
check "one idempotency record, one ledger entry" "1|1" "$(admin_val "SELECT (SELECT count(*) FROM lx.idempotency_keys WHERE key='$KEY')||'|'||(SELECT count(*) FROM lx.journal_entries WHERE workspace_id='$WS')")"
check "the amount was applied exactly once" "25.000000" "$(cash_balance)"
check "no session saw an error" 0 "$(count_lines 'ERROR')"

echo "# --- 2. concurrent reversal of one entry (8 sessions, 8 different keys)"
new_ws
E=$(post_sql "seed-entry-$(date +%s%N)" "$CASH" "$SAL" 40 | rt | grep -o 'POSTED|[0-9a-f-]*' | cut -d'|' -f2)
s2() { cat <<SQL | rt
BEGIN; SELECT lx.set_context('$U','$WS');
SELECT 'REVERSED|'||entry_id FROM lx.reverse_journal_entry('$E','rev-key-$1-$(date +%s%N)','race');
COMMIT;
SQL
}
par 8 s2
check "exactly one reversal succeeded" 1 "$(count_lines 'REVERSED|')"
check "the other seven were refused with LX409" 7 "$(count_lines 'LX409')"
check "no other error (e.g. deadlock) occurred" 7 "$(count_lines 'ERROR')"
check "ledger holds the original and a single reversal" 2 "$(admin_val "SELECT count(*) FROM lx.journal_entries WHERE workspace_id='$WS'")"
check "balance is back to zero" "0.000000" "$(cash_balance)"

echo "# --- 3. 40 concurrent postings touching the same two accounts in opposite order"
new_ws
s3() { if [ $(($1 % 2)) -eq 0 ]; then post_sql "opp-$1-$(date +%s%N)" "$CASH" "$BANK" 10 | rt; else post_sql "opp-$1-$(date +%s%N)" "$BANK" "$CASH" 10 | rt; fi; }
par 40 s3
check "all 40 postings committed" 40 "$(count_lines 'POSTED|.*|f')"
check "no deadlock or serialization failure" 0 "$(count_lines 'ERROR')"
check "cash nets to zero (20 debits, 20 credits)" "0.000000" "$(cash_balance)"
check "cash debit total is exactly 200 (no lost update)" "200.000000" "$(admin_val "SELECT debit_total FROM lx.account_balances WHERE account_id='$CASH'")"
check "projection matches the ledger" 0 "$(integrity)"

echo "# --- 4. projection rebuild racing against live postings (30 posters + 5 rebuilds)"
new_ws
s4() { if [ "$1" -le 30 ]; then post_sql "mix-$1-$(date +%s%N)" "$CASH" "$SAL" 10 | rt; else sleep "0.$(( ($1 - 30) * 2 ))"; cat <<SQL | rt
BEGIN; SELECT lx.set_context('$U','$WS'); SELECT 'REBUILT|'||lx.rebuild_account_balances(); COMMIT;
SQL
fi; }
par 35 s4
check "all 30 postings committed" 30 "$(count_lines 'POSTED|.*|f')"
check "all 5 rebuilds completed" 5 "$(count_lines 'REBUILT|')"
check "no errors" 0 "$(count_lines 'ERROR')"
check "projection equals the ledger after the race" 0 "$(integrity)"
check "cash balance is exactly 300" "300.000000" "$(cash_balance)"

echo "# --- 5. committed-transaction behaviour (the owner role, real COMMITs)"
new_ws
BAD=$(admin_val "SELECT gen_random_uuid()"); ONE=$(admin_val "SELECT gen_random_uuid()"); GOOD=$(admin_val "SELECT gen_random_uuid()")
mig() { migrator_psql -qAt -v ON_ERROR_STOP=0 -v VERBOSITY=sqlstate "$@" 2>&1; }
r=$(mig <<SQL
BEGIN;
INSERT INTO lx.journal_entries (id, workspace_id, entry_date, description, created_by) VALUES ('$BAD','$WS','2026-11-01','unbalanced','$U');
INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit, credit) VALUES ('$WS','$BAD',1,'$CASH','INR',10,0),('$WS','$BAD',2,'$SAL','INR',0,9);
COMMIT;
SQL
)
check "COMMIT of an unbalanced direct insert is refused (LX422)" 1 "$(echo "$r" | grep -c 'LX422')"
check "...and nothing was persisted" 0 "$(admin_val "SELECT count(*) FROM lx.journal_entries WHERE id='$BAD'")"
r=$(mig <<SQL
BEGIN;
INSERT INTO lx.journal_entries (id, workspace_id, entry_date, description, created_by) VALUES ('$ONE','$WS','2026-11-01','single line','$U');
INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit, credit) VALUES ('$WS','$ONE',1,'$CASH','INR',10,0);
COMMIT;
SQL
)
check "COMMIT of a single-line entry is refused (LX422)" 1 "$(echo "$r" | grep -c 'LX422')"
r=$(mig <<SQL
BEGIN;
INSERT INTO lx.journal_entries (id, workspace_id, entry_date, description, created_by) VALUES ('$GOOD','$WS','2026-11-01','balanced direct insert','$U');
INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit, credit) VALUES ('$WS','$GOOD',1,'$CASH','INR',10,0),('$WS','$GOOD',2,'$SAL','INR',0,10);
COMMIT;
SQL
)
check "positive control: a balanced direct insert commits" 1 "$(admin_val "SELECT count(*) FROM lx.journal_entries WHERE id='$GOOD'")"
check "...and the balance projection followed" "10.000000" "$(cash_balance)"
r=$(mig <<SQL
INSERT INTO lx.journal_lines (workspace_id, entry_id, line_no, account_id, currency, debit) VALUES ('$WS','$GOOD',9,'$CASH','INR',1);
SQL
)
check "lines cannot be added to an entry committed earlier (LX423)" 1 "$(echo "$r" | grep -c 'LX423')"
check "TRUNCATE of journal_lines is blocked (LX423)" 1 "$(echo "TRUNCATE lx.journal_lines CASCADE;" | mig | grep -c 'LX423')"
check "UPDATE of a committed entry is blocked (LX423)" 1 "$(echo "UPDATE lx.journal_entries SET description='x';" | mig | grep -c 'LX423')"

echo "# --- 6. session hygiene and privilege escalation over a real runtime connection"
new_ws
r=$(cat <<SQL | runtime_psql -qAt -v ON_ERROR_STOP=0 -v VERBOSITY=sqlstate 2>&1
BEGIN; SELECT lx.set_context('$U','$WS'); SELECT 'A|'||count(*) FROM lx.accounts; COMMIT;
SELECT 'B|'||count(*) FROM lx.accounts;
SELECT 'C|'||coalesce(nullif(current_setting('lx.user_id', true), ''), 'empty');
BEGIN; SELECT lx.set_context('$U','$WS'); SELECT 1/0; ROLLBACK;
SELECT 'D|'||count(*) FROM lx.accounts;
SELECT 'E|'||coalesce(nullif(current_setting('lx.workspace_id', true), ''), 'empty');
SQL
)
check "context is active inside its transaction" 1 "$(echo "$r" | grep -c '^A|[1-9]')"
check "after COMMIT the same connection sees no rows (B)" 1 "$(echo "$r" | grep -c '^B|0$')"
check "after COMMIT the user setting is cleared (C)" 1 "$(echo "$r" | grep -c '^C|empty$')"
check "after a failed + rolled-back transaction nothing leaks (D, E)" 2 "$(echo "$r" | grep -c -E '^(D\|0|E\|empty)$')"
r=$(cat <<'SQL' | runtime_psql -qAt -v ON_ERROR_STOP=0 -v VERBOSITY=sqlstate 2>&1
SET ROLE ledgerx_migrator;
SET ROLE postgres;
SET session_replication_role = replica;
CREATE TEMP TABLE x (i int);
CREATE TABLE public.x (i int);
SELECT 'whoami|'||current_user||'|'||(SELECT rolbypassrls::text FROM pg_roles WHERE rolname = current_user);
SQL
)
check "real login: SET ROLE / replica mode / temp / public DDL are all refused (42501)" 5 "$(echo "$r" | grep -c '42501')"
check "real login: connected as ledgerx_runtime without BYPASSRLS" 1 "$(echo "$r" | grep -c 'whoami|ledgerx_runtime|false')"

echo "# --- 7. migrations: repeatable, concurrent-safe, checksum-protected"
r=$("$ROOT/scripts/migrate.sh" 2>&1); check "a repeat run applies nothing" 1 "$(echo "$r" | grep -c 'applied=0')"
for i in 1 2 3; do ( "$ROOT/scripts/migrate.sh" > "$TMP/out.$i" 2>&1 || true ) & done; wait
check "three concurrent runs all apply nothing" 3 "$(count_lines 'applied=0')"
cp -r "$ROOT/database/migrations" "$TMP/mig"; echo "-- edited" >> "$TMP/mig/001_schema.sql"
r=$(MIGRATIONS_DIR="$TMP/mig" "$ROOT/scripts/migrate.sh" 2>&1 || true)
check "an edited, already-applied migration is rejected" 1 "$(echo "$r" | grep -c 'checksum mismatch')"

echo "# SUMMARY assertions=$n failed=$failed"
[ "$failed" -eq 0 ]
