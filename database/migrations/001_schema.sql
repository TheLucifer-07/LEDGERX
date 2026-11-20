-- 001_schema.sql : core tables, constraints, indexes.
-- Executed by the migration role (table owner). The runtime role is granted
-- access in 003_rls_and_grants.sql only.

CREATE SCHEMA IF NOT EXISTS lx;
REVOKE ALL ON SCHEMA lx FROM PUBLIC;
-- PostgreSQL grants EXECUTE to PUBLIC on new functions by default; remove that default for
-- everything this role creates (a schema-scoped ALTER DEFAULT PRIVILEGES cannot do this).
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- ---------------------------------------------------------------- currencies
CREATE TABLE lx.currencies (
  code       char(3)  PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
  name       text     NOT NULL,
  minor_unit smallint NOT NULL CHECK (minor_unit BETWEEN 0 AND 6)
);
INSERT INTO lx.currencies (code, name, minor_unit) VALUES
  ('INR','Indian Rupee',2), ('USD','US Dollar',2), ('EUR','Euro',2),
  ('GBP','Pound Sterling',2), ('AED','UAE Dirham',2), ('SGD','Singapore Dollar',2),
  ('AUD','Australian Dollar',2), ('CAD','Canadian Dollar',2), ('JPY','Japanese Yen',0);

-- --------------------------------------------------------------------- users
CREATE TABLE lx.users (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE,           -- Supabase auth.users.id (the JWT "sub")
  email        text NOT NULL CHECK (length(email) BETWEEN 3 AND 320),
  display_name text CHECK (display_name IS NULL OR length(display_name) <= 120),
  created_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz
);
CREATE UNIQUE INDEX users_email_uq ON lx.users (lower(email)) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------- workspaces
CREATE TABLE lx.workspaces (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type          text NOT NULL CHECK (type IN ('student','personal','family','business','demo')),
  name          text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  base_currency char(3) NOT NULL REFERENCES lx.currencies(code),
  created_by    uuid REFERENCES lx.users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  archived_at   timestamptz
);

CREATE TABLE lx.workspace_members (
  workspace_id uuid NOT NULL REFERENCES lx.workspaces(id),
  user_id      uuid NOT NULL REFERENCES lx.users(id),
  role         text NOT NULL CHECK (role IN ('owner','admin','member','viewer')),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','removed')),
  joined_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id)
);
CREATE INDEX workspace_members_user_idx ON lx.workspace_members (user_id) WHERE status = 'active';

CREATE TABLE lx.invitations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES lx.workspaces(id),
  email        text NOT NULL CHECK (length(email) BETWEEN 3 AND 320),
  role         text NOT NULL CHECK (role IN ('admin','member','viewer')),
  token_hash   bytea NOT NULL UNIQUE,           -- sha256 of the raw token; raw token is never stored
  invited_by   uuid NOT NULL,
  expires_at   timestamptz NOT NULL,
  accepted_at  timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (workspace_id, invited_by) REFERENCES lx.workspace_members (workspace_id, user_id)
);
CREATE INDEX invitations_ws_idx ON lx.invitations (workspace_id);

-- ------------------------------------------------- accounts (chart of accounts)
-- owner_user_id IS NULL  => shared workspace account
-- owner_user_id = member => private account, visible only to that member
CREATE TABLE lx.accounts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  uuid NOT NULL REFERENCES lx.workspaces(id),
  code          text NOT NULL CHECK (code ~ '^[A-Za-z0-9._-]{1,32}$'),
  name          text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  class         text NOT NULL CHECK (class IN ('asset','liability','equity','income','expense')),
  subtype       text CHECK (subtype IS NULL OR length(subtype) <= 40),
  currency      char(3) NOT NULL REFERENCES lx.currencies(code),
  parent_id     uuid,
  owner_user_id uuid,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, id),
  UNIQUE (workspace_id, id, currency),
  FOREIGN KEY (workspace_id, parent_id) REFERENCES lx.accounts (workspace_id, id),
  FOREIGN KEY (workspace_id, owner_user_id) REFERENCES lx.workspace_members (workspace_id, user_id),
  CHECK (parent_id IS NULL OR parent_id <> id)
);
CREATE UNIQUE INDEX accounts_code_uq ON lx.accounts
  (workspace_id, coalesce(owner_user_id, '00000000-0000-0000-0000-000000000000'::uuid), code);
CREATE INDEX accounts_ws_class_idx ON lx.accounts (workspace_id, class);

-- ------------------------------------------------------------------- journal
CREATE TABLE lx.journal_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq               bigint GENERATED ALWAYS AS IDENTITY,
  workspace_id      uuid NOT NULL REFERENCES lx.workspaces(id),
  entry_date        date NOT NULL,
  description       text NOT NULL CHECK (length(btrim(description)) BETWEEN 1 AND 500),
  kind              text NOT NULL DEFAULT 'standard'
                    CHECK (kind IN ('standard','transfer','opening_balance','reversal')),
  reverses_entry_id uuid,
  reversal_reason   text CHECK (reversal_reason IS NULL OR length(reversal_reason) <= 500),
  private_owner_id  uuid,                        -- NULL = shared entry
  created_by        uuid NOT NULL REFERENCES lx.users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_xid       xid8 NOT NULL DEFAULT pg_current_xact_id(),
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (workspace_id, id),
  UNIQUE (seq),
  FOREIGN KEY (workspace_id, reverses_entry_id) REFERENCES lx.journal_entries (workspace_id, id),
  FOREIGN KEY (workspace_id, private_owner_id) REFERENCES lx.workspace_members (workspace_id, user_id),
  CHECK ((kind = 'reversal') = (reverses_entry_id IS NOT NULL)),
  CHECK (reverses_entry_id IS NULL OR reverses_entry_id <> id)
);
-- An entry can be reversed at most once.
CREATE UNIQUE INDEX journal_entries_one_reversal_uq
  ON lx.journal_entries (reverses_entry_id) WHERE reverses_entry_id IS NOT NULL;
CREATE INDEX journal_entries_ws_date_idx ON lx.journal_entries (workspace_id, entry_date DESC, seq DESC);

CREATE TABLE lx.journal_lines (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id     uuid NOT NULL,
  entry_id         uuid NOT NULL,
  line_no          integer NOT NULL CHECK (line_no > 0),
  account_id       uuid NOT NULL,
  currency         char(3) NOT NULL,
  debit            numeric(24,6) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
  credit           numeric(24,6) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  memo             text CHECK (memo IS NULL OR length(memo) <= 500),
  private_owner_id uuid,                         -- always copied from the account by trigger
  UNIQUE (entry_id, line_no),
  CHECK ((debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)),
  FOREIGN KEY (workspace_id, entry_id) REFERENCES lx.journal_entries (workspace_id, id),
  -- the line currency MUST equal the account currency:
  FOREIGN KEY (workspace_id, account_id, currency) REFERENCES lx.accounts (workspace_id, id, currency)
);
CREATE INDEX journal_lines_account_idx ON lx.journal_lines (workspace_id, account_id, entry_id);
CREATE INDEX journal_lines_entry_idx   ON lx.journal_lines (entry_id);

-- Rebuildable projection of per-account totals (authoritative source = journal_lines).
CREATE TABLE lx.account_balances (
  workspace_id     uuid NOT NULL,
  account_id       uuid NOT NULL,
  currency         char(3) NOT NULL,
  debit_total      numeric(28,6) NOT NULL DEFAULT 0,
  credit_total     numeric(28,6) NOT NULL DEFAULT 0,
  line_count       bigint NOT NULL DEFAULT 0,
  private_owner_id uuid,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, account_id),
  FOREIGN KEY (workspace_id, account_id, currency) REFERENCES lx.accounts (workspace_id, id, currency)
);

-- --------------------------------------------------------------- idempotency
CREATE TABLE lx.idempotency_keys (
  workspace_id uuid NOT NULL REFERENCES lx.workspaces(id),
  key          text NOT NULL CHECK (length(key) BETWEEN 8 AND 200),
  user_id      uuid NOT NULL REFERENCES lx.users(id),
  operation    text NOT NULL,
  request_hash bytea NOT NULL,
  entry_id     uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, key),
  FOREIGN KEY (workspace_id, entry_id) REFERENCES lx.journal_entries (workspace_id, id)
);

-- --------------------------------------------------------------------- audit
CREATE TABLE lx.audit_events (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id     uuid REFERENCES lx.workspaces(id),
  actor_user_id    uuid REFERENCES lx.users(id),
  action           text NOT NULL,
  entity_type      text NOT NULL,
  entity_id        uuid,
  private_owner_id uuid,
  details          jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at      timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX audit_events_ws_idx ON lx.audit_events (workspace_id, id DESC);
