-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0006 · Fundamentals, estimates, events and macro series                   ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- The cardinal rule in this schema is point-in-time correctness. Every row
-- carries both the period it describes (period_end) and the moment it became
-- public (published_at / as_of). Research queries filter on the latter.
-- Filtering on period_end alone is lookahead bias, which is how a backtest
-- ends up with a Sharpe of 4.

CREATE TYPE fundamental.statement_type AS ENUM ('income', 'balance', 'cash_flow');
CREATE TYPE fundamental.fiscal_period  AS ENUM ('Q1', 'Q2', 'Q3', 'Q4', 'FY', 'H1', 'H2', 'TTM');
CREATE TYPE fundamental.restatement   AS ENUM ('original', 'restated', 'preliminary', 'amended');

-- ── Filings: the publication event that fundamentals hang off ────────────────
CREATE TABLE fundamental.filing (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  form_type     varchar(16) NOT NULL,     -- 10-K, 10-Q, 8-K, 20-F, 6-K…
  fiscal_year   smallint NOT NULL,
  fiscal_period fundamental.fiscal_period NOT NULL,
  period_end    date NOT NULL,
  filed_at      timestamptz NOT NULL,
  accession_no  varchar(32),
  document_url  text,
  restatement   fundamental.restatement NOT NULL DEFAULT 'original',
  source        varchar(24) NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (instrument_id, form_type, fiscal_year, fiscal_period, restatement)
);

CREATE INDEX filing_instrument_filed_idx
  ON fundamental.filing (instrument_id, filed_at DESC);
CREATE INDEX filing_period_idx ON fundamental.filing (period_end DESC);

-- ── Line items ───────────────────────────────────────────────────────────────
-- Tall rather than wide: vendors disagree on which of ~400 possible line items
-- they populate, and a 400-column table would be mostly NULL. The standard
-- concept keys live in fundamental.metric_definition.
CREATE TABLE fundamental.metric_definition (
  key         varchar(48) PRIMARY KEY,
  statement   fundamental.statement_type,
  label       varchar(120) NOT NULL,
  unit        varchar(16) NOT NULL DEFAULT 'currency',  -- currency|shares|ratio|pct
  sign_convention smallint NOT NULL DEFAULT 1 CHECK (sign_convention IN (-1, 1)),
  is_derived  boolean NOT NULL DEFAULT false,
  formula     text,            -- documented derivation when is_derived
  description text
);

CREATE TABLE fundamental.statement_item (
  filing_id     uuid NOT NULL REFERENCES fundamental.filing(id) ON DELETE CASCADE,
  metric_key    varchar(48) NOT NULL REFERENCES fundamental.metric_definition(key),
  value         numeric(28, 6),
  currency      reference.currency_code REFERENCES reference.currency(code),
  PRIMARY KEY (filing_id, metric_key)
);

-- ── Derived ratio snapshots (the shape research actually queries) ────────────
-- Recomputed when a filing lands. Wide here is correct: these are dense and
-- every cross-sectional factor query selects dozens of them at once.
CREATE TABLE fundamental.company_snapshot (
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  as_of           date NOT NULL,          -- the date this became knowable
  filing_id       uuid REFERENCES fundamental.filing(id) ON DELETE SET NULL,
  period_end      date NOT NULL,
  -- Size / value
  market_cap      reference.money,
  enterprise_value reference.money,
  pe_ratio         reference.ratio,
  forward_pe       reference.ratio,
  pb_ratio         reference.ratio,
  ps_ratio         reference.ratio,
  ev_ebitda        reference.ratio,
  ev_sales         reference.ratio,
  fcf_yield        reference.ratio,
  earnings_yield   reference.ratio,
  dividend_yield   reference.ratio,
  payout_ratio     reference.ratio,
  -- Quality / profitability
  gross_margin     reference.ratio,
  operating_margin reference.ratio,
  net_margin       reference.ratio,
  roe              reference.ratio,
  roa              reference.ratio,
  roic             reference.ratio,
  asset_turnover   reference.ratio,
  accruals_ratio   reference.ratio,
  -- Leverage / solvency
  debt_to_equity   reference.ratio,
  net_debt_ebitda  reference.ratio,
  current_ratio    reference.ratio,
  quick_ratio      reference.ratio,
  interest_coverage reference.ratio,
  -- Growth (YoY)
  revenue_growth   reference.ratio,
  earnings_growth  reference.ratio,
  fcf_growth       reference.ratio,
  -- Composite scores computed by the quant engine's factor pipeline
  piotroski_f_score smallint CHECK (piotroski_f_score BETWEEN 0 AND 9),
  altman_z_score    reference.ratio,
  beneish_m_score   reference.ratio,
  ohlson_o_score    reference.ratio,
  quality_score     reference.ratio,
  value_score       reference.ratio,
  shares_outstanding reference.quantity,
  shares_diluted     reference.quantity,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instrument_id, as_of)
);

SELECT create_hypertable(
  'fundamental.company_snapshot', 'as_of',
  chunk_time_interval => INTERVAL '90 days',
  migrate_data => true
);

CREATE INDEX company_snapshot_asof_idx ON fundamental.company_snapshot (as_of DESC);
CREATE INDEX company_snapshot_value_idx
  ON fundamental.company_snapshot (as_of DESC, pe_ratio)
  WHERE pe_ratio IS NOT NULL AND pe_ratio > 0;

COMMENT ON COLUMN fundamental.company_snapshot.as_of IS
  'Date this snapshot became knowable to the market (filing date + vendor lag), NOT the period end. Research must filter on this column.';

-- ── Analyst estimates and revisions ─────────────────────────────────────────
CREATE TABLE fundamental.estimate (
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  as_of         date NOT NULL,
  fiscal_year   smallint NOT NULL,
  fiscal_period fundamental.fiscal_period NOT NULL,
  metric_key    varchar(48) NOT NULL REFERENCES fundamental.metric_definition(key),
  mean_estimate numeric(28, 6),
  median_estimate numeric(28, 6),
  high_estimate numeric(28, 6),
  low_estimate  numeric(28, 6),
  std_dev       numeric(28, 6),
  analyst_count smallint,
  -- Revision momentum is a well-documented factor; storing the 30/90d deltas
  -- avoids recomputing window functions over the whole estimate history.
  revision_30d  reference.ratio,
  revision_90d  reference.ratio,
  PRIMARY KEY (instrument_id, as_of, fiscal_year, fiscal_period, metric_key)
);

CREATE INDEX estimate_revision_idx ON fundamental.estimate (as_of DESC, revision_30d)
  WHERE revision_30d IS NOT NULL;

-- ── Corporate events calendar ───────────────────────────────────────────────
CREATE TYPE fundamental.event_type AS ENUM (
  'earnings', 'guidance', 'dividend_declaration', 'investor_day',
  'shareholder_meeting', 'product_launch', 'fda_decision', 'index_rebalance',
  'lockup_expiry', 'secondary_offering'
);

CREATE TABLE fundamental.corporate_event (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  event_type    fundamental.event_type NOT NULL,
  scheduled_at  timestamptz NOT NULL,
  -- Earnings timing is a material feature: BMO vs AMC changes which session
  -- the reaction lands in.
  timing_hint   varchar(16),      -- bmo | amc | during | unspecified
  is_confirmed  boolean NOT NULL DEFAULT false,
  fiscal_year   smallint,
  fiscal_period fundamental.fiscal_period,
  -- Outcome, filled in after the event
  eps_estimate  numeric(18, 6),
  eps_actual    numeric(18, 6),
  eps_surprise_pct reference.ratio,
  revenue_estimate reference.money,
  revenue_actual   reference.money,
  revenue_surprise_pct reference.ratio,
  price_reaction_pct   reference.ratio,     -- next-session close-to-close
  implied_move_pct     reference.ratio,     -- from the options straddle pre-event
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (instrument_id, event_type, scheduled_at)
);

-- now() is STABLE, not IMMUTABLE, so an "upcoming events" predicate is
-- illegal in an index. is_confirmed partitions the table usefully instead, and
-- the time bound is applied by the query planner against the ordered column.
CREATE INDEX corporate_event_upcoming_idx
  ON fundamental.corporate_event (scheduled_at, event_type)
  WHERE is_confirmed;
CREATE INDEX corporate_event_instrument_idx
  ON fundamental.corporate_event (instrument_id, scheduled_at DESC);

-- ── Short interest & ownership ───────────────────────────────────────────────
CREATE TABLE fundamental.short_interest (
  instrument_id     uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  settlement_date   date NOT NULL,
  published_at      date NOT NULL,      -- FINRA publishes with ~8 day lag
  shares_short      reference.quantity NOT NULL,
  shares_short_prior reference.quantity,
  days_to_cover     reference.ratio,
  pct_of_float      reference.ratio,
  borrow_fee_bps    reference.bps,
  utilization_pct   reference.ratio,
  PRIMARY KEY (instrument_id, settlement_date)
);

CREATE INDEX short_interest_published_idx
  ON fundamental.short_interest (published_at DESC);

CREATE TABLE fundamental.institutional_holding (
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  holder_cik    varchar(16) NOT NULL,
  holder_name   varchar(160) NOT NULL,
  report_date   date NOT NULL,        -- 13F quarter end
  published_at  date NOT NULL,        -- up to 45 days later
  shares        reference.quantity NOT NULL,
  shares_prior  reference.quantity,
  market_value  reference.money,
  pct_of_portfolio reference.ratio,
  PRIMARY KEY (instrument_id, holder_cik, report_date)
);

CREATE INDEX institutional_holding_holder_idx
  ON fundamental.institutional_holding (holder_cik, report_date DESC);

-- ── Macro series (FRED-shaped) ──────────────────────────────────────────────
CREATE TABLE fundamental.macro_series (
  id            smallserial PRIMARY KEY,
  code          varchar(32) UNIQUE NOT NULL,   -- DGS10, CPIAUCSL, VIXCLS…
  name          varchar(160) NOT NULL,
  source        varchar(24) NOT NULL,
  frequency     varchar(16) NOT NULL,          -- daily|weekly|monthly|quarterly
  unit          varchar(40),
  seasonal_adjustment varchar(24),
  -- Macro data is revised. release_lag_days lets research reconstruct what was
  -- knowable on a given date without a full vintage history.
  release_lag_days smallint NOT NULL DEFAULT 0,
  is_rate       boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE fundamental.macro_observation (
  series_id    smallint NOT NULL REFERENCES fundamental.macro_series(id) ON DELETE CASCADE,
  observed_on  date NOT NULL,       -- the period the value describes
  published_at date NOT NULL,       -- when it was first released
  value        numeric(28, 8),
  vintage      smallint NOT NULL DEFAULT 1,   -- 1 = first print, 2+ = revisions
  PRIMARY KEY (series_id, observed_on, vintage)
);

CREATE INDEX macro_observation_published_idx
  ON fundamental.macro_observation (series_id, published_at DESC);

-- First-print view: what a strategy could actually have traded on.
CREATE OR REPLACE VIEW fundamental.macro_first_print AS
SELECT series_id, observed_on, published_at, value
  FROM fundamental.macro_observation
 WHERE vintage = 1;

COMMENT ON VIEW fundamental.macro_first_print IS
  'Vintage-1 observations only. Backtests using revised macro data overstate performance because revisions incorporate information published later.';

SELECT platform.attach_touch_triggers('fundamental');
