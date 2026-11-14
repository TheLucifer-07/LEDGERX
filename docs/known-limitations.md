# Known Limitations

- LedgerX is an educational local database project, not a production payment system.
- No payment rails, API, identity system, card data, or sensitive customer information are present.
- Foreign exchange, fees, taxes, chargebacks, split settlement, and many-to-one matching are out of scope.
- Rejected requests raise and roll back; durable failed-request telemetry is not implemented.
- Settlement matches gross capture/refund records one-to-one within an explicit time window.
- Runtime data access is database-role based; the sample Compose environment still has a local superuser credential.
- The concurrency harness proves selected races under the local test setup, not all schedules or hardware conditions.
- Performance measurements use temporary synthetic tables and must not be treated as end-to-end transaction throughput.
- Operational high availability, backups, restore drills, replication, retention policy, and external security review are not implemented.
