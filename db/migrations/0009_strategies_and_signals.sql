-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0009 · Strategies, versions, deployments and signals                      ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- A strategy is a named idea; a strategy_version is an immutable, hashed
-- snapshot of code + parameters. Backtests and live deployments both reference
-- a version, never the strategy, because "this backtest ran on that code" has
-- to stay true after the author edits their strategy tomorrow.

CREATE TYPE research.strategy_kind AS ENUM (
  'trend_following', 'mean_reversion', 'momentum', 'statistical_arbitrage',
  'pairs_trading', 'market_making', 'volatility', 'options_income',
  'factor_long_short', 'risk_parity', 'event_driven', 'machine_learning', 'custom'
);

CREATE TYPE research.strategy_status AS ENUM (
  'draft', 'backtesting', 'validated', 'paper_trading', 'live', 'paused', 'retired'
);

CREATE TYPE research.signal_action AS ENUM (
  'enter_long', 'enter_short', 'exit_long', 'exit_short',
  'increase', 'reduce', 'flat', 'hold', 'rebalance'
);

CREATE TABLE research.strategy (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('str'),
  owner_user_id   uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  name            varchar(100) NOT NULL,
  slug            varchar(100) NOT NULL,
  kind            research.strategy_kind NOT NULL,
  description     text,
  -- What the strategy trades and how often; drives which data it is allowed
  -- to request and which execution path it uses.
  asset_classes   reference.asset_class[] NOT NULL DEFAULT '{equity}',
  bar_interval    reference.bar_interval NOT NULL DEFAULT '1d',
  universe_definition jsonb NOT NULL DEFAULT '{}'::jsonb,
  status          research.strategy_status NOT NULL DEFAULT 'draft',
  -- Visibility in the social layer: sharing a strategy is opt-in and separate
  -- from sharing its results.
  is_public       boolean NOT NULL DEFAULT false,
  is_template     boolean NOT NULL DEFAULT false,
  forked_from_id  uuid REFERENCES research.strategy(id) ON DELETE SET NULL,
  tags            text[] NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  retired_at      timestamptz,
  UNIQUE (owner_user_id, slug)
);

CREATE INDEX strategy_owner_idx ON research.strategy (owner_user_id, updated_at DESC);
CREATE INDEX strategy_public_idx ON research.strategy (kind, updated_at DESC)
  WHERE is_public AND retired_at IS NULL;
CREATE INDEX strategy_tags_idx ON research.strategy USING gin (tags);

-- Immutable versions. content_hash is over code + default parameters + the
-- declared feature set, so an identical version is deduplicated and a
-- backtest's provenance is verifiable.
CREATE TABLE research.strategy_version (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  strategy_id     uuid NOT NULL REFERENCES research.strategy(id) ON DELETE CASCADE,
  version         integer NOT NULL,
  content_hash    char(64) NOT NULL,
  -- Either user Python in a sandbox, or a declarative rule tree built in the
  -- mobile strategy builder. Exactly one must be present.
  code            text,
  rule_tree       jsonb,
  language        varchar(16) NOT NULL DEFAULT 'python',
  runtime_version varchar(24) NOT NULL DEFAULT 'py3.11',
  default_parameters jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Declared up front so the engine can build exactly the features needed and
  -- refuse a strategy that reaches for data it did not declare.
  required_features text[] NOT NULL DEFAULT '{}',
  max_lookback_bars integer NOT NULL DEFAULT 252,
  changelog       text,
  created_by      uuid REFERENCES identity.user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (strategy_id, version),
  UNIQUE (strategy_id, content_hash),
  CONSTRAINT version_has_exactly_one_body
    CHECK ((code IS NOT NULL) <> (rule_tree IS NOT NULL))
);

CREATE INDEX strategy_version_latest_idx
  ON research.strategy_version (strategy_id, version DESC);

-- Parameter schema: the mobile app renders its editor from this, and the
-- sweep engine reads the bounds from it rather than trusting user input.
CREATE TABLE research.strategy_parameter (
  strategy_version_id uuid NOT NULL REFERENCES research.strategy_version(id) ON DELETE CASCADE,
  key             varchar(48) NOT NULL,
  label           varchar(80) NOT NULL,
  data_type       varchar(16) NOT NULL,   -- int | float | bool | enum | instrument
  default_value   jsonb NOT NULL,
  min_value       numeric,
  max_value       numeric,
  step            numeric,
  enum_values     text[],
  is_sweepable    boolean NOT NULL DEFAULT true,
  description     text,
  display_order   smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (strategy_version_id, key),
  CONSTRAINT parameter_bounds_ordered
    CHECK (min_value IS NULL OR max_value IS NULL OR max_value >= min_value),
  CONSTRAINT parameter_enum_has_values
    CHECK (data_type <> 'enum' OR array_length(enum_values, 1) > 0)
);

-- ── Deployments: a version running against a portfolio ──────────────────────
CREATE TABLE research.deployment (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('dep'),
  strategy_version_id uuid NOT NULL REFERENCES research.strategy_version(id) ON DELETE RESTRICT,
  portfolio_id    uuid NOT NULL REFERENCES book.portfolio(id) ON DELETE CASCADE,
  mode            varchar(12) NOT NULL DEFAULT 'paper',   -- paper | live
  parameters      jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Capital and risk budget for this deployment specifically. The risk engine
  -- enforces these independently of the portfolio's own limits.
  allocated_capital reference.money NOT NULL,
  max_position_count integer,
  max_gross_exposure reference.ratio,
  max_daily_loss  reference.money,
  -- Signals can be auto-executed or queued for the user to approve. Live
  -- auto-execution is the one place where a strategy bug becomes a money bug,
  -- so it defaults off.
  auto_execute    boolean NOT NULL DEFAULT false,
  execution_algo  oms.execution_algo NOT NULL DEFAULT 'none',
  schedule_cron   varchar(64),
  is_active       boolean NOT NULL DEFAULT true,
  paused_at       timestamptz,
  paused_reason   text,
  last_run_at     timestamptz,
  next_run_at     timestamptz,
  consecutive_errors smallint NOT NULL DEFAULT 0,
  deployed_at     timestamptz NOT NULL DEFAULT now(),
  stopped_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deployment_live_requires_no_auto_execute_by_default
    CHECK (mode = 'paper' OR auto_execute IS NOT NULL),
  CONSTRAINT deployment_capital_positive CHECK (allocated_capital > 0)
);

CREATE INDEX deployment_portfolio_idx ON research.deployment (portfolio_id)
  WHERE is_active;
CREATE INDEX deployment_due_idx ON research.deployment (next_run_at)
  WHERE is_active AND paused_at IS NULL;
CREATE UNIQUE INDEX deployment_one_active_version_per_portfolio
  ON research.deployment (portfolio_id, strategy_version_id) WHERE is_active;

-- Close the forward reference from oms.order.strategy_id.
ALTER TABLE oms.order
  ADD CONSTRAINT order_strategy_fk
  FOREIGN KEY (strategy_id) REFERENCES research.strategy(id) ON DELETE SET NULL;
ALTER TABLE book.position
  ADD CONSTRAINT position_strategy_fk
  FOREIGN KEY (opened_by_strategy_id) REFERENCES research.strategy(id) ON DELETE SET NULL;

-- ── Signals ──────────────────────────────────────────────────────────────────
-- High volume (every deployment × every bar × every instrument), so a
-- hypertable with aggressive compression.
CREATE TABLE research.signal (
  ts              timestamptz NOT NULL,
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id   uuid NOT NULL,
  strategy_version_id uuid NOT NULL,
  instrument_id   uuid NOT NULL,
  action          research.signal_action NOT NULL,
  -- Strength and confidence are distinct: a strong signal the model is unsure
  -- about should size smaller than a weak one it is certain of.
  strength        reference.ratio,
  confidence      reference.ratio,
  target_weight   reference.weight,
  target_quantity reference.quantity,
  suggested_limit_price reference.price,
  stop_loss_price reference.price,
  take_profit_price reference.price,
  -- The feature vector that produced this signal. Essential for explaining a
  -- trade after the fact, and for debugging a strategy that went strange.
  feature_snapshot jsonb,
  rationale       text,
  -- Lifecycle: a signal may be superseded before it is ever acted on.
  expires_at      timestamptz,
  acted_on_at     timestamptz,
  order_id        uuid,
  suppressed_reason varchar(48),
  bar_ts          timestamptz NOT NULL,
  generated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT signal_confidence_bounds
    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1)
);

SELECT create_hypertable('research.signal', 'ts',
  partitioning_column => 'deployment_id',
  number_partitions   => 8,
  chunk_time_interval => INTERVAL '7 days',
  create_default_indexes => false);

CREATE UNIQUE INDEX signal_pk_idx ON research.signal (id, ts);
CREATE INDEX signal_deployment_ts_idx ON research.signal (deployment_id, ts DESC);
CREATE INDEX signal_instrument_ts_idx ON research.signal (instrument_id, ts DESC);
CREATE INDEX signal_pending_idx ON research.signal (deployment_id, ts DESC)
  WHERE acted_on_at IS NULL AND suppressed_reason IS NULL;

ALTER TABLE research.signal SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'deployment_id, instrument_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('research.signal', INTERVAL '30 days');

COMMENT ON COLUMN research.signal.feature_snapshot IS
  'The inputs the strategy actually saw. Without this, "why did it buy?" is unanswerable once the feature store is rebuilt.';

-- ── Deployment run log ──────────────────────────────────────────────────────
CREATE TABLE research.deployment_run (
  id              bigserial PRIMARY KEY,
  deployment_id   uuid NOT NULL REFERENCES research.deployment(id) ON DELETE CASCADE,
  run_kind        varchar(16) NOT NULL DEFAULT 'scheduled',  -- scheduled|manual|event
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz,
  status          varchar(16) NOT NULL DEFAULT 'running',
  bars_processed  integer NOT NULL DEFAULT 0,
  signals_emitted integer NOT NULL DEFAULT 0,
  orders_placed   integer NOT NULL DEFAULT 0,
  -- Features the run asked for but could not get. A run with missing data that
  -- traded anyway is a silent correctness failure, so this is surfaced.
  missing_features text[] NOT NULL DEFAULT '{}',
  error_class     varchar(48),
  error_message   text,
  duration_ms     integer,
  trace_id        varchar(32)
);

CREATE INDEX deployment_run_recent_idx
  ON research.deployment_run (deployment_id, started_at DESC);
CREATE INDEX deployment_run_failed_idx ON research.deployment_run (started_at DESC)
  WHERE status = 'failed';

-- ── Live performance attribution per deployment ─────────────────────────────
CREATE TABLE research.deployment_performance_daily (
  trade_date      date NOT NULL,
  deployment_id   uuid NOT NULL REFERENCES research.deployment(id) ON DELETE CASCADE,
  starting_equity reference.money NOT NULL,
  ending_equity   reference.money NOT NULL,
  return_net      reference.ratio,
  realized_pnl    reference.money NOT NULL DEFAULT 0,
  unrealized_pnl  reference.money NOT NULL DEFAULT 0,
  fees            reference.money NOT NULL DEFAULT 0,
  trades_count    integer NOT NULL DEFAULT 0,
  turnover        reference.ratio,
  gross_exposure  reference.ratio,
  net_exposure    reference.ratio,
  positions_count integer NOT NULL DEFAULT 0,
  -- Rolling statistics kept here so the mobile strategy card is a single row read.
  sharpe_30d      reference.ratio,
  sharpe_inception reference.ratio,
  max_drawdown_inception reference.ratio,
  hit_rate_30d    reference.ratio,
  PRIMARY KEY (trade_date, deployment_id)
);

SELECT platform.attach_touch_triggers('research');
