-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0001 · Extensions, schemas, roles and shared conventions                 ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Establishes the vocabulary every later migration relies on: the schema
-- layout, the tenancy helper functions used by RLS, the audit trigger, and
-- the domains that keep money and price precision honest.

-- ── Extensions ───────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS timescaledb;          -- hypertables, CAGGs
CREATE EXTENSION IF NOT EXISTS pgcrypto;             -- gen_random_uuid, digest
CREATE EXTENSION IF NOT EXISTS citext;               -- case-insensitive email
CREATE EXTENSION IF NOT EXISTS pg_trgm;              -- instrument search
CREATE EXTENSION IF NOT EXISTS btree_gist;           -- exclusion constraints
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- ── Schemas ──────────────────────────────────────────────────────────────────
-- Separated by lifecycle and access pattern rather than by service: several
-- services legitimately read reference data, but only one writes each schema.
CREATE SCHEMA IF NOT EXISTS identity;    -- users, auth, devices, consent
CREATE SCHEMA IF NOT EXISTS reference;   -- instruments, venues, calendars
CREATE SCHEMA IF NOT EXISTS market;      -- ticks, bars, books, corp actions
CREATE SCHEMA IF NOT EXISTS fundamental; -- statements, estimates, macro
CREATE SCHEMA IF NOT EXISTS book;        -- accounts, portfolios, positions, cash
CREATE SCHEMA IF NOT EXISTS oms;         -- orders, fills, routes, algos
CREATE SCHEMA IF NOT EXISTS research;    -- strategies, backtests, features
CREATE SCHEMA IF NOT EXISTS risk;        -- limits, VaR, exposures, breaches
CREATE SCHEMA IF NOT EXISTS notify;      -- watchlists, alert rules, deliveries
CREATE SCHEMA IF NOT EXISTS platform;    -- outbox, jobs, idempotency, flags
CREATE SCHEMA IF NOT EXISTS audit;       -- append-only change log

COMMENT ON SCHEMA market  IS 'Time-series market data. Timescale hypertables; append-only.';
COMMENT ON SCHEMA oms     IS 'Order lifecycle. Orders are immutable after terminal state; oms.order_events is the source of truth.';
COMMENT ON SCHEMA audit   IS 'Append-only. No UPDATE/DELETE grants are ever issued here.';

-- ── Service roles ────────────────────────────────────────────────────────────
-- Each service connects as its own role so that RLS and grants can express
-- least privilege. Passwords are injected by Terraform/Secrets Manager; the
-- DO block keeps local bootstrap idempotent.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    'helios_gateway', 'helios_marketdata', 'helios_quant',
    'helios_risk', 'helios_execution', 'helios_notify', 'helios_readonly'
  ] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

GRANT USAGE ON SCHEMA reference, market, fundamental TO helios_readonly;

-- ── Domains: make precision mistakes unrepresentable ─────────────────────────
-- Money is never a float. Prices carry 12 decimals to survive crypto and FX
-- minor pairs; quantities carry 18 to survive fractional shares and satoshis.
CREATE DOMAIN reference.price      AS numeric(28, 12) CHECK (VALUE IS NULL OR VALUE >= 0);
CREATE DOMAIN reference.signed_px  AS numeric(28, 12);  -- spreads, P&L per unit
CREATE DOMAIN reference.quantity   AS numeric(38, 18);
CREATE DOMAIN reference.money      AS numeric(28, 8);
CREATE DOMAIN reference.bps        AS numeric(12, 6);
CREATE DOMAIN reference.ratio      AS numeric(18, 10);
CREATE DOMAIN reference.weight     AS numeric(12, 10) CHECK (VALUE IS NULL OR (VALUE >= -10 AND VALUE <= 10));
CREATE DOMAIN reference.currency_code AS char(3) CHECK (VALUE ~ '^[A-Z]{3}$');
CREATE DOMAIN reference.ticker     AS varchar(32) CHECK (VALUE = upper(VALUE) AND length(VALUE) > 0);
CREATE DOMAIN reference.email      AS citext CHECK (VALUE ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$');

COMMENT ON DOMAIN reference.price IS 'numeric(28,12): exact decimal. Never use float for anything that touches a ledger.';

-- ── Shared enums ─────────────────────────────────────────────────────────────
CREATE TYPE reference.asset_class AS ENUM (
  'equity', 'etf', 'adr', 'fund', 'option', 'future', 'future_option',
  'forex', 'crypto', 'crypto_perp', 'index', 'bond', 'commodity', 'warrant', 'cfd'
);

CREATE TYPE reference.bar_interval AS ENUM (
  '1s', '5s', '15s', '1m', '5m', '15m', '30m', '1h', '4h', '1d', '1w', '1mo'
);

CREATE TYPE reference.side AS ENUM ('buy', 'sell');
CREATE TYPE reference.position_side AS ENUM ('long', 'short', 'flat');

CREATE TYPE reference.data_quality AS ENUM (
  'verified',    -- reconciled against a second vendor
  'vendor',      -- single vendor, accepted
  'derived',     -- computed by us (e.g. aggregated bar)
  'estimated',   -- gap-filled
  'suspect'      -- failed a validation rule; excluded from research by default
);

-- ── Tenancy helpers used by RLS policies ─────────────────────────────────────
-- The gateway sets these per transaction: SET LOCAL helios.user_id = '…'.
-- They must never raise, because they run inside policy expressions on every
-- row; an unset context yields NULL and therefore denies access.
CREATE OR REPLACE FUNCTION platform.current_user_id() RETURNS uuid
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT nullif(current_setting('helios.user_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION platform.current_account_id() RETURNS uuid
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT nullif(current_setting('helios.account_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION platform.current_request_id() RETURNS text
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT nullif(current_setting('helios.request_id', true), '')
$$;

CREATE OR REPLACE FUNCTION platform.is_service_role() RETURNS boolean
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT current_user LIKE 'helios\_%' AND current_user <> 'helios_readonly'
$$;

-- ── updated_at maintenance ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION platform.touch_updated_at() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Attach the touch trigger to every table in a schema that has updated_at.
-- Called at the end of each migration so new tables pick it up automatically.
CREATE OR REPLACE FUNCTION platform.attach_touch_triggers(target_schema text)
  RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  t record;
  attached integer := 0;
BEGIN
  FOR t IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at' AND a.attnum > 0
    WHERE n.nspname = target_schema
      AND c.relkind = 'r'
      AND NOT EXISTS (
        SELECT 1 FROM pg_trigger g
        WHERE g.tgrelid = c.oid AND g.tgname = 'trg_touch_updated_at'
      )
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION platform.touch_updated_at()',
      target_schema, t.relname);
    attached := attached + 1;
  END LOOP;
  RETURN attached;
END $$;

-- ── Deterministic, sortable public identifiers ───────────────────────────────
-- Surrogate keys stay uuid internally; these are what we expose in APIs and
-- logs. Prefix + base32 time component so support can eyeball ordering.
CREATE OR REPLACE FUNCTION platform.public_id(prefix text)
  RETURNS text LANGUAGE plpgsql VOLATILE AS $$
DECLARE
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';  -- Crockford
  ms       bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  out      text := '';
  i        integer;
BEGIN
  WHILE ms > 0 LOOP
    out := substr(alphabet, (ms % 32)::int + 1, 1) || out;
    ms := ms / 32;
  END LOOP;
  FOR i IN 1..8 LOOP
    out := out || substr(alphabet, floor(random() * 32)::int + 1, 1);
  END LOOP;
  RETURN prefix || '_' || out;
END $$;

COMMENT ON FUNCTION platform.public_id IS 'Lexicographically sortable external id, e.g. ord_01JB3QF7K2ZXQ8M4.';

-- ── Numeric helpers used across risk and research ────────────────────────────
CREATE OR REPLACE FUNCTION platform.safe_div(numerator numeric, denominator numeric)
  RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN denominator IS NULL OR denominator = 0 THEN NULL
              ELSE numerator / denominator END
$$;

CREATE OR REPLACE FUNCTION platform.pct_change(old_value numeric, new_value numeric)
  RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT platform.safe_div(new_value - old_value, abs(old_value))
$$;

-- Annualisation factor per bar interval; used by both SQL reporting views and
-- the quant engine's SQL fallback path so the two never disagree.
CREATE OR REPLACE FUNCTION platform.periods_per_year(iv reference.bar_interval)
  RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE iv
    WHEN '1s'  THEN 252 * 6.5 * 3600
    WHEN '5s'  THEN 252 * 6.5 * 720
    WHEN '15s' THEN 252 * 6.5 * 240
    WHEN '1m'  THEN 252 * 390
    WHEN '5m'  THEN 252 * 78
    WHEN '15m' THEN 252 * 26
    WHEN '30m' THEN 252 * 13
    WHEN '1h'  THEN 252 * 6.5
    WHEN '4h'  THEN 252 * 1.625
    WHEN '1d'  THEN 252
    WHEN '1w'  THEN 52
    WHEN '1mo' THEN 12
  END::numeric
$$;

CREATE OR REPLACE FUNCTION platform.interval_to_duration(iv reference.bar_interval)
  RETURNS interval LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE iv
    WHEN '1s' THEN interval '1 second'   WHEN '5s'  THEN interval '5 seconds'
    WHEN '15s' THEN interval '15 seconds' WHEN '1m' THEN interval '1 minute'
    WHEN '5m' THEN interval '5 minutes'  WHEN '15m' THEN interval '15 minutes'
    WHEN '30m' THEN interval '30 minutes' WHEN '1h' THEN interval '1 hour'
    WHEN '4h' THEN interval '4 hours'    WHEN '1d'  THEN interval '1 day'
    WHEN '1w' THEN interval '1 week'     WHEN '1mo' THEN interval '1 month'
  END
$$;
