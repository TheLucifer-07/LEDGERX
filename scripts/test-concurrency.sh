#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$ROOT_DIR/.env" ]]; then
  printf 'Missing .env. Run scripts/setup.sh first.\n' >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "$ROOT_DIR/.env"
set +a

"$ROOT_DIR/scripts/setup.sh"

db_psql() {
  local app_name="$1"
  shift
  if [[ -n "${LEDGERX_DATABASE_URL:-}" ]]; then
    PGAPPNAME="$app_name" PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}" \
      psql -X -v ON_ERROR_STOP=1 "$LEDGERX_DATABASE_URL" "$@"
  else
    docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T \
      -e "PGAPPNAME=$app_name" db \
      psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" \
        -d "${POSTGRES_DB:-ledgerx}" "$@"
  fi
}

db_psql "ledgerx-prepare" -f /dev/stdin \
  < "$ROOT_DIR/tests/concurrency/prepare.sql"

run_tag="$(date +%s)-$$"
run_scope="concurrency-$run_tag"
temp_dir="$(mktemp -d)"
cleanup_enabled=yes
cleanup() {
  local result=$?
  local cleanup_status=0
  trap - EXIT
  if [[ "$cleanup_enabled" == yes ]]; then
    set +e
    psql_file "ledgerx-cleanup-withdraw-$run_tag" \
      "$ROOT_DIR/tests/concurrency/restore_withdrawal.sql" \
      >"$temp_dir/cleanup-withdrawal.log" 2>&1
    if (( $? != 0 )); then
      cleanup_status=1
      cat "$temp_dir/cleanup-withdrawal.log" >&2
    fi
    psql_file "ledgerx-cleanup-restore-$run_tag" \
      "$ROOT_DIR/tests/concurrency/restore.sql" \
      >"$temp_dir/cleanup-restore.log" 2>&1
    if (( $? != 0 )); then
      cleanup_status=1
      cat "$temp_dir/cleanup-restore.log" >&2
    fi
    set -e
  fi
  for file in "$temp_dir"/*; do
    [[ -e "$file" ]] && unlink "$file"
  done
  rmdir "$temp_dir"
  if (( result == 0 && cleanup_status != 0 )); then
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT

psql_file() {
  local app_name="$1"
  local input_file="$2"
  db_psql "$app_name" -v VERBOSITY=verbose -v "run_scope=$run_scope" \
    -f /dev/stdin <"$input_file"
}

wait_for_query() {
  local app_name="$1"
  local expected_query="$2"
  local attempt count
  for attempt in {1..50}; do
    count="$(db_psql "ledgerx-observer" -At \
      -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$app_name' AND state = 'active' AND query LIKE '$expected_query'" \
      2>/dev/null | tr -d '\r')"
    if [[ "$count" == "1" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_lock() {
  local app_name="$1"
  local attempt count
  for attempt in {1..50}; do
    count="$(db_psql "ledgerx-observer" -At \
      -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$app_name' AND wait_event_type = 'Lock'" \
      2>/dev/null | tr -d '\r')"
    if [[ "$count" == "1" ]]; then
      local wait_event
      wait_event="$(db_psql "ledgerx-observer" -At \
        -c "SELECT wait_event_type || '/' || wait_event FROM pg_stat_activity WHERE application_name = '$app_name' AND wait_event_type = 'Lock' LIMIT 1" \
        2>/dev/null | tr -d '\r')"
      printf 'Observed PostgreSQL lock wait for %s: %s.\n' "$app_name" "$wait_event"
      return 0
    fi
    sleep 0.1
  done
  printf 'Expected lock wait was not observed for %s.\n' "$app_name" >&2
  return 1
}

run_expected_contention() {
  local label="$1" app_a="$2" app_b="$3" file_a="$4" file_b="$5"
  local b_should_fail="$6" expected_sqlstate="${7:-}" expected_message="${8:-}"
  local status_b status_a
  psql_file "$app_a" "$ROOT_DIR/tests/concurrency/$file_a" \
    >"$temp_dir/$label-a.log" 2>&1 &
  local pid_a=$!
  if ! wait_for_query "$app_a" 'SELECT pg_sleep%'; then
    wait "$pid_a" || true
    cat "$temp_dir/$label-a.log" >&2
    printf 'Session A did not reach its lock-holding sleep for %s.\n' "$label" >&2
    return 1
  fi

  set +e
  psql_file "$app_b" "$ROOT_DIR/tests/concurrency/$file_b" \
    >"$temp_dir/$label-b.log" 2>&1 &
  local pid_b=$!
  set -e
  if ! wait_for_lock "$app_b"; then
    cat "$temp_dir/$label-a.log" "$temp_dir/$label-b.log" >&2
    wait "$pid_a" || true
    wait "$pid_b" || true
    return 1
  fi

  set +e
  wait "$pid_a"
  status_a=$?
  wait "$pid_b"
  status_b=$?
  set -e
  if (( status_a != 0 )); then
    cat "$temp_dir/$label-a.log" >&2
    printf 'Session A failed for %s.\n' "$label" >&2
    return 1
  fi
  if [[ "$b_should_fail" == yes ]]; then
    if (( status_b == 0 )) || [[ -z "$expected_sqlstate" || -z "$expected_message" ]] \
       || ! grep -Eq "ERROR:[[:space:]]+$expected_sqlstate:" "$temp_dir/$label-b.log" \
       || ! grep -Fq "$expected_message" "$temp_dir/$label-b.log"; then
      cat "$temp_dir/$label-b.log" >&2
      printf 'Session B did not fail for the expected reason in %s.\n' "$label" >&2
      return 1
    fi
  elif (( status_b != 0 )); then
    cat "$temp_dir/$label-b.log" >&2
    printf 'Session B failed unexpectedly for %s.\n' "$label" >&2
    return 1
  fi
  printf 'Concurrent scenario %s completed (session A status %s, session B status %s).\n' \
    "$label" "$status_a" "$status_b"
}

psql_file "ledgerx-setup-$run_tag" "$ROOT_DIR/tests/concurrency/withdraw_a.sql" \
  >"$temp_dir/withdraw-a.log" 2>&1 &
withdraw_a_pid=$!
if ! wait_for_query "ledgerx-setup-$run_tag" 'SELECT pg_sleep%'; then
  wait "$withdraw_a_pid" || true
  cat "$temp_dir/withdraw-a.log" >&2
  printf 'Withdrawal session A did not reach its sleep.\n' >&2
  exit 1
fi
set +e
psql_file "ledgerx-withdraw-b-$run_tag" "$ROOT_DIR/tests/concurrency/withdraw_b.sql" \
  >"$temp_dir/withdraw-b.log" 2>&1 &
withdraw_b_pid=$!
set -e
if ! wait_for_lock "ledgerx-withdraw-b-$run_tag"; then
  wait "$withdraw_a_pid" || true
  wait "$withdraw_b_pid" || true
  cat "$temp_dir/withdraw-a.log" "$temp_dir/withdraw-b.log" >&2
  exit 1
fi
set +e
wait "$withdraw_a_pid"; withdraw_a_status=$?
wait "$withdraw_b_pid"; withdraw_b_status=$?
set -e
if (( withdraw_a_status != 0 || withdraw_b_status == 0 )) \
   || ! grep -Eq 'ERROR:[[:space:]]+23514:' "$temp_dir/withdraw-b.log" \
   || ! grep -Fq 'insufficient available balance' "$temp_dir/withdraw-b.log"; then
  cat "$temp_dir/withdraw-a.log" "$temp_dir/withdraw-b.log" >&2
  printf 'Withdrawal loser did not fail with the expected insufficient-balance error.\n' >&2
  exit 1
fi
withdrawal_evidence="$(db_psql "ledgerx-observer" -At \
  -c "SELECT
        (SELECT count(*) FROM ledger.idempotency_keys WHERE scope = '$run_scope' AND idempotency_key = 'withdraw-a' AND transaction_id IS NOT NULL) || ',' ||
        (SELECT count(*) FROM ledger.idempotency_keys WHERE scope = '$run_scope' AND idempotency_key = 'withdraw-b') || ',' ||
        (SELECT count(*) FROM ledger.transactions t JOIN ledger.idempotency_keys ik USING (transaction_id) WHERE ik.scope = '$run_scope' AND ik.idempotency_key = 'withdraw-a' AND t.status = 'posted' AND t.transaction_type = 'withdrawal' AND t.amount = 75.00) || ',' ||
        (SELECT count(*) FROM ledger.ledger_entries le JOIN ledger.idempotency_keys ik ON ik.transaction_id = le.transaction_id WHERE ik.scope = '$run_scope' AND ik.idempotency_key = 'withdraw-a') || ',' ||
        (SELECT b.posted_balance FROM ledger.account_balances b JOIN ledger.accounts a USING (account_id) WHERE a.account_code = 'WALLET-1003-USD')")"
[[ "$withdrawal_evidence" == "1,0,1,2,25.0000" ]] || {
  printf 'Withdrawal race evidence was invalid: %s\n' "$withdrawal_evidence" >&2; exit 1;
}
printf 'Simultaneous withdrawals: one succeeded and one was rejected for insufficient funds.\n'

run_expected_contention "reverse-transfer" "ledgerx-transfer-a-$run_tag" \
  "ledgerx-transfer-b-$run_tag" transfer_a.sql transfer_b.sql no
transfer_evidence="$(db_psql "ledgerx-observer" -At \
  -c "SELECT (SELECT count(*) FROM ledger.transactions t JOIN ledger.idempotency_keys ik USING (transaction_id) WHERE ik.scope = '$run_scope' AND ik.idempotency_key IN ('reverse-a-to-b','reverse-b-to-a') AND t.transaction_type='transfer' AND t.status='posted' AND t.amount=80.00) || ',' || (SELECT count(*) FROM ledger.ledger_entries le JOIN ledger.idempotency_keys ik ON ik.transaction_id=le.transaction_id WHERE ik.scope='$run_scope' AND ik.idempotency_key IN ('reverse-a-to-b','reverse-b-to-a')) || ',' || (SELECT string_agg(a.account_code || '=' || b.posted_balance::text, ',' ORDER BY a.account_code) FROM ledger.accounts a JOIN ledger.account_balances b USING(account_id) WHERE a.account_code IN ('WALLET-1001-USD','WALLET-1002-USD'))")"
[[ "$transfer_evidence" == "2,4,WALLET-1001-USD=100.0000,WALLET-1002-USD=100.0000" ]] || {
  printf 'Reverse-transfer ledger/balance evidence was invalid: %s\n' "$transfer_evidence" >&2; exit 1;
}

run_expected_contention "same-key" "ledgerx-idempotency-a-$run_tag" \
  "ledgerx-idempotency-b-$run_tag" idempotency_a.sql idempotency_b.sql no
same_key_count="$(db_psql "ledgerx-observer" -At \
  -c "SELECT count(*) FROM ledger.transactions AS t JOIN ledger.idempotency_keys AS ik USING (transaction_id) WHERE ik.scope = '$run_scope' AND ik.idempotency_key = 'same-key-transfer' AND t.request_reference = 'concurrent-same-key'")"
[[ "$same_key_count" == 1 ]] || { printf 'Same-key requests created %s transactions.\n' "$same_key_count" >&2; exit 1; }
same_key_evidence="$(db_psql "ledgerx-observer" -At \
  -c "SELECT count(DISTINCT ik.transaction_id) || ',' || count(DISTINCT le.ledger_entry_id) || ',' || (SELECT string_agg(a.account_code || '=' || b.posted_balance::text, ',' ORDER BY a.account_code) FROM ledger.accounts a JOIN ledger.account_balances b USING(account_id) WHERE a.account_code IN ('WALLET-1001-USD','WALLET-1002-USD')) FROM ledger.idempotency_keys ik JOIN ledger.ledger_entries le ON le.transaction_id=ik.transaction_id WHERE ik.scope='$run_scope' AND ik.idempotency_key='same-key-transfer'")"
same_key_transaction_id="$(db_psql "ledgerx-observer" -At \
  -c "SELECT transaction_id FROM ledger.idempotency_keys WHERE scope='$run_scope' AND idempotency_key='same-key-transfer'")"
[[ "$same_key_evidence" == "1,2,WALLET-1001-USD=90.0000,WALLET-1002-USD=110.0000" ]] \
  && grep -Eq "^[[:space:]]+$same_key_transaction_id[[:space:]]*$" "$temp_dir/same-key-a.log" \
  && grep -Eq "^[[:space:]]+$same_key_transaction_id[[:space:]]*$" "$temp_dir/same-key-b.log" || {
  printf 'Same-key ledger evidence was invalid: %s\n' "$same_key_evidence" >&2; exit 1;
}

psql_file "ledgerx-withdraw-restore-$run_tag" \
  "$ROOT_DIR/tests/concurrency/restore_withdrawal.sql" \
  >"$temp_dir/withdraw-restore.log" 2>&1
psql_file "ledgerx-create-capture-$run_tag" \
  "$ROOT_DIR/tests/concurrency/create_capture.sql" \
  >"$temp_dir/create-capture.log" 2>&1

run_expected_contention "refund-cap" "ledgerx-refund-a-$run_tag" \
  "ledgerx-refund-b-$run_tag" refund_a.sql refund_b.sql yes 23514 'refund total'
refund_total="$(db_psql "ledgerx-observer" -At \
  -c "SELECT COALESCE(sum(r.amount) FILTER (WHERE refund_tx.status = 'posted'), 0) FROM ledger.refunds r JOIN ledger.transactions refund_tx ON refund_tx.transaction_id=r.refund_transaction_id WHERE r.original_transaction_id = (SELECT transaction_id FROM ledger.idempotency_keys WHERE scope = '$run_scope' AND idempotency_key = 'capture-100')")"
[[ "$refund_total" == 70.0000 ]] || { printf 'Competing refund total expected 70.0000, got %s.\n' "$refund_total" >&2; exit 1; }
refund_evidence="$(db_psql "ledgerx-observer" -At \
  -c "SELECT (SELECT count(*) FROM ledger.refunds r JOIN ledger.transactions tx ON tx.transaction_id=r.refund_transaction_id WHERE r.original_transaction_id=(SELECT transaction_id FROM ledger.idempotency_keys WHERE scope='$run_scope' AND idempotency_key='capture-100') AND tx.status='posted') || ',' || (SELECT count(*) FROM ledger.idempotency_keys WHERE scope='$run_scope' AND idempotency_key='refund-70' AND transaction_id IS NOT NULL) || ',' || (SELECT count(*) FROM ledger.idempotency_keys WHERE scope='$run_scope' AND idempotency_key='refund-50') || ',' || (SELECT count(*) FROM ledger.ledger_entries le JOIN ledger.idempotency_keys ik ON ik.transaction_id=le.transaction_id WHERE ik.scope='$run_scope' AND ik.idempotency_key='refund-70')")"
[[ "$refund_evidence" == "1,1,0,2" ]] || {
  printf 'Refund-cap ledger evidence was invalid: %s\n' "$refund_evidence" >&2; exit 1;
}

psql_file "ledgerx-restore-$run_tag" "$ROOT_DIR/tests/concurrency/restore.sql" \
  >"$temp_dir/restore.log" 2>&1
cleanup_enabled=no

final_balances="$(db_psql "ledgerx-observer" -At \
  -c "SELECT string_agg(a.account_code || '=' || b.posted_balance::text, ',' ORDER BY a.account_code) FROM ledger.accounts AS a JOIN ledger.account_balances AS b USING (account_id) WHERE a.account_code IN ('WALLET-1001-USD', 'WALLET-1002-USD', 'WALLET-1003-USD', 'MERCHANT-2001-USD')")"
if [[ "$final_balances" != "MERCHANT-2001-USD=0.0000,WALLET-1001-USD=100.0000,WALLET-1002-USD=100.0000,WALLET-1003-USD=100.0000" ]]; then
  printf 'Concurrency fixture balances were not restored: %s\n' "$final_balances" >&2
  exit 1
fi
printf 'All concurrency scenarios passed; fixture balances restored.\n'
