#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/setup.sh"
"$ROOT_DIR/scripts/test-schema.sh"
"$ROOT_DIR/scripts/test-financial.sh"
"$ROOT_DIR/scripts/test-integrity.sh"
"$ROOT_DIR/scripts/test-settlement.sh"
"$ROOT_DIR/scripts/test-reports.sh"
"$ROOT_DIR/scripts/test-concurrency.sh"
"$ROOT_DIR/scripts/test-migration-checksum.sh"
