-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0011 · Feature registry, point-in-time feature store, datasets            ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Postgres holds the *registry and manifest*; the values themselves live in
-- Parquet on object storage, because a feature matrix of 8k instruments ×
-- 60 features × 10y of daily bars is ~200M rows and columnar files are the
-- right tool. The hypertable here caches only the recent window that live
-- deployments read on every bar.
--
-- The non-negotiable property is point-in-time correctness: a feature value
-- carries both the bar it describes (ts) and the moment it could first be
-- computed (available_at). A read as of T must filter on available_at <= T.

CREATE TYPE research.feature_category AS ENUM (
  'trend', 'momentum', 'volatility', 'mean_reversion', 'volume', 'liquidity',
  'microstructure', 'fundamental', 'estimate', 'sentiment', 'macro',
  'seasonality', 'cross_sectional', 'regime', 'derived'
);

CREATE TABLE research.feature_definition (
  key             varchar(64) PRIMARY KEY,
  name            varchar(120) NOT NULL,
  category        research.feature_category NOT NULL,
  description     text NOT NULL,
  -- Declared contract. The engine builds exactly what a strategy asked for and
  -- refuses a request for an undeclared input.
  input_series    text[] NOT NULL DEFAULT '{}',   -- close, volume, bid, ask…
  parameters      jsonb NOT NULL DEFAULT '{}'::jsonb,
  lookback_bars   integer NOT NULL DEFAULT 0,
  -- Publication lag: how long after the bar closes the value is usable. Zero
  -- for price features; days for fundamentals; this is what makes an as-of
  -- read honest rather than approximately honest.
  availability_lag interval NOT NULL DEFAULT INTERVAL '0',
  is_causal       boolean NOT NULL DEFAULT true,
  is_cross_sectional boolean NOT NULL DEFAULT false,
  -- Cross-sectional features are only meaningful relative to a universe, so
  -- the definition must say which.
  universe_scope  varchar(48),
  output_type     varchar(16) NOT NULL DEFAULT 'float',
  valid_range_min numeric,
  valid_range_max numeric,
  implementation  varchar(120) NOT NULL,   -- python dotted path
  version         integer NOT NULL DEFAULT 1,
  deprecated_at   timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT feature_cross_sectional_needs_scope
    CHECK (NOT is_cross_sectional OR universe_scope IS NOT NULL),
  CONSTRAINT feature_range_ordered
    CHECK (valid_range_min IS NULL OR valid_range_max IS NULL
           OR valid_range_max >= valid_range_min)
);

CREATE INDEX feature_definition_category_idx
  ON research.feature_definition (category) WHERE deprecated_at IS NULL;

COMMENT ON COLUMN research.feature_definition.is_causal IS
  'False marks a feature that uses future information — permitted only for labels and diagnostics, never as a model input. The backtest engine refuses a non-causal feature in a strategy''s required_features.';

-- Dependencies between features, so a rebuild orders itself correctly and a
-- change to one feature can find everything downstream of it.
CREATE TABLE research.feature_dependency (
  feature_key     varchar(64) NOT NULL REFERENCES research.feature_definition(key) ON DELETE CASCADE,
  depends_on_key  varchar(64) NOT NULL REFERENCES research.feature_definition(key) ON DELETE RESTRICT,
  PRIMARY KEY (feature_key, depends_on_key),
  CONSTRAINT feature_no_self_dependency CHECK (feature_key <> depends_on_key)
);

-- ── Feature sets: a named bundle a strategy or model consumes ───────────────
CREATE TABLE research.feature_set (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            varchar(64) UNIQUE NOT NULL,
  name            varchar(120) NOT NULL,
  description     text,
  feature_keys    text[] NOT NULL,
  -- Normalisation must be fitted on training data only; storing the choice
  -- here means the same transform is applied at inference.
  normalization   varchar(24) NOT NULL DEFAULT 'none',  -- none|zscore|rank|quantile
  winsorize_pct   reference.ratio,
  fill_method     varchar(16) NOT NULL DEFAULT 'none',  -- none|ffill|zero|median
  created_by      uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT feature_set_not_empty CHECK (array_length(feature_keys, 1) > 0)
);

-- ── Recent-window value cache (hypertable) ─────────────────────────────────
-- Only the trailing window live deployments need. The historical archive is
-- Parquet; see research.feature_partition.
CREATE TABLE research.feature_value (
  ts              timestamptz NOT NULL,       -- the bar this describes
  instrument_id   uuid NOT NULL,
  feature_key     varchar(64) NOT NULL,
  value           double precision,
  -- Statistical features are computed in float64 deliberately: these are
  -- z-scores and ratios over returns, not ledger amounts.
  available_at    timestamptz NOT NULL,
  universe_id     varchar(48),                -- set for cross-sectional features
  quality         reference.data_quality NOT NULL DEFAULT 'derived',
  computed_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT feature_available_after_bar CHECK (available_at >= ts)
);

SELECT create_hypertable('research.feature_value', 'ts',
  partitioning_column => 'instrument_id',
  number_partitions   => 16,
  chunk_time_interval => INTERVAL '7 days',
  create_default_indexes => false);

CREATE UNIQUE INDEX feature_value_pk_idx
  ON research.feature_value (instrument_id, feature_key, ts);
-- The as-of read path: "every feature for this instrument knowable at T".
CREATE INDEX feature_value_asof_idx
  ON research.feature_value (instrument_id, available_at DESC, feature_key);
CREATE INDEX feature_value_key_ts_idx
  ON research.feature_value (feature_key, ts DESC);

ALTER TABLE research.feature_value SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'instrument_id, feature_key',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('research.feature_value', INTERVAL '3 days');
SELECT add_retention_policy('research.feature_value', INTERVAL '400 days');

COMMENT ON TABLE research.feature_value IS
  'Trailing-window cache only. Retention is deliberately short: the Parquet store in research.feature_partition is the archive, and keeping two full copies invites them to disagree.';

-- Point-in-time read. Research and live inference must both go through this,
-- so the two cannot drift apart in what they consider knowable.
CREATE OR REPLACE FUNCTION research.features_as_of(
  p_instrument_id uuid,
  p_as_of         timestamptz,
  p_feature_keys  text[] DEFAULT NULL
) RETURNS TABLE (feature_key varchar(64), value double precision, ts timestamptz)
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT DISTINCT ON (f.feature_key) f.feature_key, f.value, f.ts
    FROM research.feature_value f
   WHERE f.instrument_id = p_instrument_id
     AND f.available_at <= p_as_of
     AND (p_feature_keys IS NULL OR f.feature_key = ANY(p_feature_keys))
   ORDER BY f.feature_key, f.available_at DESC, f.ts DESC
$$;

COMMENT ON FUNCTION research.features_as_of IS
  'The only sanctioned feature read. Filters on available_at, not ts — a value computed from a bar is not knowable at that bar''s timestamp if it carries a publication lag.';

-- ── Parquet archive manifest ───────────────────────────────────────────────
CREATE TABLE research.feature_partition (
  id              bigserial PRIMARY KEY,
  feature_set_id  uuid REFERENCES research.feature_set(id) ON DELETE CASCADE,
  partition_date  date NOT NULL,
  universe_id     varchar(48) NOT NULL,
  object_uri      text NOT NULL,          -- s3://helios-feature-store/...
  row_count       bigint NOT NULL,
  byte_size       bigint NOT NULL,
  -- Content hash lets a reader verify it got the file the manifest described,
  -- and lets a rebuild skip partitions whose inputs did not change.
  content_hash    char(64) NOT NULL,
  feature_keys    text[] NOT NULL,
  min_available_at timestamptz NOT NULL,
  max_available_at timestamptz NOT NULL,
  build_version   varchar(24) NOT NULL,
  built_at        timestamptz NOT NULL DEFAULT now(),
  superseded_by   bigint REFERENCES research.feature_partition(id),
  UNIQUE (feature_set_id, partition_date, universe_id, build_version)
);

CREATE INDEX feature_partition_current_idx
  ON research.feature_partition (feature_set_id, partition_date DESC)
  WHERE superseded_by IS NULL;

-- ── Build runs, so a bad feature build is traceable ────────────────────────
CREATE TABLE research.feature_build (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_set_id  uuid REFERENCES research.feature_set(id) ON DELETE CASCADE,
  build_version   varchar(24) NOT NULL,
  start_date      date NOT NULL,
  end_date        date NOT NULL,
  universe_id     varchar(48) NOT NULL,
  status          research.backtest_status NOT NULL DEFAULT 'queued',
  partitions_written integer NOT NULL DEFAULT 0,
  rows_written    bigint NOT NULL DEFAULT 0,
  -- Data-quality outcome of the build. A build that silently produced 40% NaNs
  -- is worse than one that failed.
  null_rate       reference.ratio,
  outlier_rate    reference.ratio,
  instruments_skipped integer NOT NULL DEFAULT 0,
  skip_reasons    jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message   text,
  trace_id        varchar(32),
  started_at      timestamptz,
  finished_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX feature_build_recent_idx
  ON research.feature_build (feature_set_id, created_at DESC);

-- ── Labels (supervised targets), kept separate from features on purpose ────
-- Mixing labels into the feature table is how a forward return ends up as a
-- model input. Different table, different access path, explicit horizon.
CREATE TABLE research.label_definition (
  key             varchar(64) PRIMARY KEY,
  name            varchar(120) NOT NULL,
  description     text NOT NULL,
  horizon_bars    integer NOT NULL,
  label_type      varchar(24) NOT NULL,    -- forward_return|triple_barrier|classification
  parameters      jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Labels overlap in time when the horizon exceeds the sampling interval,
  -- which is exactly when purged CV with an embargo becomes mandatory.
  -- Named labels_overlap rather than "overlaps": OVERLAPS is a SQL operator
  -- keyword and an unquoted column of that name is a syntax error.
  labels_overlap  boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT label_horizon_positive CHECK (horizon_bars > 0)
);

COMMENT ON TABLE research.label_definition IS
  'Targets, deliberately not in research.feature_definition. A label is computed from the future by construction; letting it share a namespace with model inputs is how lookahead gets shipped.';

CREATE TABLE research.dataset (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            varchar(64) UNIQUE NOT NULL,
  name            varchar(120) NOT NULL,
  feature_set_id  uuid NOT NULL REFERENCES research.feature_set(id) ON DELETE RESTRICT,
  label_key       varchar(64) REFERENCES research.label_definition(key),
  universe_id     varchar(48) NOT NULL,
  start_date      date NOT NULL,
  end_date        date NOT NULL,
  -- Splits are stored, not computed at train time, so two runs of the same
  -- experiment see the same split.
  train_end       date NOT NULL,
  validation_end  date,
  embargo_days    integer NOT NULL DEFAULT 0,
  row_count       bigint,
  object_uri      text,
  content_hash    char(64),
  created_by      uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dataset_splits_ordered CHECK (
    train_end > start_date
    AND (validation_end IS NULL OR validation_end > train_end)
    AND end_date > coalesce(validation_end, train_end)
  )
);

SELECT platform.attach_touch_triggers('research');
