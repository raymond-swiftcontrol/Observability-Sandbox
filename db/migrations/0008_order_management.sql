-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0008 · Order management: orders, events, fills, routes, algos              ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- oms.order_event is the append-only source of truth; oms.order is a
-- projection of the latest state, maintained by trigger so that readers never
-- have to fold the event log. Every transition is validated against an explicit
-- state machine — an out-of-order broker callback is rejected loudly rather
-- than silently corrupting the order.

CREATE TYPE oms.order_type AS ENUM (
  'market', 'limit', 'stop', 'stop_limit', 'trailing_stop',
  'market_on_open', 'market_on_close', 'limit_on_close', 'pegged', 'iceberg'
);

CREATE TYPE oms.time_in_force AS ENUM ('day', 'gtc', 'ioc', 'fok', 'opg', 'cls', 'gtd');

CREATE TYPE oms.order_status AS ENUM (
  'draft',             -- built in the app, not submitted
  'pending_risk',      -- awaiting the pre-trade gate
  'risk_rejected',
  'pending_new',       -- sent to broker, no ack yet
  'new',               -- acked, working
  'partially_filled',
  'filled',
  'pending_cancel',
  'cancelled',
  'pending_replace',
  'replaced',
  'rejected',
  'expired',
  'suspended'          -- held by the kill switch
);

CREATE TYPE oms.execution_algo AS ENUM (
  'none', 'twap', 'vwap', 'pov', 'iceberg', 'sniper', 'implementation_shortfall'
);

CREATE TYPE oms.order_source AS ENUM ('mobile', 'web', 'api', 'strategy', 'risk_liquidation', 'rebalance');

-- ── Orders ───────────────────────────────────────────────────────────────────
CREATE TABLE oms.order (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id         text UNIQUE NOT NULL DEFAULT platform.public_id('ord'),
  -- Client-generated, so a retried submit from a flaky mobile connection
  -- cannot create a duplicate order.
  client_order_id   text NOT NULL,
  account_id        uuid NOT NULL REFERENCES book.account(id) ON DELETE RESTRICT,
  portfolio_id      uuid NOT NULL REFERENCES book.portfolio(id) ON DELETE RESTRICT,
  instrument_id     uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE RESTRICT,
  submitted_by_user_id uuid REFERENCES identity.user(id),
  strategy_id       uuid,          -- FK added in 0009 once strategies exist
  source            oms.order_source NOT NULL DEFAULT 'mobile',

  side              reference.side NOT NULL,
  order_type        oms.order_type NOT NULL,
  time_in_force     oms.time_in_force NOT NULL DEFAULT 'day',
  quantity          reference.quantity NOT NULL CHECK (quantity > 0),
  limit_price       reference.price,
  stop_price        reference.price,
  trail_amount      reference.price,
  trail_percent     reference.ratio,
  display_quantity  reference.quantity,       -- iceberg visible size
  -- Notional ordering (fractional shares): exactly one of quantity/notional
  -- is user-supplied and the other is derived at submit time.
  notional          reference.money,
  extended_hours    boolean NOT NULL DEFAULT false,
  good_till_date    date,

  status            oms.order_status NOT NULL DEFAULT 'draft',
  filled_quantity   reference.quantity NOT NULL DEFAULT 0,
  leaves_quantity   reference.quantity NOT NULL DEFAULT 0,
  avg_fill_price    reference.price,
  last_fill_price   reference.price,
  last_fill_at      timestamptz,

  -- Costs
  commission        reference.money NOT NULL DEFAULT 0,
  fees              reference.money NOT NULL DEFAULT 0,
  -- Execution quality: arrival price is captured at submit, so slippage is
  -- measurable without reconstructing the book afterwards.
  arrival_price     reference.price,
  arrival_mid       reference.price,
  decision_price    reference.price,
  slippage_bps      reference.bps,
  implementation_shortfall_bps reference.bps,

  -- Algo parent/child relationship
  algo              oms.execution_algo NOT NULL DEFAULT 'none',
  algo_params       jsonb NOT NULL DEFAULT '{}'::jsonb,
  parent_order_id   uuid REFERENCES oms.order(id) ON DELETE SET NULL,
  -- Bracket / OCO linkage
  oco_group_id      uuid,
  bracket_role      varchar(12),          -- entry | take_profit | stop_loss

  -- Broker linkage
  broker            book.broker NOT NULL,
  broker_order_id   varchar(64),
  venue_id          smallint REFERENCES reference.venue(id),
  routing_strategy  varchar(24),

  -- Risk gate outcome
  risk_assessment_id uuid,
  rejected_reason   text,
  rejected_code     varchar(32),

  -- Lifecycle timestamps; all of them, because execution-quality analysis and
  -- latency SLOs both need the full breakdown.
  created_at        timestamptz NOT NULL DEFAULT now(),
  risk_checked_at   timestamptz,
  submitted_at      timestamptz,
  acked_at          timestamptz,
  first_fill_at     timestamptz,
  terminal_at       timestamptz,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz,

  CONSTRAINT order_limit_price_required
    CHECK (order_type NOT IN ('limit', 'stop_limit', 'limit_on_close') OR limit_price IS NOT NULL),
  CONSTRAINT order_stop_price_required
    CHECK (order_type NOT IN ('stop', 'stop_limit') OR stop_price IS NOT NULL),
  CONSTRAINT order_trail_required
    CHECK (order_type <> 'trailing_stop'
           OR trail_amount IS NOT NULL OR trail_percent IS NOT NULL),
  CONSTRAINT order_iceberg_display
    CHECK (order_type <> 'iceberg' OR (display_quantity IS NOT NULL AND display_quantity < quantity)),
  CONSTRAINT order_gtd_needs_date
    CHECK (time_in_force <> 'gtd' OR good_till_date IS NOT NULL),
  CONSTRAINT order_fill_within_quantity
    CHECK (filled_quantity >= 0 AND filled_quantity <= quantity),
  CONSTRAINT order_leaves_consistent
    CHECK (leaves_quantity = quantity - filled_quantity),
  CONSTRAINT order_terminal_has_timestamp
    CHECK ((status IN ('filled','cancelled','rejected','expired','risk_rejected'))
           = (terminal_at IS NOT NULL)),
  CONSTRAINT order_rejected_has_reason
    CHECK (status NOT IN ('rejected', 'risk_rejected') OR rejected_reason IS NOT NULL)
);

-- Idempotency: one client_order_id per account, forever.
CREATE UNIQUE INDEX order_client_id_idx ON oms.order (account_id, client_order_id);
CREATE UNIQUE INDEX order_broker_id_idx ON oms.order (broker, broker_order_id)
  WHERE broker_order_id IS NOT NULL;
-- The hot path: "show me this account's working orders".
CREATE INDEX order_working_idx ON oms.order (account_id, created_at DESC)
  WHERE status IN ('pending_risk','pending_new','new','partially_filled','pending_cancel','pending_replace');
CREATE INDEX order_account_time_idx ON oms.order (account_id, created_at DESC);
CREATE INDEX order_instrument_time_idx ON oms.order (instrument_id, created_at DESC);
CREATE INDEX order_strategy_idx ON oms.order (strategy_id, created_at DESC)
  WHERE strategy_id IS NOT NULL;
CREATE INDEX order_parent_idx ON oms.order (parent_order_id) WHERE parent_order_id IS NOT NULL;
CREATE INDEX order_oco_idx ON oms.order (oco_group_id) WHERE oco_group_id IS NOT NULL;
-- The expiry sweeper and the stuck-order alert both scan this.
CREATE INDEX order_expiring_idx ON oms.order (expires_at)
  WHERE expires_at IS NOT NULL AND terminal_at IS NULL;

COMMENT ON COLUMN oms.order.arrival_price IS
  'Mid price at the instant of submission. Slippage and implementation shortfall are meaningless without it, and it cannot be reconstructed later once quote retention expires.';

-- Close the forward reference from book.position_lot.
ALTER TABLE book.position_lot
  ADD CONSTRAINT position_lot_opening_fill_fk
  FOREIGN KEY (opening_fill_id) REFERENCES oms.fill(id) ON DELETE SET NULL
  NOT VALID;   -- validated at the end of this migration, after oms.fill exists

-- ── Event log ────────────────────────────────────────────────────────────────
CREATE TYPE oms.event_type AS ENUM (
  'created', 'risk_approved', 'risk_rejected', 'submitted', 'acked', 'partial_fill',
  'fill', 'cancel_requested', 'cancelled', 'replace_requested', 'replaced',
  'rejected', 'expired', 'suspended', 'resumed', 'broker_error'
);

CREATE TABLE oms.order_event (
  id            bigserial PRIMARY KEY,
  order_id      uuid NOT NULL REFERENCES oms.order(id) ON DELETE CASCADE,
  sequence      integer NOT NULL,
  event_type    oms.event_type NOT NULL,
  from_status   oms.order_status,
  to_status     oms.order_status NOT NULL,
  quantity      reference.quantity,
  price         reference.price,
  -- Raw broker payload, kept verbatim. When a broker's semantics surprise us,
  -- this is the only way to reconstruct what actually happened.
  broker_payload jsonb,
  message       text,
  -- Correlation: ties an order event back to the trace that produced it.
  trace_id      varchar(32),
  actor         varchar(40) NOT NULL DEFAULT 'system',
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  recorded_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id, sequence)
);

CREATE INDEX order_event_order_idx ON oms.order_event (order_id, sequence);
CREATE INDEX order_event_time_idx ON oms.order_event (occurred_at DESC);
CREATE INDEX order_event_trace_idx ON oms.order_event (trace_id) WHERE trace_id IS NOT NULL;

-- The state machine. Keeping it in the database means a buggy service cannot
-- drive an order into an impossible state, whatever the broker sends.
CREATE OR REPLACE FUNCTION oms.is_valid_transition(
  p_from oms.order_status, p_to oms.order_status
) RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p_from IS NULL THEN p_to IN ('draft', 'pending_risk')
    WHEN p_from = p_to  THEN p_to IN ('partially_filled')   -- successive partials
    ELSE (p_from, p_to) IN (
      ('draft','pending_risk'), ('draft','cancelled'),
      ('pending_risk','risk_rejected'), ('pending_risk','pending_new'),
      ('pending_risk','cancelled'), ('pending_risk','suspended'),
      ('pending_new','new'), ('pending_new','rejected'), ('pending_new','cancelled'),
      ('pending_new','filled'), ('pending_new','partially_filled'),
      ('new','partially_filled'), ('new','filled'), ('new','pending_cancel'),
      ('new','pending_replace'), ('new','cancelled'), ('new','expired'),
      ('new','rejected'), ('new','suspended'),
      ('partially_filled','filled'), ('partially_filled','pending_cancel'),
      ('partially_filled','pending_replace'), ('partially_filled','cancelled'),
      ('partially_filled','expired'),
      ('pending_cancel','cancelled'), ('pending_cancel','filled'),
      ('pending_cancel','partially_filled'), ('pending_cancel','new'),
      ('pending_replace','replaced'), ('pending_replace','new'),
      ('pending_replace','cancelled'), ('pending_replace','filled'),
      ('pending_replace','partially_filled'),
      ('replaced','new'), ('replaced','cancelled'),
      ('suspended','pending_risk'), ('suspended','cancelled')
    )
  END
$$;

COMMENT ON FUNCTION oms.is_valid_transition IS
  'Order state machine. A pending_cancel order can still fill — the race between our cancel and the venue''s match is real, and the transition table must allow it.';

-- Applying an event is the only sanctioned way to move an order. It validates
-- the transition, advances the projection, and keeps the event sequence dense.
CREATE OR REPLACE FUNCTION oms.apply_order_event(
  p_order_id     uuid,
  p_event_type   oms.event_type,
  p_to_status    oms.order_status,
  p_quantity     reference.quantity DEFAULT NULL,
  p_price        reference.price DEFAULT NULL,
  p_message      text DEFAULT NULL,
  p_broker_payload jsonb DEFAULT NULL,
  p_trace_id     varchar(32) DEFAULT NULL,
  p_actor        varchar(40) DEFAULT 'system'
) RETURNS oms.order_event LANGUAGE plpgsql AS $$
DECLARE
  cur_status oms.order_status;
  next_seq   integer;
  evt        oms.order_event;
BEGIN
  -- Row lock serialises concurrent broker callbacks for the same order.
  SELECT status INTO cur_status FROM oms.order WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order % does not exist', p_order_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT oms.is_valid_transition(cur_status, p_to_status) THEN
    RAISE EXCEPTION 'illegal order transition % -> % for order %',
      cur_status, p_to_status, p_order_id
      USING ERRCODE = 'invalid_parameter_value',
            HINT = 'See oms.is_valid_transition for the permitted set.';
  END IF;

  SELECT coalesce(max(sequence), 0) + 1 INTO next_seq
    FROM oms.order_event WHERE order_id = p_order_id;

  INSERT INTO oms.order_event (
    order_id, sequence, event_type, from_status, to_status,
    quantity, price, broker_payload, message, trace_id, actor
  ) VALUES (
    p_order_id, next_seq, p_event_type, cur_status, p_to_status,
    p_quantity, p_price, p_broker_payload, p_message, p_trace_id, p_actor
  ) RETURNING * INTO evt;

  UPDATE oms.order o
     SET status = p_to_status,
         risk_checked_at = CASE WHEN p_event_type IN ('risk_approved','risk_rejected')
                                THEN now() ELSE o.risk_checked_at END,
         submitted_at    = CASE WHEN p_event_type = 'submitted' THEN now() ELSE o.submitted_at END,
         acked_at        = CASE WHEN p_event_type = 'acked' THEN now() ELSE o.acked_at END,
         rejected_reason = CASE WHEN p_to_status IN ('rejected','risk_rejected')
                                THEN coalesce(p_message, 'unspecified') ELSE o.rejected_reason END,
         terminal_at     = CASE WHEN p_to_status IN ('filled','cancelled','rejected','expired','risk_rejected')
                                THEN now() ELSE o.terminal_at END,
         updated_at      = now()
   WHERE o.id = p_order_id;

  RETURN evt;
END $$;

-- ── Fills ────────────────────────────────────────────────────────────────────
CREATE TABLE oms.fill (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES oms.order(id) ON DELETE RESTRICT,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE RESTRICT,
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE RESTRICT,
  -- Broker's execution id. Unique per broker and the dedupe key for webhook
  -- redelivery, which every broker does.
  broker_exec_id  varchar(64),
  side            reference.side NOT NULL,
  quantity        reference.quantity NOT NULL CHECK (quantity > 0),
  price           reference.price NOT NULL CHECK (price > 0),
  gross_amount    reference.money NOT NULL,
  commission      reference.money NOT NULL DEFAULT 0,
  -- US regulatory fees are per-side and per-venue; itemised for statements.
  sec_fee         reference.money NOT NULL DEFAULT 0,
  taf_fee         reference.money NOT NULL DEFAULT 0,
  clearing_fee    reference.money NOT NULL DEFAULT 0,
  exchange_fee    reference.money NOT NULL DEFAULT 0,
  other_fees      reference.money NOT NULL DEFAULT 0,
  net_amount      reference.money NOT NULL,
  venue_id        smallint REFERENCES reference.venue(id),
  liquidity_flag  varchar(8),           -- maker | taker | auction | routed
  -- Execution quality measured against the prevailing quote at fill time.
  nbbo_bid        reference.price,
  nbbo_ask        reference.price,
  effective_spread_bps reference.bps,
  price_improvement reference.money,
  -- Settlement
  trade_date      date NOT NULL,
  settlement_date date,
  -- Lot accounting: which lots this fill opened or closed.
  realized_pnl    reference.money,
  executed_at     timestamptz NOT NULL,
  recorded_at     timestamptz NOT NULL DEFAULT now(),
  ledger_transaction_id uuid REFERENCES book.ledger_transaction(id),
  CONSTRAINT fill_net_amount_coherent CHECK (
    abs(net_amount - (gross_amount
      - CASE WHEN side = 'buy' THEN -1 ELSE 1 END
        * (commission + sec_fee + taf_fee + clearing_fee + exchange_fee + other_fees)
    )) < 0.01
  )
);

CREATE UNIQUE INDEX fill_broker_exec_idx ON oms.fill (broker_exec_id)
  WHERE broker_exec_id IS NOT NULL;
CREATE INDEX fill_order_idx ON oms.fill (order_id, executed_at);
CREATE INDEX fill_account_time_idx ON oms.fill (account_id, executed_at DESC);
CREATE INDEX fill_instrument_time_idx ON oms.fill (instrument_id, executed_at DESC);
CREATE INDEX fill_unsettled_idx ON oms.fill (settlement_date)
  WHERE settlement_date >= CURRENT_DATE;
CREATE INDEX fill_unposted_idx ON oms.fill (recorded_at)
  WHERE ledger_transaction_id IS NULL;

ALTER TABLE book.position_lot VALIDATE CONSTRAINT position_lot_opening_fill_fk;

-- Fills drive the order projection. Doing this in a trigger rather than in
-- application code means the aggregate can never drift from its fills.
CREATE OR REPLACE FUNCTION oms.recompute_order_fill_state() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  agg record;
  ord record;
BEGIN
  SELECT sum(f.quantity)                              AS qty,
         sum(f.quantity * f.price) / sum(f.quantity)   AS vwap,
         sum(f.commission + f.sec_fee + f.taf_fee
             + f.clearing_fee + f.exchange_fee + f.other_fees) AS costs,
         max(f.executed_at)                            AS last_at,
         min(f.executed_at)                            AS first_at,
         count(*)                                      AS n
    INTO agg
    FROM oms.fill f
   WHERE f.order_id = NEW.order_id;

  SELECT * INTO ord FROM oms.order WHERE id = NEW.order_id FOR UPDATE;

  UPDATE oms.order o
     SET filled_quantity = agg.qty,
         leaves_quantity = o.quantity - agg.qty,
         avg_fill_price  = agg.vwap,
         last_fill_price = NEW.price,
         last_fill_at    = agg.last_at,
         first_fill_at   = coalesce(o.first_fill_at, agg.first_at),
         commission      = agg.costs,
         -- Signed slippage in bps against arrival: positive means we paid up.
         slippage_bps    = CASE
           WHEN o.arrival_price IS NULL OR o.arrival_price = 0 THEN NULL
           ELSE (CASE WHEN o.side = 'buy' THEN 1 ELSE -1 END)
                * (agg.vwap - o.arrival_price) / o.arrival_price * 10000
         END,
         updated_at      = now()
   WHERE o.id = NEW.order_id;

  -- Advance status through the state machine rather than assigning it directly.
  IF agg.qty >= ord.quantity THEN
    IF ord.status <> 'filled' THEN
      PERFORM oms.apply_order_event(NEW.order_id, 'fill', 'filled',
               NEW.quantity, NEW.price, 'fully filled', NULL, NULL, 'oms');
    END IF;
  ELSIF agg.qty > 0 AND ord.status IN ('new', 'pending_new', 'partially_filled') THEN
    PERFORM oms.apply_order_event(NEW.order_id, 'partial_fill', 'partially_filled',
             NEW.quantity, NEW.price, NULL, NULL, NULL, 'oms');
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_fill_updates_order
  AFTER INSERT ON oms.fill
  FOR EACH ROW EXECUTE FUNCTION oms.recompute_order_fill_state();

-- ── Routing decisions (smart order router audit trail) ──────────────────────
CREATE TABLE oms.route_decision (
  id              bigserial PRIMARY KEY,
  order_id        uuid NOT NULL REFERENCES oms.order(id) ON DELETE CASCADE,
  sequence        smallint NOT NULL DEFAULT 1,
  venue_id        smallint REFERENCES reference.venue(id),
  broker          book.broker NOT NULL,
  quantity        reference.quantity NOT NULL,
  -- Why this venue won: scores from the router's cost model.
  expected_cost_bps reference.bps,
  expected_fill_probability reference.ratio,
  latency_estimate_ms integer,
  score           reference.ratio,
  candidates      jsonb NOT NULL DEFAULT '[]'::jsonb,
  decided_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id, sequence)
);

COMMENT ON TABLE oms.route_decision IS
  'Why the router chose a venue, with the rejected candidates. Best-execution reviews need the counterfactual, not just the outcome.';

-- ── Algo orders (parent schedule + slice progress) ──────────────────────────
CREATE TABLE oms.algo_execution (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_order_id uuid NOT NULL UNIQUE REFERENCES oms.order(id) ON DELETE CASCADE,
  algo            oms.execution_algo NOT NULL,
  start_at        timestamptz NOT NULL,
  end_at          timestamptz NOT NULL,
  -- POV / participation constraints
  target_participation_rate reference.ratio,
  max_participation_rate    reference.ratio,
  -- Slicing
  slice_count     integer NOT NULL,
  slices_sent     integer NOT NULL DEFAULT 0,
  slices_filled   integer NOT NULL DEFAULT 0,
  interval_seconds integer,
  randomize_pct   reference.ratio NOT NULL DEFAULT 0,
  -- Progress and benchmark tracking
  target_quantity reference.quantity NOT NULL,
  executed_quantity reference.quantity NOT NULL DEFAULT 0,
  benchmark_price reference.price,
  benchmark_type  varchar(16) NOT NULL DEFAULT 'arrival',  -- arrival|vwap|twap|close
  tracking_error_bps reference.bps,
  status          varchar(16) NOT NULL DEFAULT 'running',
  paused_reason   text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT algo_window_ordered CHECK (end_at > start_at),
  CONSTRAINT algo_participation_bounds CHECK (
    max_participation_rate IS NULL OR max_participation_rate BETWEEN 0 AND 1
  )
);

CREATE TABLE oms.algo_slice (
  id              bigserial PRIMARY KEY,
  algo_execution_id uuid NOT NULL REFERENCES oms.algo_execution(id) ON DELETE CASCADE,
  slice_number    integer NOT NULL,
  child_order_id  uuid REFERENCES oms.order(id) ON DELETE SET NULL,
  scheduled_at    timestamptz NOT NULL,
  target_quantity reference.quantity NOT NULL,
  sent_at         timestamptz,
  filled_quantity reference.quantity NOT NULL DEFAULT 0,
  avg_price       reference.price,
  -- Market context at slice time, for post-trade analysis of the schedule.
  market_volume_in_window reference.quantity,
  realized_participation  reference.ratio,
  skipped_reason  text,
  UNIQUE (algo_execution_id, slice_number)
);

CREATE INDEX algo_slice_pending_idx ON oms.algo_slice (scheduled_at)
  WHERE sent_at IS NULL;

-- ── Rejections (kept separately: we analyse them in aggregate) ──────────────
CREATE TABLE oms.rejection (
  id            bigserial PRIMARY KEY,
  order_id      uuid REFERENCES oms.order(id) ON DELETE CASCADE,
  account_id    uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  stage         varchar(16) NOT NULL,     -- validation | risk | broker | venue
  code          varchar(48) NOT NULL,
  message       text NOT NULL,
  is_retryable  boolean NOT NULL DEFAULT false,
  broker_payload jsonb,
  occurred_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX rejection_account_time_idx ON oms.rejection (account_id, occurred_at DESC);
CREATE INDEX rejection_code_idx ON oms.rejection (code, occurred_at DESC);

-- ── Execution quality rollup (populated nightly by the quant engine) ────────
CREATE TABLE oms.execution_quality_daily (
  trade_date      date NOT NULL,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE CASCADE,
  algo            oms.execution_algo NOT NULL DEFAULT 'none',
  order_count     integer NOT NULL DEFAULT 0,
  filled_notional reference.money NOT NULL DEFAULT 0,
  avg_slippage_bps reference.bps,
  median_slippage_bps reference.bps,
  p95_slippage_bps reference.bps,
  avg_spread_paid_bps reference.bps,
  fill_rate       reference.ratio,
  cancel_rate     reference.ratio,
  avg_time_to_fill_ms integer,
  total_commission reference.money NOT NULL DEFAULT 0,
  total_fees      reference.money NOT NULL DEFAULT 0,
  price_improvement_total reference.money NOT NULL DEFAULT 0,
  PRIMARY KEY (trade_date, account_id, instrument_id, algo)
);

SELECT platform.attach_touch_triggers('oms');
