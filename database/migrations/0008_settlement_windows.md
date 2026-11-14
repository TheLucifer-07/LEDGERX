# Migration 0008: Settlement Windows

- **Purpose:** make the eligible internal transaction set explicit for each batch.
- **Dependencies:** migration 0007 and its statement batches.
- **Concepts:** half-open timestamp windows, safe schema evolution, function signature changes, and deterministic reconciliation scope.
- **Important statements:** each batch stores `window_start` inclusive and `window_end` exclusive. Existing batches backfill to the full UTC statement date. Reconciliation reports unmatched captures/refunds only within that window and currency; external rows can still explicitly match their referenced transaction.
- **Why this approach:** a statement date alone makes two batches on the same date indistinguishable and causes unrelated same-day transactions to appear as exceptions. An explicit interval defines eligibility and supports repeatable same-day processing.
- **Alternatives:** use `posted_at::date <= statement_date`; this accumulates all old transactions into every later batch. V1 uses `[window_start, window_end)`.
- **Failure cases:** NULL or reversed windows are rejected; batch window metadata is immutable after creation.
- **Execute:** create batches with explicit timezone-aware window bounds; rerun reconciliation to generate a new snapshot.
- **Verify:** `scripts/test-settlement.sh` includes previously committed same-day transactions and verifies they are not treated as candidates outside the test window.
- **Interview questions:** Why use a half-open interval? How does a batch's time window define its expected population? Why does the external reference still permit matching a row across a currency mismatch?
