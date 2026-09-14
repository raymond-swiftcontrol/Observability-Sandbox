-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0013 · Watchlists, alert rules, triggers, notification delivery           ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Alert evaluation runs against every tick, so the rule set has to be
-- queryable by instrument in one index scan. The harder problem is not firing:
-- a threshold rule whose condition stays true must not fire on every tick, so
-- each rule instance carries hysteresis state and a cooldown.

CREATE TYPE notify.alert_kind AS ENUM (
  'price_above', 'price_below', 'price_crosses',
  'percent_move', 'percent_move_intraday', 'gap',
  'volume_spike', 'unusual_options_activity',
  'indicator_cross', 'indicator_threshold',
  'earnings_upcoming', 'corporate_action',
  'order_filled', 'order_rejected', 'position_pnl', 'stop_hit',
  'risk_breach', 'margin_call', 'kill_switch',
  'strategy_signal', 'backtest_complete',
  'broker_sync_stale', 'reconciliation_break',
  'social_mention', 'social_follow', 'social_reply'
);

CREATE TYPE notify.channel AS ENUM ('push', 'email', 'sms', 'in_app', 'webhook');

CREATE TYPE notify.urgency AS ENUM ('critical', 'high', 'normal', 'low');

CREATE TYPE notify.delivery_status AS ENUM (
  'pending', 'sent', 'delivered', 'read', 'failed', 'suppressed', 'expired'
);

-- ── Watchlists ───────────────────────────────────────────────────────────────
CREATE TABLE notify.watchlist (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('wl'),
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  name            varchar(64) NOT NULL,
  description     text,
  color           char(7),
  is_default      boolean NOT NULL DEFAULT false,
  -- Sharing a watchlist is a social act; it is opt-in and separate from
  -- sharing performance.
  is_public       boolean NOT NULL DEFAULT false,
  share_slug      varchar(32) UNIQUE,
  display_order   smallint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, name)
);

CREATE UNIQUE INDEX watchlist_one_default_per_user
  ON notify.watchlist (user_id) WHERE is_default;
CREATE INDEX watchlist_public_idx ON notify.watchlist (share_slug)
  WHERE is_public AND share_slug IS NOT NULL;

CREATE TABLE notify.watchlist_item (
  watchlist_id    uuid NOT NULL REFERENCES notify.watchlist(id) ON DELETE CASCADE,
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  display_order   smallint NOT NULL DEFAULT 0,
  note            text,
  -- Captured when added, so the list can show "since you added it" without a
  -- separate lookup into bars.
  added_price     reference.price,
  added_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (watchlist_id, instrument_id)
);

CREATE INDEX watchlist_item_instrument_idx
  ON notify.watchlist_item (instrument_id);

-- ── Alert rules ─────────────────────────────────────────────────────────────
CREATE TABLE notify.alert_rule (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('alr'),
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  kind            notify.alert_kind NOT NULL,
  name            varchar(80),
  -- Subject: at most one of these, depending on kind.
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE CASCADE,
  account_id      uuid REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE CASCADE,
  deployment_id   uuid REFERENCES research.deployment(id) ON DELETE CASCADE,
  watchlist_id    uuid REFERENCES notify.watchlist(id) ON DELETE CASCADE,

  -- Condition. Kept as typed columns for the common numeric comparisons and a
  -- jsonb escape hatch for indicator rules, because indexing the common case
  -- matters more than uniformity.
  operator        varchar(8),            -- gt | lt | gte | lte | cross_up | cross_down
  threshold       numeric(28, 10),
  threshold_unit  varchar(16),           -- price | percent | ratio | count
  indicator       varchar(32),
  indicator_params jsonb NOT NULL DEFAULT '{}'::jsonb,
  bar_interval    reference.bar_interval,
  lookback_bars   integer,
  condition_extra jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Delivery
  channels        notify.channel[] NOT NULL DEFAULT '{push,in_app}',
  urgency         notify.urgency NOT NULL DEFAULT 'normal',
  message_template text,

  -- Firing discipline. cooldown_seconds is the minimum gap between fires;
  -- reset_threshold is the hysteresis band the price must return through
  -- before the rule can arm again.
  is_one_shot     boolean NOT NULL DEFAULT false,
  cooldown_seconds integer NOT NULL DEFAULT 3600,
  reset_threshold numeric(28, 10),
  max_fires_per_day smallint,
  -- Session gating: most price alerts should not fire on a thin pre-market
  -- print, so this defaults to regular hours only.
  sessions        text[] NOT NULL DEFAULT '{regular}',
  quiet_hours_respected boolean NOT NULL DEFAULT true,

  -- State
  is_active       boolean NOT NULL DEFAULT true,
  is_armed        boolean NOT NULL DEFAULT true,
  last_fired_at   timestamptz,
  last_value      numeric(28, 10),
  fire_count      integer NOT NULL DEFAULT 0,
  fires_today     smallint NOT NULL DEFAULT 0,
  expires_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT alert_has_a_subject CHECK (
    instrument_id IS NOT NULL OR account_id IS NOT NULL
    OR portfolio_id IS NOT NULL OR deployment_id IS NOT NULL
    OR watchlist_id IS NOT NULL
  ),
  CONSTRAINT alert_threshold_needs_operator
    CHECK (threshold IS NULL OR operator IS NOT NULL),
  CONSTRAINT alert_indicator_rules_have_indicator
    CHECK (kind NOT IN ('indicator_cross','indicator_threshold') OR indicator IS NOT NULL),
  CONSTRAINT alert_cooldown_nonneg CHECK (cooldown_seconds >= 0),
  CONSTRAINT alert_channels_not_empty CHECK (array_length(channels, 1) > 0)
);

-- The evaluator's hot read: given a tick on instrument X, which armed rules
-- care? Partial index keeps the scan proportional to live rules only.
CREATE INDEX alert_rule_instrument_armed_idx
  ON notify.alert_rule (instrument_id, kind)
  WHERE is_active AND is_armed AND instrument_id IS NOT NULL;
CREATE INDEX alert_rule_user_idx ON notify.alert_rule (user_id, created_at DESC);
CREATE INDEX alert_rule_account_idx ON notify.alert_rule (account_id)
  WHERE is_active AND account_id IS NOT NULL;
CREATE INDEX alert_rule_expiring_idx ON notify.alert_rule (expires_at)
  WHERE expires_at IS NOT NULL AND is_active;

COMMENT ON COLUMN notify.alert_rule.reset_threshold IS
  'Hysteresis band. Without it, a price oscillating around the threshold fires the alert on every crossing; with it, the price must retrace through this level before the rule re-arms.';

-- ── Fires ───────────────────────────────────────────────────────────────────
CREATE TABLE notify.alert_trigger (
  id              bigserial PRIMARY KEY,
  alert_rule_id   uuid NOT NULL REFERENCES notify.alert_rule(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE SET NULL,
  observed_value  numeric(28, 10),
  threshold       numeric(28, 10),
  -- Enough context to render the notification without a second query, since
  -- the delivery path runs outside the request that produced the data.
  context         jsonb NOT NULL DEFAULT '{}'::jsonb,
  triggered_at    timestamptz NOT NULL DEFAULT now(),
  -- Suppression is recorded rather than silently skipped, so "why didn't I get
  -- an alert?" has an answer.
  suppressed      boolean NOT NULL DEFAULT false,
  suppressed_reason varchar(32)      -- cooldown | quiet_hours | daily_cap | duplicate
);

CREATE INDEX alert_trigger_rule_time_idx
  ON notify.alert_trigger (alert_rule_id, triggered_at DESC);
CREATE INDEX alert_trigger_user_time_idx
  ON notify.alert_trigger (user_id, triggered_at DESC) WHERE NOT suppressed;

-- ── Notifications and their delivery attempts ──────────────────────────────
CREATE TABLE notify.notification (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  category        varchar(32) NOT NULL,
  urgency         notify.urgency NOT NULL DEFAULT 'normal',
  title           varchar(120) NOT NULL,
  body            text NOT NULL,
  -- Deep link target, e.g. helios://instrument/ins_01J…
  deep_link       text,
  image_url       text,
  data            jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Provenance
  alert_trigger_id bigint REFERENCES notify.alert_trigger(id) ON DELETE SET NULL,
  source_type     varchar(32),
  source_id       uuid,
  -- Dedupe key: several producers can independently decide to tell a user the
  -- same thing, and the user should hear it once.
  dedupe_key      text,
  -- Digest batching: low-urgency notifications wait for the user's digest slot.
  digest_bucket   varchar(16),
  created_at      timestamptz NOT NULL DEFAULT now(),
  read_at         timestamptz,
  archived_at     timestamptz,
  expires_at      timestamptz
);

CREATE INDEX notification_user_unread_idx
  ON notify.notification (user_id, created_at DESC)
  WHERE read_at IS NULL AND archived_at IS NULL;
CREATE INDEX notification_user_time_idx
  ON notify.notification (user_id, created_at DESC);
CREATE UNIQUE INDEX notification_dedupe_idx
  ON notify.notification (user_id, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE TABLE notify.delivery (
  id              bigserial PRIMARY KEY,
  notification_id uuid NOT NULL REFERENCES notify.notification(id) ON DELETE CASCADE,
  channel         notify.channel NOT NULL,
  device_id       uuid REFERENCES identity.device(id) ON DELETE SET NULL,
  destination     text,             -- masked email / token prefix, never the full token
  status          notify.delivery_status NOT NULL DEFAULT 'pending',
  provider        varchar(24),
  provider_message_id varchar(128),
  attempt         smallint NOT NULL DEFAULT 1,
  -- Error classification drives the retry decision: a bad token is permanent
  -- and must invalidate the device, a 503 is transient.
  error_class     varchar(32),
  error_message   text,
  is_permanent_failure boolean NOT NULL DEFAULT false,
  queued_at       timestamptz NOT NULL DEFAULT now(),
  sent_at         timestamptz,
  delivered_at    timestamptz,
  next_retry_at   timestamptz,
  UNIQUE (notification_id, channel, device_id, attempt)
);

CREATE INDEX delivery_pending_idx ON notify.delivery (next_retry_at)
  WHERE status = 'pending' OR (status = 'failed' AND NOT is_permanent_failure);
CREATE INDEX delivery_notification_idx ON notify.delivery (notification_id);
CREATE INDEX delivery_permanent_failure_idx ON notify.delivery (device_id)
  WHERE is_permanent_failure;

COMMENT ON COLUMN notify.delivery.destination IS
  'Masked. A full push token or email address in a widely-read table is an unnecessary exposure; the real destination lives on identity.device.';

-- ── Preferences ─────────────────────────────────────────────────────────────
CREATE TABLE notify.preference (
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  category        varchar(32) NOT NULL,
  channels        notify.channel[] NOT NULL DEFAULT '{push,in_app}',
  is_enabled      boolean NOT NULL DEFAULT true,
  -- Digest instead of immediate delivery, for categories a user wants to know
  -- about but not be interrupted by.
  digest_mode     varchar(16) NOT NULL DEFAULT 'immediate',  -- immediate|daily|weekly|off
  digest_hour_local smallint CHECK (digest_hour_local BETWEEN 0 AND 23),
  PRIMARY KEY (user_id, category)
);

CREATE TABLE notify.quiet_hours (
  user_id         uuid PRIMARY KEY REFERENCES identity.user(id) ON DELETE CASCADE,
  is_enabled      boolean NOT NULL DEFAULT false,
  start_local     time NOT NULL DEFAULT '22:00',
  end_local       time NOT NULL DEFAULT '07:00',
  -- Critical notifications ignore quiet hours by default: a margin call at
  -- 3am is exactly the thing a user needs woken for.
  allow_critical  boolean NOT NULL DEFAULT true,
  weekend_only    boolean NOT NULL DEFAULT false,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

SELECT platform.attach_touch_triggers('notify');
