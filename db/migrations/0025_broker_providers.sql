-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0025 · Brokerage provider catalogue and connections                       ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Implements the broker-linking spec. Two invariants the schema is shaped
-- around:
--   • No credential value ever lands in this database. A connection holds a
--     reference into the secret store and nothing else; the check constraint
--     below is a blunt instrument against the obvious mistakes.
--   • A read-only connection must be structurally unable to trade. The column
--     is NOT NULL with no default, so every connection states its posture, and
--     the OMS refuses any connection whose can_trade is false.

CREATE SCHEMA IF NOT EXISTS broker;

CREATE TYPE broker.auth_kind AS ENUM (
  'oauth2', 'oauth1', 'api_key', 'api_key_secret', 'username_password', 'gateway_session'
);

CREATE TYPE broker.integration_kind AS ENUM (
  'native',      -- we talk to the broker's own API
  'aggregator'   -- a third party aggregates it for us; always read-only
);

CREATE TYPE broker.resource AS ENUM (
  'balances', 'positions', 'transactions', 'orders', 'lots', 'documents'
);

CREATE TYPE broker.connection_state AS ENUM (
  'pending',                  -- link started, not yet authorised
  'active',
  'reauthorisation_required', -- token expired; user action needed, not an outage
  'degraded',                 -- provider failing; last-known data still served
  'revoked',
  'error'
);

-- ── Provider catalogue ──────────────────────────────────────────────────────
CREATE TABLE broker.provider (
  id              smallserial PRIMARY KEY,
  key             varchar(32) UNIQUE NOT NULL,
  name            varchar(80) NOT NULL,
  integration     broker.integration_kind NOT NULL,
  auth_kind       broker.auth_kind NOT NULL,
  -- Base URLs come from here, never from user input: this is the SSRF
  -- boundary for the whole sync path.
  base_url        text NOT NULL,
  oauth_authorize_url text,
  oauth_token_url text,
  oauth_scopes    text[] NOT NULL DEFAULT '{}',
  -- Declared capability matrix. The sync scheduler never attempts a resource a
  -- provider has not declared, so an unsupported endpoint is a no-op rather
  -- than a recurring error.
  supported_resources broker.resource[] NOT NULL DEFAULT '{}',
  supplies_lots   boolean NOT NULL DEFAULT false,
  supplies_transaction_history boolean NOT NULL DEFAULT false,
  transaction_history_days integer,
  supports_trading boolean NOT NULL DEFAULT false,
  asset_classes   reference.asset_class[] NOT NULL DEFAULT '{}',
  -- Rate limits drive the token bucket; per-provider, not a global constant.
  rate_limit_rpm  integer NOT NULL DEFAULT 60,
  rate_limit_burst integer NOT NULL DEFAULT 10,
  min_sync_interval_seconds integer NOT NULL DEFAULT 300,
  logo_url        text,
  is_enabled      boolean NOT NULL DEFAULT true,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  -- An aggregator link is read-only by construction: we are not routing orders
  -- through someone else's aggregation layer.
  CONSTRAINT provider_aggregator_is_read_only
    CHECK (integration <> 'aggregator' OR NOT supports_trading),
  CONSTRAINT provider_history_days_when_supported
    CHECK (NOT supplies_transaction_history OR transaction_history_days IS NOT NULL),
  CONSTRAINT provider_base_url_is_https
    CHECK (base_url ~ '^https://')
);

COMMENT ON COLUMN broker.provider.base_url IS
  'The only source of outbound hostnames for this provider. Nothing in the sync path may take a URL from user input or from a provider response, which is what keeps SSRF off the table.';

-- ── Connections ─────────────────────────────────────────────────────────────
CREATE TABLE broker.connection (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('bcn'),
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  provider_id     smallint NOT NULL REFERENCES broker.provider(id) ON DELETE RESTRICT,

  -- Pointer into Secrets Manager / Vault. Never the credential.
  secret_ref      text NOT NULL,
  environment     varchar(12) NOT NULL DEFAULT 'paper',   -- paper | live

  -- Posture. NOT NULL with no default: every connection must state whether it
  -- can trade, and the execution gateway refuses any connection where this is
  -- false rather than checking a nullable flag.
  can_trade       boolean NOT NULL,

  -- What the provider declared AT LINK TIME. Kept separate from the catalogue
  -- so behaviour stays reproducible if we later change the catalogue row.
  capability_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  granted_scopes  text[] NOT NULL DEFAULT '{}',

  state           broker.connection_state NOT NULL DEFAULT 'pending',
  state_reason    text,
  -- Broker-side identifiers, useful for support but not secret.
  external_account_id varchar(64),
  external_account_mask varchar(24),
  institution_name varchar(80),

  consecutive_failures smallint NOT NULL DEFAULT 0,
  circuit_open_until timestamptz,
  last_success_at timestamptz,
  linked_at       timestamptz,
  revoked_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  -- A crude but effective guard against the catastrophic mistake. Real
  -- credentials are long and high-entropy; a secret_ref is a path.
  CONSTRAINT connection_secret_ref_is_a_reference
    CHECK (secret_ref ~ '^(arn:aws:secretsmanager:|vault://|local://)' AND length(secret_ref) < 512),
  CONSTRAINT connection_revoked_has_timestamp
    CHECK ((state = 'revoked') = (revoked_at IS NOT NULL)),
  CONSTRAINT connection_error_has_reason
    CHECK (state NOT IN ('error', 'degraded') OR state_reason IS NOT NULL)
);

CREATE INDEX connection_account_idx ON broker.connection (account_id)
  WHERE revoked_at IS NULL;
CREATE INDEX connection_user_idx ON broker.connection (user_id)
  WHERE revoked_at IS NULL;
CREATE INDEX connection_syncable_idx ON broker.connection (provider_id, state)
  WHERE state = 'active';
CREATE INDEX connection_unhealthy_idx ON broker.connection (state, updated_at DESC)
  WHERE state IN ('degraded', 'error', 'reauthorisation_required');
-- One live connection per account per provider per environment.
CREATE UNIQUE INDEX connection_unique_active_idx
  ON broker.connection (account_id, provider_id, environment)
  WHERE revoked_at IS NULL;

COMMENT ON CONSTRAINT connection_secret_ref_is_a_reference ON broker.connection IS
  'Shape check on the secret pointer. It will not stop a determined mistake, but it does stop the common one: pasting the token into the column meant to reference it.';

-- The predicate the execution gateway calls before routing anything.
CREATE OR REPLACE FUNCTION broker.can_route_orders(p_connection_id uuid)
  RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM broker.connection c
      JOIN broker.provider p ON p.id = c.provider_id
     WHERE c.id = p_connection_id
       AND c.can_trade
       AND c.state = 'active'
       AND c.revoked_at IS NULL
       AND p.supports_trading
       AND p.integration = 'native'
  )
$$;

COMMENT ON FUNCTION broker.can_route_orders IS
  'Trading requires agreement from three independent facts: the connection says it may trade, the provider supports trading, and the integration is native. An aggregator-backed link can never satisfy all three.';

SELECT platform.attach_touch_triggers('broker');
