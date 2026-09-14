-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0012 · Risk limits, pre-trade assessments, VaR, exposure, kill switch     ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- The pre-trade gate sits directly on the order path, so everything here is
-- shaped for a fast, explainable decision: limits are a small indexed set, and
-- an assessment stores *every rule evaluated* rather than a verdict — a
-- rejection has to be able to say which rule failed and by how much.

CREATE TYPE risk.limit_scope AS ENUM (
  'account', 'portfolio', 'deployment', 'instrument', 'sector', 'asset_class', 'desk'
);

CREATE TYPE risk.limit_kind AS ENUM (
  'max_position_notional', 'max_position_pct_equity', 'max_position_pct_adv',
  'max_gross_exposure', 'max_net_exposure', 'max_leverage',
  'max_concentration', 'max_sector_exposure', 'max_instrument_count',
  'max_daily_loss', 'max_weekly_loss', 'max_drawdown',
  'max_order_notional', 'max_orders_per_minute', 'max_daily_turnover',
  'min_liquidity_adv', 'max_var_95', 'max_portfolio_beta',
  'max_options_delta', 'max_options_vega', 'restricted_instrument'
);

CREATE TYPE risk.enforcement AS ENUM (
  'hard',     -- reject the order
  'soft',     -- warn, allow, record
  'advisory'  -- surface in the UI only
);

CREATE TYPE risk.decision AS ENUM ('approved', 'approved_with_warnings', 'rejected', 'error');

-- ── Limits ───────────────────────────────────────────────────────────────────
CREATE TABLE risk.limit_rule (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('lim'),
  scope           risk.limit_scope NOT NULL,
  -- Exactly one of these is set, matching the scope. Checked below rather than
  -- split across six tables, because the gate reads them all in one query.
  account_id      uuid REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE CASCADE,
  deployment_id   uuid REFERENCES research.deployment(id) ON DELETE CASCADE,
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE CASCADE,
  sector_id       smallint REFERENCES reference.sector(id) ON DELETE CASCADE,
  asset_class     reference.asset_class,

  kind            risk.limit_kind NOT NULL,
  enforcement     risk.enforcement NOT NULL DEFAULT 'hard',
  -- Threshold semantics depend on kind: a notional in base currency, a ratio,
  -- or a count. The unit is recorded so the UI can render it without a lookup
  -- table that will drift.
  threshold       numeric(28, 10) NOT NULL,
  unit            varchar(16) NOT NULL,      -- currency | ratio | count | bps
  -- Warning at a fraction of the limit, so a user sees a breach coming.
  warn_at_pct     reference.ratio NOT NULL DEFAULT 0.8,
  currency        reference.currency_code REFERENCES reference.currency(code),

  is_active       boolean NOT NULL DEFAULT true,
  effective_from  timestamptz NOT NULL DEFAULT now(),
  effective_to    timestamptz,
  -- Who set it and why. Limits get relaxed under pressure; the audit trail is
  -- the point.
  created_by      uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  reason          text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT limit_scope_target_matches CHECK (
    (scope = 'account'     AND account_id    IS NOT NULL) OR
    (scope = 'portfolio'   AND portfolio_id  IS NOT NULL) OR
    (scope = 'deployment'  AND deployment_id IS NOT NULL) OR
    (scope = 'instrument'  AND instrument_id IS NOT NULL) OR
    (scope = 'sector'      AND sector_id     IS NOT NULL) OR
    (scope = 'asset_class' AND asset_class   IS NOT NULL) OR
    (scope = 'desk')
  ),
  CONSTRAINT limit_threshold_nonneg CHECK (threshold >= 0),
  CONSTRAINT limit_warn_fraction CHECK (warn_at_pct > 0 AND warn_at_pct <= 1),
  CONSTRAINT limit_validity_ordered
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

-- The gate's read: all active limits for an account, in one index scan.
CREATE INDEX limit_rule_account_active_idx
  ON risk.limit_rule (account_id, kind)
  WHERE is_active AND effective_to IS NULL;
CREATE INDEX limit_rule_portfolio_active_idx
  ON risk.limit_rule (portfolio_id, kind)
  WHERE is_active AND effective_to IS NULL;
CREATE INDEX limit_rule_instrument_idx
  ON risk.limit_rule (instrument_id) WHERE is_active AND instrument_id IS NOT NULL;
-- One active limit of a given kind per target; two contradicting limits is a
-- configuration bug that should fail at write time, not at trade time.
CREATE UNIQUE INDEX limit_rule_unique_account_kind
  ON risk.limit_rule (account_id, kind) WHERE is_active AND scope = 'account';
CREATE UNIQUE INDEX limit_rule_unique_portfolio_kind
  ON risk.limit_rule (portfolio_id, kind) WHERE is_active AND scope = 'portfolio';

-- ── Pre-trade assessments ───────────────────────────────────────────────────
CREATE TABLE risk.assessment (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid REFERENCES oms.order(id) ON DELETE SET NULL,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE SET NULL,
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE SET NULL,
  decision        risk.decision NOT NULL,
  -- Requested trade, denormalised so the assessment stands alone in an audit.
  side            reference.side,
  quantity        reference.quantity,
  estimated_price reference.price,
  estimated_notional reference.money,
  -- Projected state if this order fills completely. The whole point of a
  -- pre-trade check is to evaluate the post-trade world.
  projected_gross_exposure reference.money,
  projected_net_exposure   reference.money,
  projected_leverage       reference.ratio,
  projected_buying_power   reference.money,
  projected_var_95         reference.money,
  rules_evaluated  smallint NOT NULL DEFAULT 0,
  rules_failed     smallint NOT NULL DEFAULT 0,
  rules_warned     smallint NOT NULL DEFAULT 0,
  -- Latency is a first-class concern here; this column feeds the SLO.
  evaluation_ms    integer,
  cache_hit        boolean,
  -- Set when the gate could not reach its inputs. Live accounts fail closed.
  degraded         boolean NOT NULL DEFAULT false,
  degraded_reason  text,
  trace_id         varchar(32),
  evaluated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT assessment_rejected_has_failures
    CHECK (decision <> 'rejected' OR rules_failed > 0 OR degraded)
);

CREATE INDEX assessment_order_idx ON risk.assessment (order_id)
  WHERE order_id IS NOT NULL;
CREATE INDEX assessment_account_time_idx
  ON risk.assessment (account_id, evaluated_at DESC);
CREATE INDEX assessment_rejected_idx ON risk.assessment (evaluated_at DESC)
  WHERE decision = 'rejected';
CREATE INDEX assessment_slow_idx ON risk.assessment (evaluation_ms DESC)
  WHERE evaluation_ms > 50;

-- Every rule the gate looked at, with its value and threshold. This is what
-- turns "rejected" into "rejected because gross exposure would reach 3.2x
-- against a 2.0x limit".
CREATE TABLE risk.assessment_rule_result (
  assessment_id   uuid NOT NULL REFERENCES risk.assessment(id) ON DELETE CASCADE,
  limit_rule_id   uuid REFERENCES risk.limit_rule(id) ON DELETE SET NULL,
  kind            risk.limit_kind NOT NULL,
  enforcement     risk.enforcement NOT NULL,
  passed          boolean NOT NULL,
  warned          boolean NOT NULL DEFAULT false,
  current_value   numeric(28, 10),
  projected_value numeric(28, 10),
  threshold       numeric(28, 10),
  utilization_pct reference.ratio,
  message         text,
  PRIMARY KEY (assessment_id, kind, limit_rule_id)
);

CREATE INDEX assessment_rule_failed_idx
  ON risk.assessment_rule_result (kind, passed) WHERE NOT passed;

COMMENT ON TABLE risk.assessment_rule_result IS
  'Every rule evaluated, not just the failing ones. A user asking "why was this rejected?" and a regulator asking "what did you check?" want the same rows.';

-- ── Breaches (a limit crossed by market movement, not by an order) ──────────
CREATE TABLE risk.breach (
  id              bigserial PRIMARY KEY,
  limit_rule_id   uuid REFERENCES risk.limit_rule(id) ON DELETE SET NULL,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE SET NULL,
  kind            risk.limit_kind NOT NULL,
  enforcement     risk.enforcement NOT NULL,
  observed_value  numeric(28, 10) NOT NULL,
  threshold       numeric(28, 10) NOT NULL,
  excess_pct      reference.ratio,
  -- A breach caused by a price move is a different operational event from one
  -- caused by a trade, and they get different responses.
  cause           varchar(24) NOT NULL DEFAULT 'market_move',
  triggering_order_id uuid REFERENCES oms.order(id) ON DELETE SET NULL,
  action_taken    varchar(32),    -- none | alert | block_new | liquidate | kill_switch
  opened_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  resolution      text,
  acknowledged_by uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  acknowledged_at timestamptz
);

CREATE INDEX breach_open_idx ON risk.breach (account_id, opened_at DESC)
  WHERE resolved_at IS NULL;
CREATE INDEX breach_unacked_idx ON risk.breach (opened_at)
  WHERE acknowledged_at IS NULL;

-- ── Kill switch ─────────────────────────────────────────────────────────────
-- Deliberately its own table rather than a boolean on the account: activation
-- must carry who, when, why and what scope, and must survive an account row
-- being updated by anything else.
CREATE TABLE risk.kill_switch (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope           risk.limit_scope NOT NULL,
  account_id      uuid REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE CASCADE,
  deployment_id   uuid REFERENCES research.deployment(id) ON DELETE CASCADE,
  -- What it actually does. Blocking new orders while leaving working orders
  -- alone is a very different decision from cancelling everything.
  blocks_new_orders boolean NOT NULL DEFAULT true,
  cancels_working_orders boolean NOT NULL DEFAULT false,
  liquidates_positions boolean NOT NULL DEFAULT false,
  reason          text NOT NULL,
  triggered_by_breach_id bigint REFERENCES risk.breach(id) ON DELETE SET NULL,
  activated_by    uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  activated_at    timestamptz NOT NULL DEFAULT now(),
  -- Release requires a distinct actor and reason; automatic expiry is not
  -- offered, because a switch that turns itself off is not a kill switch.
  released_by     uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  released_at     timestamptz,
  release_reason  text,
  CONSTRAINT kill_switch_release_has_reason
    CHECK (released_at IS NULL OR release_reason IS NOT NULL),
  CONSTRAINT kill_switch_scope_target CHECK (
    (scope = 'account'    AND account_id    IS NOT NULL) OR
    (scope = 'portfolio'  AND portfolio_id  IS NOT NULL) OR
    (scope = 'deployment' AND deployment_id IS NOT NULL) OR
    (scope = 'desk')
  )
);

CREATE UNIQUE INDEX kill_switch_active_account_idx
  ON risk.kill_switch (account_id) WHERE released_at IS NULL AND scope = 'account';
-- Unique on the scope value itself: with the partial predicate pinning scope
-- to 'desk', this admits at most one live desk-wide switch.
CREATE UNIQUE INDEX kill_switch_active_desk_idx
  ON risk.kill_switch (scope) WHERE released_at IS NULL AND scope = 'desk';
CREATE INDEX kill_switch_active_idx ON risk.kill_switch (scope)
  WHERE released_at IS NULL;

-- Single predicate the gate calls; covers desk-wide and account scopes.
CREATE OR REPLACE FUNCTION risk.is_trading_halted(
  p_account_id uuid, p_portfolio_id uuid DEFAULT NULL
) RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT EXISTS (
    SELECT 1 FROM risk.kill_switch k
     WHERE k.released_at IS NULL
       AND k.blocks_new_orders
       AND (k.scope = 'desk'
            OR k.account_id = p_account_id
            OR (p_portfolio_id IS NOT NULL AND k.portfolio_id = p_portfolio_id))
  )
  OR EXISTS (
    SELECT 1 FROM book.account a
     WHERE a.id = p_account_id AND (a.trading_blocked OR a.status IN ('closed','restricted'))
  )
$$;

-- ── Portfolio risk snapshots (hypertable) ──────────────────────────────────
CREATE TABLE risk.portfolio_snapshot (
  ts              timestamptz NOT NULL,
  account_id      uuid NOT NULL,
  portfolio_id    uuid,
  -- VaR at several horizons and methods; disagreement between methods is
  -- itself signal, so they are stored side by side rather than collapsed.
  var_95_1d_historical  reference.money,
  var_95_1d_parametric  reference.money,
  var_95_1d_montecarlo  reference.money,
  var_99_1d_historical  reference.money,
  var_95_10d_historical reference.money,
  expected_shortfall_95 reference.money,
  expected_shortfall_99 reference.money,
  -- Exposure
  gross_exposure  reference.money,
  net_exposure    reference.money,
  long_exposure   reference.money,
  short_exposure  reference.money,
  leverage        reference.ratio,
  beta_adjusted_net reference.money,
  portfolio_beta  reference.ratio,
  -- Concentration
  largest_position_pct reference.ratio,
  top5_concentration_pct reference.ratio,
  herfindahl_index reference.ratio,
  effective_positions reference.ratio,
  -- Options greeks, portfolio level
  total_delta     reference.ratio,
  total_gamma     reference.ratio,
  total_vega      reference.ratio,
  total_theta     reference.ratio,
  -- Realised risk
  volatility_30d  reference.ratio,
  correlation_to_spy reference.ratio,
  current_drawdown reference.ratio,
  -- Model provenance: a VaR number without its lookback and confidence is
  -- not comparable to another VaR number.
  lookback_days   smallint,
  computed_at     timestamptz NOT NULL DEFAULT now()
);

SELECT create_hypertable('risk.portfolio_snapshot', 'ts',
  chunk_time_interval => INTERVAL '30 days');

CREATE UNIQUE INDEX portfolio_snapshot_account_idx
  ON risk.portfolio_snapshot (account_id, ts DESC) WHERE portfolio_id IS NULL;
CREATE UNIQUE INDEX portfolio_snapshot_portfolio_idx
  ON risk.portfolio_snapshot (portfolio_id, ts DESC) WHERE portfolio_id IS NOT NULL;

ALTER TABLE risk.portfolio_snapshot SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'account_id, portfolio_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('risk.portfolio_snapshot', INTERVAL '90 days');

-- ── VaR model backtesting ───────────────────────────────────────────────────
-- A VaR model nobody backtests is decoration. Exceptions are counted and the
-- Kupiec / Christoffersen statistics recorded so a mis-calibrated model is
-- visible rather than merely wrong.
CREATE TABLE risk.var_backtest (
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  as_of           date NOT NULL,
  method          varchar(24) NOT NULL,
  confidence      reference.ratio NOT NULL,
  window_days     integer NOT NULL,
  observations    integer NOT NULL,
  exceptions      integer NOT NULL,
  expected_exceptions reference.ratio NOT NULL,
  kupiec_statistic reference.ratio,
  kupiec_p_value  reference.ratio,
  christoffersen_statistic reference.ratio,
  christoffersen_p_value reference.ratio,
  -- Basel-style traffic light, because it is the clearest way to say "this
  -- model is no longer trustworthy" to a non-specialist.
  traffic_light   varchar(8),        -- green | yellow | red
  computed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, as_of, method, confidence, window_days)
);

-- ── Factor exposures ────────────────────────────────────────────────────────
CREATE TABLE risk.factor_exposure (
  as_of           date NOT NULL,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE CASCADE,
  factor          varchar(32) NOT NULL,    -- market|size|value|momentum|quality|vol
  exposure        reference.ratio NOT NULL,
  contribution_to_risk reference.ratio,
  t_statistic     reference.ratio,
  r_squared       reference.ratio,
  PRIMARY KEY (as_of, account_id, portfolio_id, factor)
);

-- ── Stress scenarios ────────────────────────────────────────────────────────
CREATE TABLE risk.stress_scenario (
  id              smallserial PRIMARY KEY,
  key             varchar(48) UNIQUE NOT NULL,
  name            varchar(120) NOT NULL,
  description     text,
  kind            varchar(16) NOT NULL DEFAULT 'historical',  -- historical|parametric
  -- Historical scenarios replay a real window; parametric ones apply shocks.
  window_start    date,
  window_end      date,
  shocks          jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active       boolean NOT NULL DEFAULT true,
  CONSTRAINT scenario_historical_has_window
    CHECK (kind <> 'historical' OR (window_start IS NOT NULL AND window_end IS NOT NULL))
);

CREATE TABLE risk.stress_result (
  as_of           date NOT NULL,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE CASCADE,
  scenario_id     smallint NOT NULL REFERENCES risk.stress_scenario(id) ON DELETE CASCADE,
  pnl_impact      reference.money NOT NULL,
  pnl_impact_pct  reference.ratio NOT NULL,
  equity_after    reference.money,
  leverage_after  reference.ratio,
  margin_call     boolean NOT NULL DEFAULT false,
  worst_position_id uuid REFERENCES book.position(id) ON DELETE SET NULL,
  worst_position_impact reference.money,
  -- Options are fully revalued rather than delta-approximated; a scenario that
  -- linearises through a 30% move understates convexity exactly when it matters.
  revaluation_method varchar(16) NOT NULL DEFAULT 'full',
  computed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (as_of, account_id, portfolio_id, scenario_id)
);

SELECT platform.attach_touch_triggers('risk');
