#!/usr/bin/env bash
# Concurrency + committed-transaction tests (real sessions). Raw output -> docs/evidence/multisession-tests.txt
. "$(dirname "$0")/lib.sh"
set -o pipefail
bash "$ROOT/database/tests/multisession/run.sh" 2>&1 | tee "$ROOT/docs/evidence/multisession-tests.txt"
