# LedgerX Implementation Sequence

This is the implementation sequence, not a claim that any milestone is complete. Each phase ends with a reviewable artifact, relevant tests, accurate documentation, and a local Git checkpoint after successful verification.

| Phase | Focus | Verification gate |
|---|---|---|
| A | Documentation audit and architecture choices | Source documents agree with the fixed decisions in the execution brief. |
| B | PostgreSQL 17 infrastructure and migrations | Clean Compose startup, migration checksums, repeatable setup, safe roles. |
| C | Core schema | Constraints, reference data, indexes, schema assertions and permissions. |
| D | Financial engine | Balance projection, deferred journal integrity, operation functions, rollback and business rules. |
| E | Reliability and security | Idempotency, concurrency, refunds/reversals, audit, controlled rebuild and privilege tests. |
| F | Settlement | Statement import, one-to-one gross matching, versioned reconciliation and exception fixtures. |
| G | Integrity and analytics | Independent auditor, projection parity/rebuild, useful reports and justified SQL features. |
| H | Performance | Deterministic scales, `EXPLAIN (ANALYZE, BUFFERS)`, actual plans/timings, measured index comparisons. |
| I | Finalization | Full suite, GitHub Actions, documentation/learning guide, setup walkthrough and known limitations. |

Every significant SQL file has a neighboring learning note covering purpose, dependencies, concepts, key statements, why the approach was chosen, alternatives, failure cases, execution, verification, and interview questions. Concurrency demonstrations use independent sessions and record observed outcomes.
