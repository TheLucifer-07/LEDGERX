# Proposed Technical Risks and Attention Areas

| Risk | Why it matters | Proposed mitigation / review point |
|---|---|---|
| Cross-row journal invariant | CHECK constraints cannot aggregate sibling lines; direct writers could produce unbalanced postings. | Deferred constraint trigger plus final-state checks, protected posting functions, restricted DML, and tests for each mutation path. |
| Trigger concurrency race | Deferred checks can be undermined by an unrestricted multi-writer path that changes the same journal concurrently. | Make transaction-header posting the serialization point; lock header; revoke direct DML; test concurrent attempts and document trigger protocol. |
| Projection diverges from journal | Balance cache drift can authorize an invalid withdrawal. | Update it in the same transaction, only through controlled functions/triggers; add rebuild/parity query and assertions. Ledger stays authoritative. |
| Lock-order mistakes | Transfers involving overlapping account sets can deadlock. | Lock all account IDs in ascending order; test two-session reverse-direction transfers; bounded retry for deadlock SQLSTATE. |
| Stale balance read after lock wait | A transaction may acquire a lock after another commits but still use an earlier statement snapshot. | Under READ COMMITTED, acquire lock then read balance in a subsequent statement; explain snapshot semantics in implementation. |
| Idempotency key race or reuse | Concurrent duplicate requests could double-post, or changed payload could masquerade as a retry. | Unique `(scope,key)`, canonical hash, conflict wait/read, strict mismatch error; define key retention and test concurrent retry. |
| Partial-refund race | Two refunds can both observe remaining cap and exceed it. | Lock original transaction before cumulative sum and write; test simultaneous near-limit requests. |
| Currency mismatch | Numerically equal amounts from different currencies are not interchangeable. | Currency FK, single-currency journal rule and trigger checks; exclude FX initially. |
| Refund/reversal overlap | A full reversal after partial refunds could compensate value twice. | V1 prohibits reversal after any posted refund; lock original and test rejection. |
| Settlement ambiguity | External lines may be gross/net, include fees, duplicate records, or arrive late. | V1 uses gross capture/refund amounts, excludes fees/taxes/FX, enforces one-to-one matching, retains import evidence, and versions reconciliation runs. |
| Durable failure analytics vs atomicity | Logging failure in the same transaction rolls back; autonomous persistence adds a separate consistency boundary. | V1 rejected requests raise/roll back; durable failed-request analytics are out of scope. |
| Numeric precision and rounding | NUMERIC is exact but a typmod can round excess fractional digits before later checks. | Accept unconstrained numeric at function boundary, validate scale/range first, then insert into NUMERIC(20,4); test too many decimals. |
| Time and date boundaries | Time zones and statement cutoffs can skew daily reporting/settlement matching. | Use `timestamptz`, UTC storage, explicit business timezone/cutoff in report parameters. |
| Trigger complexity | Hidden side effects are harder for learners to explain and debug. | Keep triggers narrow, named, documented, and covered by SQL assertions; put business orchestration in focused functions. |
| Benchmark reproducibility | Results vary with hardware, cache, dataset, and config. | Record environment/version/data scale/query/plan and rerun; report observations rather than general claims. |

## Resolved architecture questions

- A full reversal cannot follow any posted refund.
- Settlement statements use gross amounts; fee accounting is a later explicit extension.
- Rejected requests do not produce durable records in V1.
- Fictional reference data uses a small documented set of currencies and minor-unit scales; no exchange rates are loaded.
