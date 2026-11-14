# Proposed Design Decisions and Open Questions

**Status: settled implementation baseline.** The execution brief resolves the choices below. Any later change must be reflected in the tests and docs.

| Topic | Proposed decision | Alternatives | Failure prevented / evidence needed | Interview explanation |
|---|---|---|---|---|
| Journal balance | Deferred constraint trigger validates count, currency, debit=credit at commit; controlled posting functions and restricted DML | App-only validation; ordinary CHECK | App-only validation can be bypassed; CHECK cannot aggregate rows. Test direct invalid DML, state transition, and rollback. | “The invariant spans rows, so a deferred database constraint validates the final journal at commit.” |
| Ledger history | Posted lines immutable; corrections are linked compensating journals | Edit/delete old rows | Prevents audit loss and balance drift. Test mutation rejection and exact reversal. | “The ledger records what happened; correction is another event.” |
| Balance reads | Transactional normalized balance projection, debit-normal = debits − credits and credit-normal = credits − debits; rebuildable from ledger | SUM entire ledger each request | Avoids growing scan cost while preserving ledger authority. Auditor compares projection; owner-only procedure rebuilds it after a clean ledger scan. | “The projection speeds authorization; the journal remains canonical and lets us rebuild it.” |
| Isolation and locks | READ COMMITTED; lock touched account rows in sorted ID order; fresh subsequent balance query | SERIALIZABLE everywhere; unordered locks | Prevents lost spending decisions and reduces deadlocks. Test simultaneous competing withdrawals/transfers with sessions. | “Explicit row locks serialize changes to the same money; consistent order reduces cycles.” |
| Idempotency | Unique scope/key and canonical payload digest; same payload returns original result, mismatch errors | In-memory cache; transaction ref only | Unique index arbitrates concurrent calls and survives process restarts. Test same-key races and mismatched payload. | “Idempotency is persisted with the transaction and enforced by a unique constraint.” |
| Refund cap | Lock original capture and sum posted refunds before inserting new refund | Check constraint on refund row | Aggregate cap is cross-row; lock serializes competing partial refunds. Test concurrent refunds near the cap. | “The parent lock makes the read-check-write cap operation one serialized unit.” |
| Currency | Single currency per journal/account; currency FK and trigger consistency checks | Numeric-only amounts; implicit conversion | Prevents accidental comparison/addition across currencies. Test mismatched line/account/journal. | “Amount has meaning only together with currency; FX is a separate explicit workflow.” |
| External reconciliation | Keep external statement lines separate; immutable import evidence and versioned result runs | Import external items into ledger | Avoids confusing reported settlement with booked money. Test missing sides, mismatch, repeat run. | “Reconciliation compares two sources of truth; it does not mutate either silently.” |
| Failure analytics | Rejected operations raise and roll back; no durable failure rows in V1 | Autonomous failure log or separate telemetry transaction | Avoids a misleading failed row that disappears on rollback and keeps scope focused. | “A rejected financial transaction leaves no financial record; external telemetry is a separate future concern.” |
| Numeric scale | NUMERIC(20,4), currency `minor_unit`; validate unconstrained input before typmod write | Per-currency typmod columns | Prevents both binary error and silent rounding at column assignment. Test excess scale before insert. | “Exact storage is not enough; the original scale must be checked before coercion.” |
| Scope of refunds | Refund posted capture operations (wallet-to-merchant) only | Refund any deposit/transfer | Gives refunds a precise original allocation and cap. | “A refund reverses a payment allocation with a clear counterparty.” |
| Settlement amount policy | Gross capture/refund amounts; no fees, taxes, or FX in V1 | Net settlement with fee accounting | Prevents hidden fee assumptions and like-for-unlike comparison. | “The settlement basis is explicit and consistent on both sides.” |
| Settlement cardinality | One internal capture/refund to at most one external statement item and vice versa; unique constraints enforce both sides | Many-to-one batch totals | Avoids ambiguous split/aggregation matching in V1. Test duplicate links/imports. | “One-to-one matching makes each exception attributable; aggregation can be a later feature.” |
| Reversal after refund | Prohibit full reversal when any posted refund exists | Net reversal amount after prior refunds | Avoids double-compensation ambiguity. Test rejected reversal and unchanged balances. | “A capture's compensation path is exclusive: refund or full reversal.” |
| Migrations | Numbered SQL migrations with a stored SHA-256 checksum, applied atomically with their history row | Ad hoc rerunnable scripts | Detects modified history and prevents partial migration application. Test clean setup, repeat setup, changed checksum rejection. | “The migration ledger records both order and exact applied file content.” |
| Runtime security | Separate owner/migration and runtime roles; runtime writes only through approved fixed-search-path SECURITY DEFINER functions | Grant table DML to runtime | Limits accidental or unauthorized financial mutation. Test positive and negative grants. | “Privilege boundaries are enforced in PostgreSQL, not only documented.” |

## Settled V1 decisions

1. Capture is a wallet-to-merchant operation; refunds are only for posted captures.
2. Any posted refund prohibits full reversal of that capture.
3. Storage is `NUMERIC(20,4)`; currency precision is checked before typmod assignment.
4. Settlement uses gross capture/refund amounts, one-to-one matching, and no fees/taxes/FX.
5. Rejected requests raise and roll back; durable failed-request analytics are out of scope.
6. System accounts share `accounts` with nullable customer ownership and an explicit account kind/normal side.
7. Migrations are versioned and checksum-verified; CI applies from a clean PostgreSQL 17 service.

## Required implementation evidence

For each choice, preserve SQL assertions and scripts that demonstrate the stated invariant. Benchmark claims need measured output. No test or performance result is asserted until actually observed.
