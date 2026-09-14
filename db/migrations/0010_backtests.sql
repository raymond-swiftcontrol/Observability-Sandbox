-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0010 · Backtests, runs, trades, metrics, sweeps, walk-forward folds       ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- A backtest result is only meaningful alongside the assumptions that produced
-- it. Every run therefore records its fee model, slippage model, data range,
-- universe and sample designation as NOT NULL columns — a run that cannot say
-- how it modelled costs cannot be compared to one that can, and the social
-- layer refuses to share it.

CREATE TYPE research.backtest_status AS ENUM (
  'queued', 'preparing', 'running', 'completed', 'failed', 'cancelled', 'expired'
);

CREATE TYPE research.sample_designation AS ENUM (
  'in_sample', 'out_of_sample', 'walk_forward', 'paper_forward', 'live'
);

CREATE TYPE research.slippage_model AS ENUM (
  'none', 'fixed_bps', 'spread_proportional', 'square_root_impact', 'book_replay'
);

CREATE TABLE research.backtest (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id         text UNIQUE NOT NULL DEFAULT platform.public_id('bt'),
  strategy_version_id uuid NOT NULL REFERENCES research.strategy_version(id) ON DELETE CASCADE,
  requested_by      uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  name              varchar(120),
  status            research.backtest_status NOT NULL DEFAULT 'queued',

  -- ── Reproducibility envelope ─────────────────────────────────────────────
  -- Everything needed to re-run this and get the same numbers.
  parameters        jsonb NOT NULL DEFAULT '{}'::jsonb,
  universe_definition jsonb NOT NULL,
  start_date        date NOT NULL,
  end_date          date NOT NULL,
  bar_interval      reference.bar_interval NOT NULL,
  initial_capital   reference.money NOT NULL,
  base_currency     reference.currency_code NOT NULL DEFAULT 'USD',
  random_seed       bigint,
  engine            varchar(16) NOT NULL DEFAULT 'event',   -- event | vectorised
  engine_version    varchar(24) NOT NULL,
  data_snapshot_at  timestamptz NOT NULL DEFAULT now(),

  -- ── Cost assumptions: NOT NULL on purpose ────────────────────────────────
  commission_model  jsonb NOT NULL,
  slippage_model    research.slippage_model NOT NULL,
  slippage_params   jsonb NOT NULL DEFAULT '{}'::jsonb,
  borrow_cost_bps   reference.bps NOT NULL DEFAULT 0,
  financing_rate_bps reference.bps NOT NULL DEFAULT 0,
  -- Participation cap: the impact model is only credible if the backtest is
  -- forbidden from assuming it can trade an implausible share of the volume.
  max_participation_rate reference.ratio NOT NULL DEFAULT 0.1,
  allow_same_bar_fill boolean NOT NULL DEFAULT false,
  include_extended_hours boolean NOT NULL DEFAULT false,
  sample            research.sample_designation NOT NULL DEFAULT 'in_sample',

  -- ── Progress and provenance ──────────────────────────────────────────────
  progress_pct      smallint NOT NULL DEFAULT 0 CHECK (progress_pct BETWEEN 0 AND 100),
  bars_total        bigint,
  bars_processed    bigint NOT NULL DEFAULT 0,
  worker_id         varchar(64),
  trace_id          varchar(32),
  artifact_uri      text,          -- s3://helios-artifacts/backtests/<id>/
  error_class       varchar(48),
  error_message     text,
  queued_at         timestamptz NOT NULL DEFAULT now(),
  started_at        timestamptz,
  finished_at       timestamptz,
  duration_ms       integer,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT backtest_dates_ordered CHECK (end_date > start_date),
  CONSTRAINT backtest_capital_positive CHECK (initial_capital > 0),
  CONSTRAINT backtest_participation_bounded
    CHECK (max_participation_rate > 0 AND max_participation_rate <= 1),
  CONSTRAINT backtest_failed_has_reason
    CHECK (status <> 'failed' OR error_message IS NOT NULL)
);

CREATE INDEX backtest_strategy_idx
  ON research.backtest (strategy_version_id, created_at DESC);
CREATE INDEX backtest_user_idx ON research.backtest (requested_by, created_at DESC);
CREATE INDEX backtest_queue_idx ON research.backtest (queued_at)
  WHERE status IN ('queued', 'preparing');
CREATE INDEX backtest_running_idx ON research.backtest (started_at)
  WHERE status = 'running';

COMMENT ON COLUMN research.backtest.allow_same_bar_fill IS
  'Off by default. A signal computed from a bar''s close cannot be filled at that same close in reality; enabling this is a deliberate, recorded choice.';

-- ── Headline metrics (one row per backtest; wide is right here) ─────────────
CREATE TABLE research.backtest_metrics (
  backtest_id       uuid PRIMARY KEY REFERENCES research.backtest(id) ON DELETE CASCADE,
  -- Returns
  total_return      reference.ratio,
  cagr              reference.ratio,
  final_equity      reference.money,
  -- Risk
  volatility_annual reference.ratio,
  downside_deviation reference.ratio,
  max_drawdown      reference.ratio,
  max_drawdown_days integer,
  max_drawdown_start date,
  max_drawdown_end  date,
  recovery_days     integer,
  ulcer_index       reference.ratio,
  var_95            reference.ratio,
  cvar_95           reference.ratio,
  -- Risk-adjusted
  sharpe            reference.ratio,
  sortino           reference.ratio,
  calmar            reference.ratio,
  omega             reference.ratio,
  -- Overfitting-aware variants. A raw Sharpe from a parameter sweep is not a
  -- forecast; these are what the UI should lead with for swept results.
  probabilistic_sharpe reference.ratio,
  deflated_sharpe   reference.ratio,
  trials_count      integer,
  -- Benchmark relative
  benchmark_instrument_id uuid REFERENCES reference.instrument(id),
  alpha_annual      reference.ratio,
  beta              reference.ratio,
  information_ratio reference.ratio,
  tracking_error    reference.ratio,
  up_capture        reference.ratio,
  down_capture      reference.ratio,
  -- Trade statistics
  trades_count      integer NOT NULL DEFAULT 0,
  win_rate          reference.ratio,
  profit_factor     reference.ratio,
  expectancy        reference.money,
  payoff_ratio      reference.ratio,
  avg_win           reference.money,
  avg_loss          reference.money,
  largest_win       reference.money,
  largest_loss      reference.money,
  max_consecutive_losses integer,
  avg_holding_period_hours reference.ratio,
  -- Costs and exposure: a strategy whose gross edge is eaten by costs should
  -- be obvious at a glance, so both are stored rather than derived.
  gross_return      reference.ratio,
  total_commission  reference.money,
  total_slippage    reference.money,
  total_borrow_cost reference.money,
  turnover_annual   reference.ratio,
  avg_gross_exposure reference.ratio,
  avg_net_exposure  reference.ratio,
  max_leverage_used reference.ratio,
  time_in_market    reference.ratio,
  -- Distribution shape
  skewness          reference.ratio,
  kurtosis          reference.ratio,
  tail_ratio        reference.ratio,
  best_month        reference.ratio,
  worst_month       reference.ratio,
  positive_months   integer,
  computed_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX backtest_metrics_sharpe_idx
  ON research.backtest_metrics (deflated_sharpe DESC NULLS LAST);

-- ── Equity curve (hypertable: a 10-year 1m backtest is ~1M points) ─────────
CREATE TABLE research.backtest_equity (
  ts              timestamptz NOT NULL,
  backtest_id     uuid NOT NULL,
  equity          reference.money NOT NULL,
  cash            reference.money NOT NULL,
  positions_value reference.money NOT NULL DEFAULT 0,
  gross_exposure  reference.ratio,
  net_exposure    reference.ratio,
  leverage        reference.ratio,
  drawdown        reference.ratio,
  high_water_mark reference.money,
  positions_count integer NOT NULL DEFAULT 0,
  return_period   reference.ratio,
  benchmark_equity reference.money
);

SELECT create_hypertable('research.backtest_equity', 'ts',
  partitioning_column => 'backtest_id',
  number_partitions   => 8,
  chunk_time_interval => INTERVAL '365 days',
  create_default_indexes => false);

CREATE UNIQUE INDEX backtest_equity_pk_idx
  ON research.backtest_equity (backtest_id, ts);

ALTER TABLE research.backtest_equity SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'backtest_id',
  timescaledb.compress_orderby   = 'ts'
);
SELECT add_compression_policy('research.backtest_equity', INTERVAL '7 days');

-- ── Simulated trades ────────────────────────────────────────────────────────
CREATE TABLE research.backtest_trade (
  id              bigserial PRIMARY KEY,
  backtest_id     uuid NOT NULL REFERENCES research.backtest(id) ON DELETE CASCADE,
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id),
  side            reference.side NOT NULL,
  entry_ts        timestamptz NOT NULL,
  entry_price     reference.price NOT NULL,
  entry_reason    varchar(48),
  exit_ts         timestamptz,
  exit_price      reference.price,
  exit_reason     varchar(48),      -- signal | stop_loss | take_profit | eod | expiry
  quantity        reference.quantity NOT NULL,
  gross_pnl       reference.money,
  commission      reference.money NOT NULL DEFAULT 0,
  slippage_cost   reference.money NOT NULL DEFAULT 0,
  borrow_cost     reference.money NOT NULL DEFAULT 0,
  net_pnl         reference.money,
  return_pct      reference.ratio,
  holding_hours   reference.ratio,
  -- Maximum favourable/adverse excursion: the single most useful pair of
  -- numbers for diagnosing stop placement.
  mfe             reference.ratio,
  mae             reference.ratio,
  bars_held       integer,
  signal_strength reference.ratio,
  CONSTRAINT backtest_trade_exit_after_entry
    CHECK (exit_ts IS NULL OR exit_ts >= entry_ts)
);

CREATE INDEX backtest_trade_backtest_idx
  ON research.backtest_trade (backtest_id, entry_ts);
CREATE INDEX backtest_trade_instrument_idx
  ON research.backtest_trade (backtest_id, instrument_id);
CREATE INDEX backtest_trade_losers_idx
  ON research.backtest_trade (backtest_id, net_pnl)
  WHERE net_pnl < 0;

-- ── Parameter sweeps ────────────────────────────────────────────────────────
-- A sweep is the fastest way to overfit, so the schema makes the trial count
-- explicit and carries it into the deflated Sharpe calculation.
CREATE TABLE research.parameter_sweep (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('swp'),
  strategy_version_id uuid NOT NULL REFERENCES research.strategy_version(id) ON DELETE CASCADE,
  requested_by    uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  name            varchar(120),
  parameter_grid  jsonb NOT NULL,
  search_method   varchar(16) NOT NULL DEFAULT 'grid',  -- grid|random|bayesian
  objective       varchar(32) NOT NULL DEFAULT 'sharpe',
  total_trials    integer NOT NULL,
  completed_trials integer NOT NULL DEFAULT 0,
  failed_trials   integer NOT NULL DEFAULT 0,
  status          research.backtest_status NOT NULL DEFAULT 'queued',
  best_backtest_id uuid REFERENCES research.backtest(id) ON DELETE SET NULL,
  -- Reported alongside the winner, always. The best of 500 trials is a
  -- different claim from the best of 5.
  best_objective_value reference.ratio,
  deflated_best_sharpe reference.ratio,
  started_at      timestamptz,
  finished_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sweep_trials_positive CHECK (total_trials > 0)
);

CREATE TABLE research.sweep_trial (
  sweep_id        uuid NOT NULL REFERENCES research.parameter_sweep(id) ON DELETE CASCADE,
  trial_number    integer NOT NULL,
  backtest_id     uuid REFERENCES research.backtest(id) ON DELETE SET NULL,
  parameters      jsonb NOT NULL,
  objective_value reference.ratio,
  status          research.backtest_status NOT NULL DEFAULT 'queued',
  PRIMARY KEY (sweep_id, trial_number)
);

CREATE INDEX sweep_trial_objective_idx
  ON research.sweep_trial (sweep_id, objective_value DESC NULLS LAST);

-- ── Walk-forward validation ─────────────────────────────────────────────────
-- Folds are stored rather than derived so that a validation result can be
-- audited: which window trained, which tested, and what the embargo was.
CREATE TABLE research.walk_forward (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  strategy_version_id uuid NOT NULL REFERENCES research.strategy_version(id) ON DELETE CASCADE,
  method          varchar(24) NOT NULL DEFAULT 'rolling',  -- rolling|anchored|purged_kfold|cpcv
  train_days      integer NOT NULL,
  test_days       integer NOT NULL,
  step_days       integer NOT NULL,
  -- Embargo prevents label leakage across the split boundary when labels
  -- overlap in time; omitting it is a classic, invisible source of inflation.
  embargo_days    integer NOT NULL DEFAULT 0,
  folds_total     integer NOT NULL,
  status          research.backtest_status NOT NULL DEFAULT 'queued',
  -- Aggregate out-of-sample performance: the only number worth quoting.
  oos_sharpe      reference.ratio,
  oos_return      reference.ratio,
  oos_max_drawdown reference.ratio,
  is_oos_degradation reference.ratio,   -- (is_sharpe - oos_sharpe) / is_sharpe
  consistency_score reference.ratio,    -- share of folds with positive OOS return
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE research.walk_forward_fold (
  walk_forward_id uuid NOT NULL REFERENCES research.walk_forward(id) ON DELETE CASCADE,
  fold_number     integer NOT NULL,
  train_start     date NOT NULL,
  train_end       date NOT NULL,
  test_start      date NOT NULL,
  test_end        date NOT NULL,
  fitted_parameters jsonb,
  train_backtest_id uuid REFERENCES research.backtest(id) ON DELETE SET NULL,
  test_backtest_id  uuid REFERENCES research.backtest(id) ON DELETE SET NULL,
  train_sharpe    reference.ratio,
  test_sharpe     reference.ratio,
  test_return     reference.ratio,
  PRIMARY KEY (walk_forward_id, fold_number),
  CONSTRAINT fold_windows_ordered CHECK (
    train_end > train_start AND test_end > test_start AND test_start >= train_end
  )
);

COMMENT ON CONSTRAINT fold_windows_ordered ON research.walk_forward_fold IS
  'The test window must start at or after the train window ends. Overlap here is lookahead, and it is the most common way a walk-forward implementation is silently wrong.';

-- ── Monte-Carlo robustness ──────────────────────────────────────────────────
CREATE TABLE research.monte_carlo_result (
  backtest_id     uuid PRIMARY KEY REFERENCES research.backtest(id) ON DELETE CASCADE,
  method          varchar(24) NOT NULL DEFAULT 'trade_resample',
  iterations      integer NOT NULL,
  return_p05      reference.ratio,
  return_p25      reference.ratio,
  return_median   reference.ratio,
  return_p75      reference.ratio,
  return_p95      reference.ratio,
  max_drawdown_p95 reference.ratio,
  probability_of_loss reference.ratio,
  probability_of_ruin reference.ratio,
  computed_at     timestamptz NOT NULL DEFAULT now()
);

SELECT platform.attach_touch_triggers('research');
