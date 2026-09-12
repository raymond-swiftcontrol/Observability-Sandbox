-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0007 · Accounts, portfolios, positions, lots and the cash ledger          ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- The ledger is double-entry. Every balance in this schema is derivable by
-- summing book.ledger_entry; book.position and book.cash_balance are
-- maintained projections that exist for latency, and
-- book.assert_ledger_balanced() is the invariant that proves they agree.
-- When a projection and the ledger disagree, the ledger is right.

CREATE TYPE book.account_type AS ENUM (
  'cash', 'margin', 'portfolio_margin', 'ira', 'roth_ira', 'paper', 'simulated'
);

CREATE TYPE book.account_status AS ENUM (
  'pending', 'active', 'restricted', 'liquidation_only', 'closed'
);

CREATE TYPE book.broker AS ENUM (
  'internal_sim', 'alpaca', 'interactive_brokers', 'tradier', 'binance',
  'coinbase', 'oanda', 'tastytrade'
);

-- ── Accounts ─────────────────────────────────────────────────────────────────
CREATE TABLE book.account (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id         text UNIQUE NOT NULL DEFAULT platform.public_id('acc'),
  owner_user_id     uuid NOT NULL REFERENCES identity.user(id) ON DELETE RESTRICT,
  name              varchar(80) NOT NULL,
  account_type      book.account_type NOT NULL,
  status            book.account_status NOT NULL DEFAULT 'pending',
  base_currency     reference.currency_code NOT NULL REFERENCES reference.currency(code),
  broker            book.broker NOT NULL DEFAULT 'internal_sim',
  broker_account_no varchar(48),
  is_paper          boolean NOT NULL DEFAULT true,
  -- Leverage and day-trading rules differ per account type and jurisdiction;
  -- these are the values the pre-trade gate actually enforces.
  max_leverage      reference.ratio NOT NULL DEFAULT 1,
  day_trade_buying_power_multiple reference.ratio NOT NULL DEFAULT 1,
  pdt_restricted    boolean NOT NULL DEFAULT false,
  day_trades_used_5d smallint NOT NULL DEFAULT 0,
  options_level     smallint NOT NULL DEFAULT 0 CHECK (options_level BETWEEN 0 AND 4),
  shorting_enabled  boolean NOT NULL DEFAULT false,
  crypto_enabled    boolean NOT NULL DEFAULT false,
  -- Trading can be halted at the account level without touching the broker.
  trading_blocked   boolean NOT NULL DEFAULT false,
  trading_blocked_reason text,
  opened_at         timestamptz,
  closed_at         timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT account_live_requires_broker
    CHECK (is_paper OR broker <> 'internal_sim'),
  CONSTRAINT account_leverage_sane CHECK (max_leverage BETWEEN 1 AND 30),
  CONSTRAINT account_blocked_has_reason
    CHECK (NOT trading_blocked OR trading_blocked_reason IS NOT NULL)
);

CREATE INDEX account_owner_idx ON book.account (owner_user_id)
  WHERE status <> 'closed';
CREATE INDEX account_broker_idx ON book.account (broker, status);
CREATE UNIQUE INDEX account_broker_no_idx ON book.account (broker, broker_account_no)
  WHERE broker_account_no IS NOT NULL;

COMMENT ON COLUMN book.account.day_trades_used_5d IS
  'Rolling count of day trades in the last 5 business days. At 4 on an account under $25k equity, FINRA PDT blocks the next one.';

-- ── Broker connections (credentials live in Secrets Manager, not here) ────────
CREATE TABLE book.broker_connection (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  broker          book.broker NOT NULL,
  -- Pointer into AWS Secrets Manager / Vault. Never the credential itself.
  secret_ref      text NOT NULL,
  environment     varchar(12) NOT NULL DEFAULT 'paper',  -- paper | live
  status          varchar(16) NOT NULL DEFAULT 'disconnected',
  scopes          text[] NOT NULL DEFAULT '{}',
  last_connected_at timestamptz,
  last_error      text,
  last_error_at   timestamptz,
  -- Broker rate limits we must respect; the execution gateway reads these.
  rate_limit_rpm  integer NOT NULL DEFAULT 200,
  consecutive_failures smallint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, broker, environment)
);

-- ── Portfolios: a logical sleeve within an account ───────────────────────────
-- One account can carry several strategy sleeves, each with its own capital
-- allocation and risk budget, all netting into the same broker account.
CREATE TABLE book.portfolio (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('pf'),
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  name            varchar(80) NOT NULL,
  description     text,
  -- Capital allocated to this sleeve; the sum across sleeves may be less than
  -- account equity (uncommitted cash) but is checked never to exceed it.
  allocated_capital reference.money NOT NULL DEFAULT 0,
  target_volatility reference.ratio,
  max_drawdown_limit reference.ratio,
  benchmark_instrument_id uuid REFERENCES reference.instrument(id),
  is_default      boolean NOT NULL DEFAULT false,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, name),
  CONSTRAINT portfolio_capital_nonneg CHECK (allocated_capital >= 0)
);

CREATE UNIQUE INDEX portfolio_one_default_per_account
  ON book.portfolio (account_id) WHERE is_default;

-- ── Double-entry ledger ──────────────────────────────────────────────────────
CREATE TYPE book.ledger_account AS ENUM (
  'cash', 'settled_cash', 'unsettled_cash', 'margin_loan', 'securities',
  'realized_pnl', 'unrealized_pnl', 'commission', 'fees', 'interest',
  'dividend', 'tax_withheld', 'transfer_in', 'transfer_out', 'borrow_fee'
);

CREATE TYPE book.entry_reason AS ENUM (
  'fill', 'commission', 'regulatory_fee', 'dividend', 'interest',
  'margin_interest', 'borrow_fee', 'deposit', 'withdrawal', 'fx_conversion',
  'corporate_action', 'adjustment', 'assignment', 'exercise', 'expiration'
);

-- Transactions group the entries that must balance together.
CREATE TABLE book.ledger_transaction (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES book.account(id) ON DELETE RESTRICT,
  reason        book.entry_reason NOT NULL,
  description   text,
  -- Source document: a fill, a corporate action, a transfer…
  source_type   varchar(32),
  source_id     uuid,
  -- Idempotency: broker webhooks are redelivered, and double-posting a fill is
  -- the single worst bug this schema can have.
  idempotency_key text NOT NULL,
  occurred_at   timestamptz NOT NULL,
  posted_at     timestamptz NOT NULL DEFAULT now(),
  reversed_by   uuid REFERENCES book.ledger_transaction(id),
  UNIQUE (idempotency_key)
);

CREATE INDEX ledger_transaction_account_time_idx
  ON book.ledger_transaction (account_id, occurred_at DESC);
CREATE INDEX ledger_transaction_source_idx
  ON book.ledger_transaction (source_type, source_id)
  WHERE source_id IS NOT NULL;

CREATE TABLE book.ledger_entry (
  id             bigserial PRIMARY KEY,
  transaction_id uuid NOT NULL REFERENCES book.ledger_transaction(id) ON DELETE RESTRICT,
  account_id     uuid NOT NULL REFERENCES book.account(id) ON DELETE RESTRICT,
  portfolio_id   uuid REFERENCES book.portfolio(id) ON DELETE SET NULL,
  ledger_account book.ledger_account NOT NULL,
  instrument_id  uuid REFERENCES reference.instrument(id),
  -- Signed: debits positive, credits negative. Sum per transaction per
  -- currency must be zero, enforced by the deferred constraint trigger below.
  amount         reference.money NOT NULL,
  currency       reference.currency_code NOT NULL REFERENCES reference.currency(code),
  quantity       reference.quantity,
  occurred_at    timestamptz NOT NULL,
  CONSTRAINT ledger_entry_amount_nonzero CHECK (amount <> 0)
);

CREATE INDEX ledger_entry_transaction_idx ON book.ledger_entry (transaction_id);
CREATE INDEX ledger_entry_account_time_idx
  ON book.ledger_entry (account_id, occurred_at DESC, ledger_account);
CREATE INDEX ledger_entry_instrument_idx
  ON book.ledger_entry (instrument_id, occurred_at DESC)
  WHERE instrument_id IS NOT NULL;

-- The invariant. Deferred so that a transaction can insert its legs in any
-- order, but checked before COMMIT — an unbalanced transaction cannot exist.
CREATE OR REPLACE FUNCTION book.assert_ledger_balanced() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  offending record;
BEGIN
  FOR offending IN
    SELECT e.transaction_id, e.currency, sum(e.amount) AS imbalance
      FROM book.ledger_entry e
     WHERE e.transaction_id = COALESCE(NEW.transaction_id, OLD.transaction_id)
     GROUP BY e.transaction_id, e.currency
    HAVING sum(e.amount) <> 0
  LOOP
    RAISE EXCEPTION
      'ledger transaction % is unbalanced in %: sum = %',
      offending.transaction_id, offending.currency, offending.imbalance
      USING ERRCODE = 'integrity_constraint_violation',
            HINT = 'Every transaction must have equal debits and credits per currency.';
  END LOOP;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_ledger_balanced
  AFTER INSERT OR UPDATE OR DELETE ON book.ledger_entry
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION book.assert_ledger_balanced();

-- ── Cash balances (projection over the ledger) ───────────────────────────────
CREATE TABLE book.cash_balance (
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  currency        reference.currency_code NOT NULL REFERENCES reference.currency(code),
  -- T+1 settlement means cash exists in three states at once.
  settled         reference.money NOT NULL DEFAULT 0,
  unsettled       reference.money NOT NULL DEFAULT 0,
  pending_transfer reference.money NOT NULL DEFAULT 0,
  -- Cash committed to working orders; not spendable twice.
  reserved        reference.money NOT NULL DEFAULT 0,
  margin_loan     reference.money NOT NULL DEFAULT 0,
  buying_power    reference.money NOT NULL DEFAULT 0,
  day_trade_buying_power reference.money NOT NULL DEFAULT 0,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, currency),
  CONSTRAINT cash_reserved_nonneg CHECK (reserved >= 0)
);

-- ── Positions (projection) and tax lots (the truth for cost basis) ───────────
CREATE TABLE book.position (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id        uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id      uuid NOT NULL REFERENCES book.portfolio(id) ON DELETE CASCADE,
  instrument_id     uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE RESTRICT,
  side              reference.position_side NOT NULL,
  quantity          reference.quantity NOT NULL,
  avg_entry_price   reference.price NOT NULL,
  -- Marks, refreshed by the position marker on every quote tick for held names.
  last_price        reference.price,
  marked_at         timestamptz,
  market_value      reference.money,
  cost_basis        reference.money NOT NULL,
  unrealized_pnl    reference.money,
  unrealized_pnl_pct reference.ratio,
  realized_pnl      reference.money NOT NULL DEFAULT 0,
  -- Intraday attribution needs the open price reference separately.
  day_open_quantity reference.quantity NOT NULL DEFAULT 0,
  day_open_price    reference.price,
  day_pnl           reference.money,
  -- Options / futures
  multiplier        reference.ratio NOT NULL DEFAULT 1,
  delta_adjusted_qty reference.quantity,
  -- Strategy attribution: which sleeve opened this.
  opened_by_strategy_id uuid,
  opened_at         timestamptz NOT NULL DEFAULT now(),
  closed_at         timestamptz,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  -- One open position per (portfolio, instrument). Closed ones are kept for
  -- history, hence the partial uniqueness rather than a plain unique key.
  CONSTRAINT position_qty_nonneg CHECK (quantity >= 0),
  CONSTRAINT position_flat_iff_zero CHECK ((side = 'flat') = (quantity = 0)),
  CONSTRAINT position_closed_is_flat CHECK (closed_at IS NULL OR quantity = 0)
);

CREATE UNIQUE INDEX position_open_unique_idx
  ON book.position (portfolio_id, instrument_id) WHERE closed_at IS NULL;
CREATE INDEX position_account_idx ON book.position (account_id) WHERE closed_at IS NULL;
CREATE INDEX position_instrument_idx ON book.position (instrument_id) WHERE closed_at IS NULL;
CREATE INDEX position_stale_mark_idx ON book.position (marked_at NULLS FIRST)
  WHERE closed_at IS NULL;
CREATE INDEX position_strategy_idx ON book.position (opened_by_strategy_id)
  WHERE opened_by_strategy_id IS NOT NULL;

-- Tax lots: FIFO/LIFO/HIFO selection is a user preference and realised P&L
-- depends on it, so lots are tracked individually rather than netted.
CREATE TABLE book.position_lot (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  position_id     uuid NOT NULL REFERENCES book.position(id) ON DELETE CASCADE,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id),
  opening_fill_id uuid,
  quantity_opened reference.quantity NOT NULL,
  quantity_remaining reference.quantity NOT NULL,
  entry_price     reference.price NOT NULL,
  entry_commission reference.money NOT NULL DEFAULT 0,
  opened_at       timestamptz NOT NULL,
  closed_at       timestamptz,
  -- US wash-sale rule: a loss is disallowed if the same security is
  -- repurchased within 30 days. Flagged here so tax reporting can adjust.
  is_wash_sale    boolean NOT NULL DEFAULT false,
  holding_period  varchar(12),      -- short_term | long_term
  CONSTRAINT lot_remaining_within_opened
    CHECK (quantity_remaining >= 0 AND quantity_remaining <= quantity_opened)
);

CREATE INDEX position_lot_open_idx ON book.position_lot (position_id, opened_at)
  WHERE quantity_remaining > 0;
CREATE INDEX position_lot_account_instrument_idx
  ON book.position_lot (account_id, instrument_id, opened_at);

-- ── Transfers ────────────────────────────────────────────────────────────────
CREATE TYPE book.transfer_direction AS ENUM ('deposit', 'withdrawal', 'internal');
CREATE TYPE book.transfer_status AS ENUM (
  'requested', 'pending_review', 'approved', 'submitted', 'settled', 'rejected', 'returned'
);

CREATE TABLE book.transfer (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id      text UNIQUE NOT NULL DEFAULT platform.public_id('xfr'),
  account_id     uuid NOT NULL REFERENCES book.account(id) ON DELETE RESTRICT,
  direction      book.transfer_direction NOT NULL,
  status         book.transfer_status NOT NULL DEFAULT 'requested',
  amount         reference.money NOT NULL CHECK (amount > 0),
  currency       reference.currency_code NOT NULL REFERENCES reference.currency(code),
  method         varchar(24) NOT NULL,        -- ach | wire | card | crypto | internal
  external_ref   varchar(64),
  counterparty_account_id uuid REFERENCES book.account(id),
  requested_at   timestamptz NOT NULL DEFAULT now(),
  settled_at     timestamptz,
  rejection_reason text,
  ledger_transaction_id uuid REFERENCES book.ledger_transaction(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT transfer_internal_has_counterparty
    CHECK (direction <> 'internal' OR counterparty_account_id IS NOT NULL)
);

CREATE INDEX transfer_account_idx ON book.transfer (account_id, requested_at DESC);
CREATE INDEX transfer_pending_idx ON book.transfer (status, requested_at)
  WHERE status IN ('requested', 'pending_review', 'approved', 'submitted');

-- ── Daily equity / performance snapshots (hypertable) ────────────────────────
CREATE TABLE book.equity_snapshot (
  ts                timestamptz NOT NULL,
  account_id        uuid NOT NULL,
  portfolio_id      uuid,
  equity            reference.money NOT NULL,
  cash              reference.money NOT NULL,
  long_market_value  reference.money NOT NULL DEFAULT 0,
  short_market_value reference.money NOT NULL DEFAULT 0,
  gross_exposure    reference.money NOT NULL DEFAULT 0,
  net_exposure      reference.money NOT NULL DEFAULT 0,
  leverage          reference.ratio,
  margin_used       reference.money NOT NULL DEFAULT 0,
  maintenance_margin reference.money NOT NULL DEFAULT 0,
  buying_power      reference.money NOT NULL DEFAULT 0,
  -- P&L decomposition
  realized_pnl_day  reference.money NOT NULL DEFAULT 0,
  unrealized_pnl    reference.money NOT NULL DEFAULT 0,
  fees_day          reference.money NOT NULL DEFAULT 0,
  dividends_day     reference.money NOT NULL DEFAULT 0,
  -- Return series for performance analytics; net is after fees and financing.
  return_gross      reference.ratio,
  return_net        reference.ratio,
  -- Running statistics so the mobile app can render a performance header
  -- without scanning the whole history.
  high_water_mark   reference.money,
  drawdown          reference.ratio,
  positions_count   integer NOT NULL DEFAULT 0,
  currency          reference.currency_code NOT NULL DEFAULT 'USD'
);

SELECT create_hypertable('book.equity_snapshot', 'ts',
  chunk_time_interval => INTERVAL '30 days');

-- A null portfolio_id means "whole account", so uniqueness is expressed as two
-- partial indexes rather than a primary key — NULLs are not comparable in a PK,
-- and Timescale requires the partitioning column in every unique index anyway.
CREATE UNIQUE INDEX equity_snapshot_account_level_idx
  ON book.equity_snapshot (account_id, ts DESC) WHERE portfolio_id IS NULL;
CREATE UNIQUE INDEX equity_snapshot_portfolio_level_idx
  ON book.equity_snapshot (portfolio_id, ts DESC) WHERE portfolio_id IS NOT NULL;
CREATE INDEX equity_snapshot_ts_idx ON book.equity_snapshot (ts DESC);

ALTER TABLE book.equity_snapshot SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'account_id, portfolio_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('book.equity_snapshot', INTERVAL '180 days');

-- ── Reconciliation against the broker's own books ───────────────────────────
-- Run nightly. A break that survives T+1 is a paging incident.
CREATE TABLE book.reconciliation_run (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  as_of         date NOT NULL,
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  status        varchar(16) NOT NULL DEFAULT 'running',
  positions_checked integer NOT NULL DEFAULT 0,
  breaks_found  integer NOT NULL DEFAULT 0,
  cash_delta    reference.money,
  notes         text,
  UNIQUE (account_id, as_of)
);

CREATE TABLE book.reconciliation_break (
  id            bigserial PRIMARY KEY,
  run_id        uuid NOT NULL REFERENCES book.reconciliation_run(id) ON DELETE CASCADE,
  break_type    varchar(32) NOT NULL,       -- quantity | cost_basis | cash | missing
  instrument_id uuid REFERENCES reference.instrument(id),
  our_value     numeric(28, 8),
  broker_value  numeric(28, 8),
  delta         numeric(28, 8),
  severity      varchar(12) NOT NULL DEFAULT 'warning',
  resolved_at   timestamptz,
  resolution    text
);

CREATE INDEX reconciliation_break_open_idx ON book.reconciliation_break (run_id)
  WHERE resolved_at IS NULL;

SELECT platform.attach_touch_triggers('book');
