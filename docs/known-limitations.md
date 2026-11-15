# Known Limitations

- LedgerX is an educational product under development, not a production financial system.
- The operator dashboard API remains unauthenticated, read-only, and intended for local development. Optional JWT-protected context and workspace-bootstrap routes are implemented, but they do not yet secure dashboard reads. The API refuses production startup.
- PostgreSQL workspaces, permissions, composite tenant foreign keys, and forced RLS are implemented in migrations 0012–0013. Migrations 0014–0018 add a restricted API role, idempotent workspace bootstrap, tightened function grants, and a denial for the cross-workspace audit function. Existing local rows are private in the legacy workspace. The separate demo workspace is empty and has no public read route.
- Public landing, email/password and Google sign-in, email confirmation callback, age attestation, and starter-workspace onboarding screens are implemented. They have not been connected to a real Supabase project or authenticated local API role. The 18+ attestation is client-side only and is not persisted or enforced by the server. Workspace switching/invitations and tenant-scoped financial views are not implemented.
- The existing PostgreSQL operations dashboard is available only at `/operations` during Vite development. Production builds redirect that route to the public home page so legacy-only data cannot be exposed through a public deployment.
- Financial write forms, budgets, savings goals, recurring records, CSV imports/exports, and Gemini assistance are not implemented.
- Vercel, Render, Supabase Auth, hosted database migrations, backups, and restore drills are not configured. Google OAuth and email confirmation still require provider-side setup.
- Foreign exchange, fees, taxes, chargebacks, split settlement, and many-to-one matching are out of scope.
- Rejected requests raise and roll back; durable failed-request telemetry is not implemented.
- Settlement matches gross capture/refund records one-to-one within an explicit time window.
- Imported statement evidence is append-only; V1 has no batch reopen or corrected-import workflow after import completes.
- Reversing a reversal is rejected; V1 supports one reversal per original transaction.
- Runtime data access is currently a restricted local read-only database role; the sample Compose environment still has a local administrator credential for migrations and seeds.
- Creating a second database inside the same PostgreSQL cluster currently encounters the existing migration 0001 role bootstrap because LedgerX roles are cluster-wide. Fresh initialization is verified on a separate PostgreSQL cluster; migration 0001 remains checksum-protected and unchanged.
- The concurrency harness proves selected races under the local test setup, not all schedules or hardware conditions.
- Performance measurements use temporary synthetic tables and must not be treated as end-to-end transaction throughput.
- Operational high availability, backups, restore drills, replication, retention policy, and external security review are not implemented.
