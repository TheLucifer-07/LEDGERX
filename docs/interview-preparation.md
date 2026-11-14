# Interview Preparation

## Explain the ledger in one minute

“Each operation is a single-currency journal with positive debit or credit lines. A deferred constraint trigger checks that the final journal has at least two lines and balances at commit. Posted lines cannot be edited. Wallet balances are credit-normal liabilities; an indexed projection is updated in the posting transaction and can be checked or rebuilt from the journal.”

## Likely follow-ups

**Why not balance with a `CHECK`?** A `CHECK` sees the row being written, not an aggregate over sibling journal lines. The deferred constraint trigger checks the final multi-row state at transaction end.

**How do you prevent two withdrawals from spending the same funds?** Both lock the wallet row. After the lock is acquired, a subsequent READ COMMITTED statement reads the current projection. The first commits; the second then sees the reduced balance and fails if funds are insufficient.

**How are deadlocks reduced?** Every operation locks all affected account IDs in ascending order. This establishes a shared order for overlapping transfers. A production caller should retry bounded deadlock failures; the test demonstrates reversed transfers complete.

**How does idempotency survive concurrency?** A unique `(scope, idempotency_key)` index chooses one owner. A concurrent insert waits; after the winner commits, the second request compares the canonical payload digest and returns the original transaction if equal.

**How are refunds bounded?** The original capture is locked before summing its posted refunds. That serializes competing partial refunds. A different payload with an existing key is rejected, and cumulative refunds cannot exceed the capture.

**What does reconciliation change?** It stores imported external evidence and a versioned comparison result. It never posts or edits an internal ledger transaction.

## State evidence precisely

The committed local test run passed schema, financial, auditor/rebuild, settlement, reporting, concurrency, and migration checksum suites against PostgreSQL 17.12. Concurrent tests observed lock waits and demonstrated the outcomes above. The benchmark report is local to its recorded container and machine. State those conditions rather than generalizing them to production workloads.

## Design trade-offs to discuss

- `READ COMMITTED` plus explicit row locks keeps this workflow understandable; broader predicate invariants may need `SERIALIZABLE` and retries.
- A maintained balance projection makes authorization checks bounded, at the cost of a second representation that must be audited and rebuildable.
- One-to-one gross settlement matching is straightforward to explain, but does not model split payouts, fees, taxes, FX, or many-to-one settlement.
- The runtime role is intentionally narrow, but local Compose still uses an administrative bootstrap credential.

## Practice prompts

1. Draw the deposits and withdrawals as T-accounts.
2. Explain the difference between transaction atomicity and journal balance.
3. Describe what happens if a deferred trigger fails after the PL/pgSQL function returns.
4. Explain the unique-index wait in a same-key race.
5. Describe how an auditor can distinguish an incorrect projection from an incorrect source journal.
