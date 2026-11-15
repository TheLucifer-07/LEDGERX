# Known Limitations

- LedgerX is an educational product under development, not a production financial system.
- The Express API is unauthenticated, read-only, and intended for local development. It refuses production startup until Supabase authentication, workspace authorization, and PostgreSQL RLS are implemented and verified.
- Existing local rows are not assigned to workspaces and must not be exposed publicly or reused as a demo dataset. A controlled legacy workspace and independent synthetic demo workspace are still required.
- The React application is currently the PostgreSQL operations dashboard. Public pages, registration, onboarding, workspace switching, and the student/personal/family/business product flows are not implemented.
- Financial write forms, budgets, savings goals, recurring records, CSV imports/exports, and Gemini assistance are not implemented.
- Vercel, Render, Supabase Auth, hosted database migrations, backups, and restore drills are not configured.
- Foreign exchange, fees, taxes, chargebacks, split settlement, and many-to-one matching are out of scope.
- Rejected requests raise and roll back; durable failed-request telemetry is not implemented.
- Settlement matches gross capture/refund records one-to-one within an explicit time window.
- Imported statement evidence is append-only; V1 has no batch reopen or corrected-import workflow after import completes.
- Reversing a reversal is rejected; V1 supports one reversal per original transaction.
- Runtime data access is currently a restricted local read-only database role; the sample Compose environment still has a local administrator credential for migrations and seeds.
- The concurrency harness proves selected races under the local test setup, not all schedules or hardware conditions.
- Performance measurements use temporary synthetic tables and must not be treated as end-to-end transaction throughput.
- Operational high availability, backups, restore drills, replication, retention policy, and external security review are not implemented.
