-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0003 · Reference data: venues, calendars, instruments, corporate actions  ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Every price, position and order points at reference.instrument. Symbols are
-- *not* keys: tickers are reused after delistings, so the instrument uuid is
-- the only stable identity and reference.instrument_symbol carries the
-- effective-dated mapping.

-- ── Currencies ───────────────────────────────────────────────────────────────
CREATE TABLE reference.currency (
  code          reference.currency_code PRIMARY KEY,
  name          varchar(64) NOT NULL,
  minor_units   smallint NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 18),
  symbol        varchar(8),
  is_crypto     boolean NOT NULL DEFAULT false,
  is_tradeable  boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- ── Venues / exchanges ───────────────────────────────────────────────────────
CREATE TYPE reference.venue_kind AS ENUM (
  'exchange', 'mtf', 'ats', 'dark_pool', 'ecn', 'otc', 'crypto_cex', 'crypto_dex'
);

CREATE TABLE reference.venue (
  id              smallserial PRIMARY KEY,
  mic             char(4) UNIQUE,                  -- ISO 10383; null for crypto
  code            varchar(24) UNIQUE NOT NULL,      -- internal: XNAS, BINANCE…
  name            varchar(120) NOT NULL,
  kind            reference.venue_kind NOT NULL,
  country_code    char(2),
  timezone        text NOT NULL,
  currency        reference.currency_code NOT NULL REFERENCES reference.currency(code),
  website         text,
  -- Microstructure facts the execution model needs.
  tick_size_regime jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{max_price, tick}]
  lot_size        integer NOT NULL DEFAULT 1,
  supports_odd_lots boolean NOT NULL DEFAULT true,
  maker_fee_bps   reference.bps NOT NULL DEFAULT 0,
  taker_fee_bps   reference.bps NOT NULL DEFAULT 0,
  settlement_days smallint NOT NULL DEFAULT 1,      -- T+1 for US equities since 2024
  has_pre_market  boolean NOT NULL DEFAULT false,
  has_post_market boolean NOT NULL DEFAULT false,
  is_24h          boolean NOT NULL DEFAULT false,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN reference.venue.tick_size_regime IS
  'Ordered price bands, e.g. [{"max_price":1,"tick":0.0001},{"max_price":null,"tick":0.01}]. Used to validate limit prices before routing.';

-- ── Trading calendars ────────────────────────────────────────────────────────
-- Regular weekly schedule, then explicit holiday/half-day overrides. The
-- session table is generated from these for a rolling ±3y window so that
-- "is the market open at t?" is an index lookup, not a computation.
CREATE TABLE reference.calendar (
  id          smallserial PRIMARY KEY,
  code        varchar(24) UNIQUE NOT NULL,     -- NYSE, NASDAQ, CME, 24x7…
  name        varchar(80) NOT NULL,
  timezone    text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE reference.calendar_weekly_schedule (
  calendar_id      smallint NOT NULL REFERENCES reference.calendar(id) ON DELETE CASCADE,
  day_of_week      smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0=Sunday
  pre_market_open  time,
  regular_open     time NOT NULL,
  regular_close    time NOT NULL,
  post_market_close time,
  PRIMARY KEY (calendar_id, day_of_week),
  CONSTRAINT weekly_regular_order CHECK (regular_close > regular_open)
);

CREATE TABLE reference.calendar_exception (
  calendar_id   smallint NOT NULL REFERENCES reference.calendar(id) ON DELETE CASCADE,
  exception_date date NOT NULL,
  is_closed     boolean NOT NULL DEFAULT true,
  regular_open  time,
  regular_close time,
  label         varchar(80) NOT NULL,
  PRIMARY KEY (calendar_id, exception_date),
  CONSTRAINT exception_times_when_open
    CHECK (is_closed OR (regular_open IS NOT NULL AND regular_close IS NOT NULL))
);

CREATE TABLE reference.trading_session (
  calendar_id     smallint NOT NULL REFERENCES reference.calendar(id) ON DELETE CASCADE,
  session_date    date NOT NULL,
  pre_market      tstzrange,
  regular         tstzrange NOT NULL,
  post_market     tstzrange,
  is_half_day     boolean NOT NULL DEFAULT false,
  PRIMARY KEY (calendar_id, session_date),
  -- Two regular sessions on the same calendar can never overlap.
  CONSTRAINT session_regular_no_overlap
    EXCLUDE USING gist (calendar_id WITH =, regular WITH &&)
);

CREATE INDEX trading_session_regular_idx
  ON reference.trading_session USING gist (regular);

-- "Is venue X open at time t?" — used by the order gate and the bar aggregator.
CREATE OR REPLACE FUNCTION reference.is_market_open(
  p_calendar_id smallint,
  p_at timestamptz,
  p_include_extended boolean DEFAULT false
) RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT EXISTS (
    SELECT 1 FROM reference.trading_session s
     WHERE s.calendar_id = p_calendar_id
       AND (s.regular @> p_at
            OR (p_include_extended AND (s.pre_market @> p_at OR s.post_market @> p_at)))
  )
$$;

-- ── Sector taxonomy (GICS-shaped) ────────────────────────────────────────────
CREATE TABLE reference.sector (
  id            smallserial PRIMARY KEY,
  gics_code     varchar(8) UNIQUE NOT NULL,
  level         smallint NOT NULL CHECK (level BETWEEN 1 AND 4),  -- sector→sub-industry
  name          varchar(80) NOT NULL,
  parent_id     smallint REFERENCES reference.sector(id),
  CONSTRAINT sector_level1_has_no_parent CHECK ((level = 1) = (parent_id IS NULL))
);

-- ── Instruments ──────────────────────────────────────────────────────────────
CREATE TYPE reference.instrument_status AS ENUM (
  'active', 'halted', 'suspended', 'delisted', 'pre_listing', 'expired'
);

CREATE TABLE reference.instrument (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id         text UNIQUE NOT NULL DEFAULT platform.public_id('ins'),
  symbol            reference.ticker NOT NULL,
  venue_id          smallint NOT NULL REFERENCES reference.venue(id),
  asset_class       reference.asset_class NOT NULL,
  name              varchar(200) NOT NULL,
  currency          reference.currency_code NOT NULL REFERENCES reference.currency(code),
  calendar_id       smallint NOT NULL REFERENCES reference.calendar(id),
  status            reference.instrument_status NOT NULL DEFAULT 'active',
  -- Cross-vendor identifiers. figi is our preferred join key for equities.
  figi              char(12),
  isin              char(12),
  cusip             char(9),
  sedol             char(7),
  ric               varchar(24),
  bloomberg_ticker  varchar(32),
  -- Classification
  sector_id         smallint REFERENCES reference.sector(id),
  country_code      char(2),
  -- Tradability / microstructure
  tick_size         reference.price,
  lot_size          reference.quantity NOT NULL DEFAULT 1,
  min_order_qty     reference.quantity NOT NULL DEFAULT 1,
  max_order_qty     reference.quantity,
  multiplier        reference.ratio NOT NULL DEFAULT 1,   -- 100 for equity options
  is_shortable      boolean NOT NULL DEFAULT false,
  is_marginable     boolean NOT NULL DEFAULT false,
  is_fractionable   boolean NOT NULL DEFAULT false,
  maintenance_margin_rate reference.ratio,
  short_borrow_rate_bps   reference.bps,
  -- Liquidity snapshot, refreshed nightly; feeds universe selection and the
  -- slippage model's participation cap.
  adv_30d           reference.quantity,
  median_spread_bps reference.bps,
  market_cap        reference.money,
  free_float_shares reference.quantity,
  listed_on         date,
  delisted_on       date,
  first_trade_date  date,
  data_start_date   date,             -- earliest bar we hold
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT instrument_symbol_venue_unique_when_listed
    EXCLUDE (symbol WITH =, venue_id WITH =) WHERE (delisted_on IS NULL),
  CONSTRAINT instrument_delist_after_list
    CHECK (delisted_on IS NULL OR listed_on IS NULL OR delisted_on >= listed_on),
  CONSTRAINT instrument_multiplier_positive CHECK (multiplier > 0),
  CONSTRAINT instrument_qty_bounds
    CHECK (max_order_qty IS NULL OR max_order_qty >= min_order_qty)
);

CREATE INDEX instrument_symbol_idx      ON reference.instrument (symbol);
CREATE INDEX instrument_asset_class_idx ON reference.instrument (asset_class, status);
CREATE INDEX instrument_venue_idx       ON reference.instrument (venue_id) WHERE status = 'active';
CREATE INDEX instrument_figi_idx        ON reference.instrument (figi) WHERE figi IS NOT NULL;
CREATE INDEX instrument_isin_idx        ON reference.instrument (isin) WHERE isin IS NOT NULL;
CREATE INDEX instrument_sector_idx      ON reference.instrument (sector_id) WHERE sector_id IS NOT NULL;
CREATE INDEX instrument_liquidity_idx   ON reference.instrument (adv_30d DESC NULLS LAST)
  WHERE status = 'active';
-- Fuzzy search: "appl", "apple inc", "AAPL" all have to work in the mobile search bar.
CREATE INDEX instrument_search_trgm_idx ON reference.instrument
  USING gin ((symbol || ' ' || name) gin_trgm_ops);

COMMENT ON TABLE reference.instrument IS
  'Canonical tradeable instrument. Never key off symbol — tickers are recycled after delisting.';

-- Effective-dated symbol history, so a 2015 backtest resolves 2015 tickers.
CREATE TABLE reference.instrument_symbol (
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  symbol        reference.ticker NOT NULL,
  valid_from    date NOT NULL,
  valid_to      date,
  reason        varchar(40),    -- rename, merger, reverse_split…
  PRIMARY KEY (instrument_id, symbol, valid_from),
  CONSTRAINT symbol_validity_ordered CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE INDEX instrument_symbol_lookup_idx
  ON reference.instrument_symbol (symbol, valid_from DESC);

-- Point-in-time symbol resolution. Backtests must call this, not instrument.symbol.
CREATE OR REPLACE FUNCTION reference.resolve_symbol(p_symbol text, p_as_of date)
  RETURNS uuid LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT s.instrument_id
    FROM reference.instrument_symbol s
   WHERE s.symbol = upper(p_symbol)
     AND s.valid_from <= p_as_of
     AND (s.valid_to IS NULL OR s.valid_to > p_as_of)
   ORDER BY s.valid_from DESC
   LIMIT 1
$$;

-- Vendor-specific ids, so ingestion can map a payload back to an instrument.
CREATE TABLE reference.instrument_vendor_map (
  vendor        varchar(24) NOT NULL,
  vendor_symbol varchar(64) NOT NULL,
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  vendor_payload jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (vendor, vendor_symbol)
);

CREATE INDEX instrument_vendor_map_instrument_idx
  ON reference.instrument_vendor_map (instrument_id);

-- ── Derivatives ──────────────────────────────────────────────────────────────
CREATE TYPE reference.option_type AS ENUM ('call', 'put');
CREATE TYPE reference.exercise_style AS ENUM ('american', 'european', 'bermudan');
CREATE TYPE reference.settlement_type AS ENUM ('physical', 'cash');

CREATE TABLE reference.option_contract (
  instrument_id     uuid PRIMARY KEY REFERENCES reference.instrument(id) ON DELETE CASCADE,
  underlying_id     uuid NOT NULL REFERENCES reference.instrument(id),
  option_type       reference.option_type NOT NULL,
  strike            reference.price NOT NULL,
  expiration_date   date NOT NULL,
  exercise_style    reference.exercise_style NOT NULL DEFAULT 'american',
  settlement        reference.settlement_type NOT NULL DEFAULT 'physical',
  contract_size     reference.quantity NOT NULL DEFAULT 100,
  occ_symbol        varchar(24),
  is_weekly         boolean NOT NULL DEFAULT false,
  is_mini           boolean NOT NULL DEFAULT false,
  -- Denormalised for chain queries; maintained by the ingestor.
  open_interest     bigint,
  open_interest_date date,
  UNIQUE (underlying_id, option_type, strike, expiration_date)
);

CREATE INDEX option_chain_idx
  ON reference.option_contract (underlying_id, expiration_date, strike)
  INCLUDE (option_type);
-- No partial predicate: CURRENT_DATE is not IMMUTABLE, so "only unexpired
-- contracts" cannot be expressed in an index WHERE clause. Range scans on the
-- full index are cheap here because expired contracts sort to one end.
CREATE INDEX option_expiry_idx ON reference.option_contract (expiration_date);

CREATE TABLE reference.future_contract (
  instrument_id    uuid PRIMARY KEY REFERENCES reference.instrument(id) ON DELETE CASCADE,
  root_symbol      varchar(8) NOT NULL,
  underlying_id    uuid REFERENCES reference.instrument(id),
  contract_month   date NOT NULL,
  first_trade_date date,
  last_trade_date  date NOT NULL,
  first_notice_date date,
  settlement       reference.settlement_type NOT NULL DEFAULT 'physical',
  contract_size    reference.quantity NOT NULL,
  price_unit       varchar(24),
  -- Continuous-contract construction needs explicit roll rules.
  roll_rule        varchar(24) NOT NULL DEFAULT 'open_interest',
  roll_offset_days smallint NOT NULL DEFAULT 0,
  UNIQUE (root_symbol, contract_month)
);

CREATE INDEX future_root_expiry_idx
  ON reference.future_contract (root_symbol, last_trade_date);

-- ── Index membership (point-in-time, for universe construction) ───────────────
CREATE TABLE reference.index_constituent (
  index_id      uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  valid_from    date NOT NULL,
  valid_to      date,
  weight        reference.weight,
  shares        reference.quantity,
  PRIMARY KEY (index_id, instrument_id, valid_from)
);

CREATE INDEX index_constituent_asof_idx
  ON reference.index_constituent (index_id, valid_from DESC, valid_to);

COMMENT ON TABLE reference.index_constituent IS
  'Point-in-time index membership. Survivorship bias in backtests is an engineering bug, not a statistics problem — always filter by valid_from/valid_to.';

-- ── Corporate actions ────────────────────────────────────────────────────────
CREATE TYPE reference.corporate_action_type AS ENUM (
  'cash_dividend', 'special_dividend', 'stock_dividend', 'split', 'reverse_split',
  'spinoff', 'merger', 'acquisition', 'rights_issue', 'ticker_change',
  'delisting', 'bankruptcy', 'return_of_capital'
);

CREATE TABLE reference.corporate_action (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  action_type     reference.corporate_action_type NOT NULL,
  announced_date  date,
  ex_date         date NOT NULL,
  record_date     date,
  payable_date    date,
  -- Adjustment factors. A 2:1 split has split_ratio 2 and price_factor 0.5.
  split_ratio     reference.ratio,
  price_factor    reference.ratio NOT NULL DEFAULT 1,
  volume_factor   reference.ratio NOT NULL DEFAULT 1,
  cash_amount     reference.money,
  cash_currency   reference.currency_code REFERENCES reference.currency(code),
  target_instrument_id uuid REFERENCES reference.instrument(id),  -- merger/spinoff
  notes           text,
  source          varchar(24) NOT NULL,
  quality         reference.data_quality NOT NULL DEFAULT 'vendor',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (instrument_id, action_type, ex_date),
  CONSTRAINT ca_factors_positive CHECK (price_factor > 0 AND volume_factor > 0),
  CONSTRAINT ca_cash_requires_currency
    CHECK (cash_amount IS NULL OR cash_currency IS NOT NULL)
);

CREATE INDEX corporate_action_ex_date_idx
  ON reference.corporate_action (instrument_id, ex_date DESC);

-- Cumulative back-adjustment factor for a date range; the single source of
-- truth for adjusted prices. Bars are stored raw and adjusted on read.
CREATE OR REPLACE FUNCTION reference.adjustment_factor(
  p_instrument_id uuid, p_from date, p_to date DEFAULT CURRENT_DATE
) RETURNS numeric LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT coalesce(exp(sum(ln(price_factor))), 1)
    FROM reference.corporate_action
   WHERE instrument_id = p_instrument_id
     AND ex_date > p_from
     AND ex_date <= p_to
     AND price_factor <> 1
$$;

COMMENT ON FUNCTION reference.adjustment_factor IS
  'Product of price factors over (from, to]. Summed in log space to avoid numeric drift over long histories.';

-- ── Halts (affects order gating and backtest realism) ────────────────────────
CREATE TABLE reference.trading_halt (
  id            bigserial PRIMARY KEY,
  instrument_id uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  halt_code     varchar(16) NOT NULL,     -- LUDP, T1, H10, M1…
  reason        text,
  halted_at     timestamptz NOT NULL,
  resumed_at    timestamptz,
  CONSTRAINT halt_resume_after_halt CHECK (resumed_at IS NULL OR resumed_at > halted_at)
);

CREATE INDEX trading_halt_active_idx ON reference.trading_halt (instrument_id)
  WHERE resumed_at IS NULL;
CREATE INDEX trading_halt_time_idx ON reference.trading_halt (halted_at DESC);

SELECT platform.attach_touch_triggers('reference');
