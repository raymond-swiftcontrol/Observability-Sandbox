-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0027 · File import and manual portfolio entry                             ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Implements the portfolio-import spec. The guarantee that shapes this schema
-- is "the committed result matches the preview": per-row outcomes are
-- PERSISTED at preview time and the commit replays those rows rather than
-- re-deciding. A preview that is recomputed at commit time is not a preview,
-- it is a promise the system has no way to keep.

CREATE TYPE broker.import_state AS ENUM (
  'uploaded', 'parsing', 'previewed', 'committing', 'committed', 'failed', 'cancelled'
);

CREATE TYPE broker.import_row_outcome AS ENUM (
  'create',      -- will be / was created
  'duplicate',   -- matches an existing imported or synced transaction
  'rejected',    -- unparseable or failed validation
  'ignored'      -- user deselected it
);

-- ── Learned column mappings ─────────────────────────────────────────────────
-- A user who corrects the mapping for their broker's export should not have to
-- do it again next month.
CREATE TABLE broker.format_profile (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES identity.user(id) ON DELETE CASCADE,
  -- A null user_id marks a built-in profile shipped with the product.
  provider_id     smallint REFERENCES broker.provider(id) ON DELETE SET NULL,
  name            varchar(80) NOT NULL,
  -- Detection: a fingerprint of the header row, so an upload can be matched to
  -- a profile before the user is asked anything.
  header_fingerprint text NOT NULL,
  column_mapping  jsonb NOT NULL,
  date_format     varchar(32),
  decimal_separator char(1) NOT NULL DEFAULT '.',
  thousands_separator char(1),
  -- Some exports sign sells negative, some use a side column; getting this
  -- wrong silently inverts a portfolio.
  amount_sign_convention varchar(16) NOT NULL DEFAULT 'side_column',
  skip_rows       smallint NOT NULL DEFAULT 0,
  encoding        varchar(16) NOT NULL DEFAULT 'utf-8',
  use_count       integer NOT NULL DEFAULT 0,
  is_builtin      boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT format_profile_builtin_has_no_owner
    CHECK (is_builtin = (user_id IS NULL))
);

CREATE INDEX format_profile_fingerprint_idx
  ON broker.format_profile (header_fingerprint);
CREATE INDEX format_profile_user_idx ON broker.format_profile (user_id)
  WHERE user_id IS NOT NULL;

-- ── Import batches ──────────────────────────────────────────────────────────
CREATE TABLE broker.import_batch (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('imp'),
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE SET NULL,

  state           broker.import_state NOT NULL DEFAULT 'uploaded',
  -- The uploaded file: stored in object storage, never in the database, and
  -- bounded in size at the edge.
  object_key      text NOT NULL,
  original_filename varchar(255) NOT NULL,
  content_type    varchar(64) NOT NULL,
  byte_size       bigint NOT NULL,
  content_hash    char(64) NOT NULL,

  format_profile_id uuid REFERENCES broker.format_profile(id) ON DELETE SET NULL,
  detected_format varchar(64),
  column_mapping  jsonb,
  mapping_corrected_by_user boolean NOT NULL DEFAULT false,

  -- Preview totals, frozen when the preview is produced.
  rows_total      integer NOT NULL DEFAULT 0,
  rows_create     integer NOT NULL DEFAULT 0,
  rows_duplicate  integer NOT NULL DEFAULT 0,
  rows_rejected   integer NOT NULL DEFAULT 0,
  previewed_at    timestamptz,

  -- Commit results, compared against the preview totals by a check at the
  -- application layer and by the reconciliation report.
  rows_committed  integer NOT NULL DEFAULT 0,
  committed_at    timestamptz,
  error_message   text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT import_size_bounded CHECK (byte_size > 0 AND byte_size <= 52428800),
  CONSTRAINT import_content_type_allowed
    CHECK (content_type IN ('text/csv', 'text/plain', 'application/vnd.ms-excel',
                            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                            'application/pdf', 'application/json')),
  CONSTRAINT import_committed_has_preview
    CHECK (state <> 'committed' OR previewed_at IS NOT NULL),
  CONSTRAINT import_failed_has_reason
    CHECK (state <> 'failed' OR error_message IS NOT NULL)
);

CREATE INDEX import_batch_user_idx ON broker.import_batch (user_id, created_at DESC);
CREATE INDEX import_batch_pending_idx ON broker.import_batch (created_at)
  WHERE state IN ('uploaded', 'parsing', 'previewed');
-- Re-uploading the identical file should be recognised rather than silently
-- duplicated at the row level.
CREATE INDEX import_batch_hash_idx ON broker.import_batch (account_id, content_hash);

COMMENT ON CONSTRAINT import_size_bounded ON broker.import_batch IS
  '50 MB ceiling. Parsing happens in a worker with a memory limit; an unbounded upload is a denial-of-service vector, not merely an inconvenience.';

-- ── Per-row preview outcomes ────────────────────────────────────────────────
CREATE TABLE broker.import_row (
  batch_id        uuid NOT NULL REFERENCES broker.import_batch(id) ON DELETE CASCADE,
  row_number      integer NOT NULL,
  outcome         broker.import_row_outcome NOT NULL,

  -- Parsed interpretation
  transaction_type varchar(32),
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE SET NULL,
  raw_symbol      varchar(64),
  side            reference.side,
  quantity        reference.quantity,
  price           reference.price,
  amount          reference.money,
  fees            reference.money,
  currency        reference.currency_code REFERENCES reference.currency(code),
  occurred_at     timestamptz,

  -- Why it landed where it did. A user looking at 40 skipped rows deserves a
  -- per-row reason, not a count.
  reason          varchar(120),
  duplicate_of_external_id uuid REFERENCES broker.external_transaction(id) ON DELETE SET NULL,
  -- The source line, kept verbatim for the preview UI and for debugging a
  -- mapping that went wrong.
  raw_values      jsonb NOT NULL,

  -- Set at commit, so preview and result are comparable row by row.
  created_transaction_id uuid REFERENCES broker.external_transaction(id) ON DELETE SET NULL,
  committed_at    timestamptz,

  PRIMARY KEY (batch_id, row_number),
  CONSTRAINT import_row_rejected_has_reason
    CHECK (outcome <> 'rejected' OR reason IS NOT NULL)
);

CREATE INDEX import_row_committable_idx ON broker.import_row (batch_id, row_number)
  WHERE outcome = 'create';
CREATE INDEX import_row_problems_idx ON broker.import_row (batch_id)
  WHERE outcome IN ('rejected', 'duplicate');

COMMENT ON TABLE broker.import_row IS
  'Persisted at preview time. The commit replays rows with outcome = create rather than re-deciding, which is what makes "the committed result matches the preview" a guarantee rather than an intention.';

-- ── Manual entry ────────────────────────────────────────────────────────────
-- Recorded distinctly from synced data so a later broker sync can flag, rather
-- than silently delete, a position it cannot confirm.
CREATE TABLE broker.manual_entry (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  account_id      uuid NOT NULL REFERENCES book.account(id) ON DELETE CASCADE,
  portfolio_id    uuid NOT NULL REFERENCES book.portfolio(id) ON DELETE CASCADE,
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE RESTRICT,
  -- Lot-level by design: entering an average price throws away the basis
  -- detail that realised P&L and tax reporting need.
  quantity        reference.quantity NOT NULL,
  entry_price     reference.price NOT NULL,
  acquired_on     date NOT NULL,
  fees            reference.money NOT NULL DEFAULT 0,
  currency        reference.currency_code NOT NULL REFERENCES reference.currency(code),
  note            text,
  position_lot_id uuid REFERENCES book.position_lot(id) ON DELETE SET NULL,
  -- A sync that cannot match this entry flags it here instead of removing it.
  broker_confirmed boolean,
  confirmation_checked_at timestamptz,
  flagged_unconfirmed_at timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT manual_entry_quantity_positive CHECK (quantity > 0)
);

CREATE INDEX manual_entry_portfolio_idx
  ON broker.manual_entry (portfolio_id, instrument_id);
CREATE INDEX manual_entry_unconfirmed_idx ON broker.manual_entry (account_id)
  WHERE flagged_unconfirmed_at IS NOT NULL;

COMMENT ON COLUMN broker.manual_entry.broker_confirmed IS
  'Null means never checked; false means a sync ran and could not find it. A sync must never delete a manual entry it cannot explain — it flags it and asks.';

SELECT platform.attach_touch_triggers('broker');
