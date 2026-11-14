# Migration 0007: Settlement and Reconciliation

- **Purpose:** import external statement evidence, match it one-to-one to posted captures/refunds, preserve reconciliation runs, classify exceptions, and close complete batches.
- **Dependencies:** migrations 0001–0006 and reference currencies. Function execution requires the runtime role.
- **Concepts:** immutable evidence, idempotent unique-reference imports, row locking for batch lifecycle, one-to-one uniqueness, versioned snapshots, and exact gross comparisons.
- **Important statements:** batch/item imports validate metadata and amount scale before typmod assignment. Reconciliation matches a statement's internal reference to a transaction reference, stores an immutable match, and writes a separate versioned result for every matched or unmatched side. Amount, currency, and transaction-type mismatches remain explicit results.
- **Why this approach:** an external statement is evidence, not an instruction to change internal balances. Unique keys prevent duplicate imports and one-to-one matches. Reconciliation runs preserve the result of each review.
- **Alternatives:** merge statement lines into the journal or aggregate many internal transactions into one external line. V1 keeps sources separate and uses one-to-one matching so exception ownership is clear.
- **Failure cases:** mismatched import payloads, invalid state transitions, duplicate match attempts, and premature close raise errors. A settled transaction cannot be fully reversed.
- **Execute:** create a batch, import rows, complete import, reconcile, and optionally close in one or more caller-owned transactions.
- **Verify:** run `scripts/test-settlement.sh`; inspect results by `reconciliation_run_id` and confirm a batch with exceptions cannot close.
- **Interview questions:** Why are settlement rows not posted to the ledger? How does a versioned run differ from overwriting the previous result? Which unique constraints implement one-to-one matching?
