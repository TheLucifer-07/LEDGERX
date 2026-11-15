# LedgerX frontend

This is the independently installable React and Vite application. Install with `npm ci`, run the local UI with `npm run dev`, run unit tests with `npm test`, and build static assets with `npm run build`.

Copy `.env.example` to `.env` for local development. Leave `VITE_API_BASE_URL` empty to use Vite's `/api` proxy; set `API_PROXY_TARGET` to the local Express address. Vercel builds this directory and needs `VITE_API_BASE_URL`, `VITE_SUPABASE_URL`, and `VITE_SUPABASE_PUBLISHABLE_KEY` configured there.

The current pages are the local PostgreSQL operations dashboard. Authentication, workspace-specific pages, and public marketing routes are not implemented yet. Do not deploy this frontend publicly until those routes and the backend authorization layer are complete.
