# Learning Path

Follow `LEARNING_GUIDE.md` for the detailed walkthrough. The dependency order is:

1. Requirements, system architecture, ER model, data dictionary.
2. Compose and role/migration setup (`0001`).
3. Normalized schema and fictional seed records (`0002`).
4. Row protections, deferred journal checks, and projection trigger (`0003`).
5. Atomic business operations and idempotency (`0004`, `0005`).
6. Auditor, recovery, and restricted privileges (`0006`).
7. Refund/reversal lifecycle, then settlement import and reconciliation (`0004`, `0007`, `0008`, `0010`).
8. Reporting views, active refund history, and reversal verification (`0009`, `0010`).
9. SQL assertions and concurrent sessions in `tests/`.
10. The rollback-only walkthrough in `examples/end_to_end_demo.sql`.
11. Synthetic query benchmark and interview explanations.

For each SQL file, read the adjacent `.md` learning note before inspecting its definitions. After a test run, explain the database behavior in your own words before moving to the next layer.
