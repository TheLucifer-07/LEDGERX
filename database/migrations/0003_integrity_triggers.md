# Migration 0003: Integrity Triggers and Indexes

- **Purpose:** add query-path indexes and database guards for ledger immutability, normal-side balance projection updates, lifecycle transitions, audit append-only behavior, and commit-time journal validity.
- **Dependencies:** migration 0002 core tables; runs as `ledgerx_owner`.
- **Concepts:** partial B-tree indexes, `BEFORE` and `AFTER` triggers, deferred constraint triggers, aggregate validation, trigger-based transactional side effects, and explicit privilege revocation.
- **Important statements:** every new ledger line updates `account_balances` in the same transaction. The sign is positive when entry side equals account normal side and negative otherwise. At commit, header and line constraint triggers validate state, minimum line count, a single currency, exact debit/credit equality, and both totals matching the business amount.
- **Why this approach:** an ordinary `CHECK` cannot aggregate journal sibling rows. A deferred trigger sees the final transaction state and aborts commit when it is invalid. Table privileges and controlled functions constrain who can attempt writes.
- **Alternatives:** maintain balance in application code or check only in a posting function. Those approaches can be bypassed by other SQL writers. The trigger protects projection consistency and the deferred trigger protects the aggregate invariant.
- **Failure cases:** unbalanced journals, missing lines, currency mismatch, negative wallet projection, invalid state changes, or audit mutation abort the statement/transaction. Projection updates roll back with failed postings.
- **Execute:** `scripts/setup.sh` applies the migration after core schema creation.
- **Verify:** run the integrity tests after adding reference data and posting functions; inspect trigger definitions and index definitions with `pg_trigger` and `pg_indexes`.
- **Interview questions:** Why is this trigger deferred? How does normal-side balance differ for a debit-normal clearing account and a credit-normal wallet? Why are row locks still needed if balance updates are atomic?
