-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0026 · Sync cursors, runs, external transactions, gaps, reconciliation    ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Implements the holdings-sync spec. The design is built around three facts
-- about real brokerage APIs:
--   • They redeliver. Idempotency is keyed on (connection, external id), and a
--     restatement creates a NEW row pointing at the old one rather than
--     mutating it — the original is evidence.
--   • They paginate inconsistently. Cursors are per-resource so a failure
--     syncing transactions cannot skip or re-sync positions.
--   • They are incomplete. A gap is recorded and surfaced, never tolerated
--     silently, because an incomplete history presented as complete is how
--     wrong cost basis and wrong tax numbers get shipped.

CREATE TYPE broker.sync_outcome AS ENUM (
  'success', 'partial', 'rate_limited', 'auth_failed',
  'contract_violation', 'provider_error', 'timeout', 'skipped'
);

CREATE TYPE broker.basis_quality AS ENUM (
  'sourced',       -- the broker gave us per-lot acquisition detail
  'reconstructed', -- derived from a complete, reconciling transaction history
  'estimated'      -- derived from an average price; must be labelled in the UI
);

CREATE TYPE broker.break_kind AS ENUM (
  'quantity', 'cash', 'cost_basis', 'missing_in_broker',
  'missing_in_helios', 'corporate_action_suspected', 'currency'
);

-- ── Per-resource cursors ────────────────────────────────────────────────────
CREATE TABLE broker.sync_cursor (
  connection_id   uuid NOT NULL REFERENCES broker.connection(id) ON DELETE CASCADE,
  resource        broker.resource NOT NULL,
  -- Opaque to us: a page token, a timestamp, a sequence — whatever the
  -- provider's pagination model uses.
  cursor_value    text,
  cursor_kind     varchar(16) NOT NULL DEFAULT 'opaque',
  -- The watermark a resumed sync starts from. Distinct from cursor_value
  -- because some providers paginate within a time window.
  synced_through  timestamptz,
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  consecutive_failures smallint NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  is_paused       boolean NOT NULL DEFAULT false,
  pause_reason    text,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (connection_id, resource)
);

-- The scheduler's read: what is due, soonest first.
CREATE INDEX sync_cursor_due_idx ON broker.sync_cursor (next_attempt_at)
  WHERE NOT is_paused;
-- Staleness is the signal users actually feel, so it gets its own index.
CREATE INDEX sync_cursor_stale_idx ON broker.sync_cursor (last_success_at NULLS FIRST);

COMMENT ON TABLE broker.sync_cursor IS
  'One row per connection per resource. Independent cursors are what make "the transaction sync failed but positions are current" an expressible state rather than an all-or-nothing retry.';

-- ── Run log ─────────────────────────────────────────────────────────────────
CREATE TABLE broker.sync_run (
  id              bigserial PRIMARY KEY,
  connection_id   uuid NOT NULL REFERENCES broker.connection(id) ON DELETE CASCADE,
  resource        broker.resource NOT NULL,
  trigger_kind    varchar(16) NOT NULL DEFAULT 'scheduled',  -- scheduled|manual|webhook
  outcome         broker.sync_outcome,
  -- Counts, because "the sync succeeded" is not an answer to "did anything
  -- change?" and the user-facing status screen shows both.
  records_fetched integer NOT NULL DEFAULT 0,
  records_created integer NOT NULL DEFAULT 0,
  records_duplicate integer NOT NULL DEFAULT 0,
  records_superseded integer NOT NULL DEFAULT 0,
  records_rejected integer NOT NULL DEFAULT 0,
  pages_fetched   integer NOT NULL DEFAULT 0,
  cursor_before   text,
  cursor_after    text,
  error_class     varchar(48),
  error_message   text,
  provider_status smallint,
  retry_after_seconds integer,
  duration_ms     integer,
  trace_id        varchar(32),
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);

CREATE INDEX sync_run_connection_idx
  ON broker.sync_run (connection_id, resource, started_at DESC);
CREATE INDEX sync_run_failures_idx ON broker.sync_run (started_at DESC)
  WHERE outcome NOT IN ('success', 'skipped');
-- A contract violation means the provider changed its response shape; it is
-- always an incident, never noise.
CREATE INDEX sync_run_contract_violation_idx ON broker.sync_run (started_at DESC)
  WHERE outcome = 'contract_violation';

-- ── External transactions ───────────────────────────────────────────────────
CREATE TABLE broker.external_transaction (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id   uuid NOT NULL REFERENCES broker.connection(id) ON DELETE CASCADE,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  -- The idempotency key. Redelivery is normal, not exceptional.
  external_id     varchar(128) NOT NULL,

  -- Normalised interpretation
  transaction_type varchar(32) NOT NULL,     -- buy|sell|dividend|fee|interest|transfer…
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE SET NULL,
  external_symbol varchar(64),
  side            reference.side,
  quantity        reference.quantity,
  price           reference.price,
  gross_amount    reference.money,
  fees            reference.money NOT NULL DEFAULT 0,
  net_amount      reference.money,
  currency        reference.currency_code REFERENCES reference.currency(code),
  trade_date      date,
  settlement_date date,
  occurred_at     timestamptz NOT NULL,

  -- The provider's payload, verbatim. When a broker's semantics surprise us,
  -- this is the only way to reconstruct what they actually said.
  raw_payload     jsonb NOT NULL,

  -- Supersession chain. A restatement inserts a new row and points the old one
  -- at it; the original is never mutated, so the audit trail survives.
  supersedes_id   uuid REFERENCES broker.external_transaction(id) ON DELETE SET NULL,
  superseded_by   uuid REFERENCES broker.external_transaction(id) ON DELETE SET NULL,

  -- What we did with it
  ledger_transaction_id uuid REFERENCES book.ledger_transaction(id) ON DELETE SET NULL,
  fill_id         uuid REFERENCES oms.fill(id) ON DELETE SET NULL,
  posted_at       timestamptz,
  rejected_reason text,

  sync_run_id     bigint REFERENCES broker.sync_run(id) ON DELETE SET NULL,
  ingested_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT external_transaction_no_self_supersede
    CHECK (superseded_by IS DISTINCT FROM id AND supersedes_id IS DISTINCT FROM id)
);

-- The idempotency guarantee, as an index rather than an application check.
CREATE UNIQUE INDEX external_transaction_idempotency_idx
  ON broker.external_transaction (connection_id, external_id)
  WHERE superseded_by IS NULL;

CREATE INDEX external_transaction_account_time_idx
  ON broker.external_transaction (account_id, occurred_at DESC);
CREATE INDEX external_transaction_instrument_idx
  ON broker.external_transaction (instrument_id, occurred_at)
  WHERE instrument_id IS NOT NULL;
-- The posting worker's queue.
CREATE INDEX external_transaction_unposted_idx
  ON broker.external_transaction (ingested_at)
  WHERE posted_at IS NULL AND rejected_reason IS NULL AND superseded_by IS NULL;

COMMENT ON INDEX broker.external_transaction_idempotency_idx IS
  'Partial on superseded_by IS NULL so a restatement can carry the same external_id as the row it replaces. Without the partial clause, restatement and idempotency contradict each other.';

-- ── External positions and balances (latest snapshot per sync) ──────────────
CREATE TABLE broker.external_position (
  connection_id   uuid NOT NULL REFERENCES broker.connection(id) ON DELETE CASCADE,
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  as_of           timestamptz NOT NULL,
  quantity        reference.quantity NOT NULL,
  average_price   reference.price,
  market_value    reference.money,
  cost_basis      reference.money,
  unrealized_pnl  reference.money,
  currency        reference.currency_code REFERENCES reference.currency(code),
  external_symbol varchar(64),
  raw_payload     jsonb,
  PRIMARY KEY (connection_id, instrument_id, as_of)
);

CREATE INDEX external_position_latest_idx
  ON broker.external_position (connection_id, as_of DESC);

CREATE TABLE broker.external_balance (
  connection_id   uuid NOT NULL REFERENCES broker.connection(id) ON DELETE CASCADE,
  currency        reference.currency_code NOT NULL REFERENCES reference.currency(code),
  as_of           timestamptz NOT NULL,
  cash            reference.money NOT NULL,
  settled_cash    reference.money,
  buying_power    reference.money,
  margin_used     reference.money,
  equity          reference.money,
  raw_payload     jsonb,
  PRIMARY KEY (connection_id, currency, as_of)
);

-- ── Gaps ────────────────────────────────────────────────────────────────────
CREATE TABLE broker.sync_gap (
  id              bigserial PRIMARY KEY,
  connection_id   uuid NOT NULL REFERENCES broker.connection(id) ON DELETE CASCADE,
  resource        broker.resource NOT NULL,
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE CASCADE,
  gap_kind        varchar(32) NOT NULL,   -- missing_window|unexplained_position_change|sequence
  window_start    timestamptz,
  window_end      timestamptz,
  detail          text NOT NULL,
  -- Whether this gap invalidates a cost-basis reconstruction. A gap inside the
  -- holding period does; one after the position closed does not.
  affects_cost_basis boolean NOT NULL DEFAULT false,
  detected_at     timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  resolution      text
);

CREATE INDEX sync_gap_open_idx ON broker.sync_gap (connection_id, detected_at DESC)
  WHERE resolved_at IS NULL;
CREATE INDEX sync_gap_basis_affecting_idx ON broker.sync_gap (instrument_id)
  WHERE resolved_at IS NULL AND affects_cost_basis;

-- ── Reconciliation ──────────────────────────────────────────────────────────
CREATE TABLE broker.reconciliation (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id   uuid NOT NULL REFERENCES broker.connection(id) ON DELETE CASCADE,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  as_of           timestamptz NOT NULL,
  instruments_compared integer NOT NULL DEFAULT 0,
  breaks_found    integer NOT NULL DEFAULT 0,
  breaks_auto_resolved integer NOT NULL DEFAULT 0,
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz,
  trace_id        varchar(32)
);

CREATE INDEX reconciliation_connection_idx
  ON broker.reconciliation (connection_id, as_of DESC);

CREATE TABLE broker.reconciliation_break (
  id              bigserial PRIMARY KEY,
  reconciliation_id uuid NOT NULL REFERENCES broker.reconciliation(id) ON DELETE CASCADE,
  kind            broker.break_kind NOT NULL,
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE SET NULL,
  currency        reference.currency_code REFERENCES reference.currency(code),
  -- Both figures are kept. The broker's number never silently overwrites ours;
  -- a difference is a decision, not a data-entry problem.
  helios_value    numeric(38, 18),
  broker_value    numeric(38, 18),
  delta           numeric(38, 18),
  tolerance       numeric(38, 18),
  -- Only corporate-action breaks are auto-resolvable, and only when a known
  -- action explains the delta exactly.
  auto_resolved   boolean NOT NULL DEFAULT false,
  corporate_action_id uuid REFERENCES reference.corporate_action(id) ON DELETE SET NULL,
  severity        varchar(12) NOT NULL DEFAULT 'warning',
  resolved_at     timestamptz,
  resolved_by     uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  resolution      varchar(32),      -- accept_broker | keep_helios | adjust | ignore
  resolution_note text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT break_auto_resolution_requires_action
    CHECK (NOT auto_resolved OR corporate_action_id IS NOT NULL),
  CONSTRAINT break_resolved_has_resolution
    CHECK (resolved_at IS NULL OR resolution IS NOT NULL)
);

CREATE INDEX reconciliation_break_open_idx
  ON broker.reconciliation_break (created_at)
  WHERE resolved_at IS NULL;
CREATE INDEX reconciliation_break_run_idx
  ON broker.reconciliation_break (reconciliation_id);

COMMENT ON CONSTRAINT break_auto_resolution_requires_action ON broker.reconciliation_break IS
  'Auto-resolution is permitted only when a specific corporate action explains the delta. Every other break needs a human decision, because "the broker is probably right" is how a real discrepancy gets papered over.';

-- ── Cost-basis quality on lots ──────────────────────────────────────────────
-- Extends book.position_lot rather than duplicating it: basis quality belongs
-- with the lot, and every surface that shows P&L has to be able to see it.
ALTER TABLE book.position_lot
  ADD COLUMN basis_quality broker.basis_quality NOT NULL DEFAULT 'sourced',
  ADD COLUMN source_connection_id uuid REFERENCES broker.connection(id) ON DELETE SET NULL,
  ADD COLUMN basis_note text;

CREATE INDEX position_lot_estimated_basis_idx
  ON book.position_lot (account_id, instrument_id)
  WHERE basis_quality = 'estimated';

COMMENT ON COLUMN book.position_lot.basis_quality IS
  'sourced: the broker supplied lot detail. reconstructed: derived from a transaction history that replayed to the reported quantity exactly. estimated: derived from an average price. Any surface displaying cost basis or P&L for an estimated lot must say so.';

SELECT platform.attach_touch_triggers('broker');
