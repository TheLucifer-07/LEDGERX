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
docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
  psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
  < "$ROOT_DIR/tests/concurrency/prepare.sql"

run_tag="$(date +%s)-$$"
run_scope="concurrency-$run_tag"
temp_dir="$(mktemp -d)"
cleanup() {
  for file in "$temp_dir"/*; do
    [[ -e "$file" ]] && unlink "$file"
  done
  rmdir "$temp_dir"
}
trap cleanup EXIT

psql_file() {
  local app_name="$1"
  local input_file="$2"
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T \
    -e "PGAPPNAME=$app_name" db \
    psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" \
      -d "${POSTGRES_DB:-ledgerx}" -v "run_scope=$run_scope" <"$input_file"
}

wait_for_query() {
  local app_name="$1"
  local expected_query="$2"
  local attempt count
  for attempt in {1..50}; do
    count="$(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
      psql -X -At -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
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
    count="$(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
      psql -X -At -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
      -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$app_name' AND wait_event_type = 'Lock'" \
      2>/dev/null | tr -d '\r')"
    if [[ "$count" == "1" ]]; then
      local wait_event
      wait_event="$(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
        psql -X -At -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
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
  local b_should_fail="$6" status_b status_a
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
  wait_for_lock "$app_b"

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
  if [[ "$b_should_fail" == yes && $status_b -eq 0 ]]; then
    cat "$temp_dir/$label-b.log" >&2
    printf 'Session B should have been rejected for %s.\n' "$label" >&2
    return 1
  fi
  if [[ "$b_should_fail" == no && $status_b -ne 0 ]]; then
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
wait_for_lock "ledgerx-withdraw-b-$run_tag"
set +e
wait "$withdraw_a_pid"; withdraw_a_status=$?
wait "$withdraw_b_pid"; withdraw_b_status=$?
set -e
if (( withdraw_a_status != 0 || withdraw_b_status == 0 )); then
  cat "$temp_dir/withdraw-a.log" "$temp_dir/withdraw-b.log" >&2
  printf 'Expected exactly one successful concurrent withdrawal.\n' >&2
  exit 1
fi
success_count="$(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
  psql -X -At -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
  -c "SELECT count(*) FROM ledger.idempotency_keys WHERE scope = '$run_scope' AND idempotency_key IN ('withdraw-a', 'withdraw-b') AND transaction_id IS NOT NULL")"
[[ "$success_count" == 1 ]] || { printf 'Expected one withdrawal result, got %s.\n' "$success_count" >&2; exit 1; }
printf 'Simultaneous withdrawals: one succeeded and one was rejected for insufficient funds.\n'

run_expected_contention "reverse-transfer" "ledgerx-transfer-a-$run_tag" \
  "ledgerx-transfer-b-$run_tag" transfer_a.sql transfer_b.sql no

run_expected_contention "same-key" "ledgerx-idempotency-a-$run_tag" \
  "ledgerx-idempotency-b-$run_tag" idempotency_a.sql idempotency_b.sql no
same_key_count="$(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
  psql -X -At -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
  -c "SELECT count(*) FROM ledger.transactions AS t JOIN ledger.idempotency_keys AS ik USING (transaction_id) WHERE ik.scope = '$run_scope' AND ik.idempotency_key = 'same-key-transfer' AND t.request_reference = 'concurrent-same-key'")"
[[ "$same_key_count" == 1 ]] || { printf 'Same-key requests created %s transactions.\n' "$same_key_count" >&2; exit 1; }

psql_file "ledgerx-withdraw-restore-$run_tag" \
  "$ROOT_DIR/tests/concurrency/restore_withdrawal.sql" \
  >"$temp_dir/withdraw-restore.log" 2>&1
psql_file "ledgerx-create-capture-$run_tag" \
  "$ROOT_DIR/tests/concurrency/create_capture.sql" \
  >"$temp_dir/create-capture.log" 2>&1

run_expected_contention "refund-cap" "ledgerx-refund-a-$run_tag" \
  "ledgerx-refund-b-$run_tag" refund_a.sql refund_b.sql yes
refund_total="$(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
  psql -X -At -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
  -c "SELECT COALESCE(sum(r.amount), 0) FROM ledger.refunds AS r WHERE r.original_transaction_id = (SELECT transaction_id FROM ledger.idempotency_keys WHERE scope = '$run_scope' AND idempotency_key = 'capture-100')")"
[[ "$refund_total" == 70.0000 ]] || { printf 'Competing refund total expected 70.0000, got %s.\n' "$refund_total" >&2; exit 1; }

psql_file "ledgerx-restore-$run_tag" "$ROOT_DIR/tests/concurrency/restore.sql" \
  >"$temp_dir/restore.log" 2>&1

final_balances="$(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T db \
  psql -X -At -U "$POSTGRES_USER" -d "${POSTGRES_DB:-ledgerx}" \
  -c "SELECT string_agg(a.account_code || '=' || b.posted_balance::text, ',' ORDER BY a.account_code) FROM ledger.accounts AS a JOIN ledger.account_balances AS b USING (account_id) WHERE a.account_code IN ('WALLET-1001-USD', 'WALLET-1002-USD', 'WALLET-1003-USD', 'MERCHANT-2001-USD')")"
if [[ "$final_balances" != "MERCHANT-2001-USD=0.0000,WALLET-1001-USD=100.0000,WALLET-1002-USD=100.0000,WALLET-1003-USD=100.0000" ]]; then
  printf 'Concurrency fixture balances were not restored: %s\n' "$final_balances" >&2
  exit 1
fi
printf 'All concurrency scenarios passed; fixture balances restored.\n'
