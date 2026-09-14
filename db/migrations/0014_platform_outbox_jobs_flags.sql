-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0014 · Transactional outbox, job queue, idempotency, feature flags        ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- The outbox exists because "write the row and publish the event" is not
-- atomic across Postgres and Kafka. Writing the event into the same
-- transaction as the state change, and relaying it afterwards, converts a
-- lost-event bug into a delayed-event one — which is recoverable.

CREATE TABLE platform.outbox (
  id              bigserial PRIMARY KEY,
  aggregate_type  varchar(32) NOT NULL,   -- order | fill | signal | post | sync
  aggregate_id    uuid NOT NULL,
  event_type      varchar(48) NOT NULL,
  topic           varchar(64) NOT NULL,
  -- Partition key, so ordering guarantees survive the relay. Orders for one
  -- account must not be reordered on the way to Kafka.
  partition_key   text NOT NULL,
  payload         jsonb NOT NULL,
  headers         jsonb NOT NULL DEFAULT '{}'::jsonb,
  trace_id        varchar(32),
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- Relay state
  published_at    timestamptz,
  attempts        smallint NOT NULL DEFAULT 0,
  last_error      text,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  -- A message that has failed enough times is parked rather than retried
  -- forever, because a poison message otherwise stalls the whole relay.
  dead_lettered_at timestamptz
);

-- The relay's read: oldest unpublished, due now. Partial index keeps it small
-- even when the table holds months of published rows awaiting cleanup.
CREATE INDEX outbox_unpublished_idx
  ON platform.outbox (next_attempt_at, id)
  WHERE published_at IS NULL AND dead_lettered_at IS NULL;
CREATE INDEX outbox_aggregate_idx
  ON platform.outbox (aggregate_type, aggregate_id, created_at);
CREATE INDEX outbox_dead_letter_idx ON platform.outbox (dead_lettered_at DESC)
  WHERE dead_lettered_at IS NOT NULL;
-- Published rows are pruned on a schedule; this index serves that sweep.
CREATE INDEX outbox_published_idx ON platform.outbox (published_at)
  WHERE published_at IS NOT NULL;

COMMENT ON TABLE platform.outbox IS
  'Transactional outbox. Producers INSERT here inside the same transaction as the state change; the relay publishes and marks published_at. At-least-once, so every consumer must be idempotent.';

-- ── Idempotency keys ────────────────────────────────────────────────────────
-- Mobile clients retry. A retried order submission must return the original
-- result, not create a second order.
CREATE TABLE platform.idempotency_key (
  key             text PRIMARY KEY,
  user_id         uuid REFERENCES identity.user(id) ON DELETE CASCADE,
  endpoint        varchar(120) NOT NULL,
  -- Request fingerprint: the same key with a different body is a client bug
  -- and must be rejected rather than silently returning the wrong response.
  request_hash    char(64) NOT NULL,
  status_code     smallint,
  response_body   jsonb,
  -- in_progress guards the window between first request and its completion,
  -- so two concurrent retries do not both execute.
  state           varchar(16) NOT NULL DEFAULT 'in_progress',
  locked_at       timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  expires_at      timestamptz NOT NULL DEFAULT now() + INTERVAL '24 hours'
);

CREATE INDEX idempotency_expiry_idx ON platform.idempotency_key (expires_at);
CREATE INDEX idempotency_stuck_idx ON platform.idempotency_key (locked_at)
  WHERE state = 'in_progress';

-- ── Job queue (for work that must survive a restart and be auditable) ──────
-- Redis/BullMQ handles the high-churn queues; this table is for durable,
-- business-visible jobs where "did that nightly reconciliation actually run?"
-- has to be answerable months later.
CREATE TABLE platform.job (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  queue           varchar(32) NOT NULL,
  job_type        varchar(48) NOT NULL,
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
  priority        smallint NOT NULL DEFAULT 100,
  -- Deduplication for scheduled work: a nightly job must not run twice if two
  -- schedulers both wake up.
  dedupe_key      text,
  run_after       timestamptz NOT NULL DEFAULT now(),
  status          varchar(16) NOT NULL DEFAULT 'queued',
  attempts        smallint NOT NULL DEFAULT 0,
  max_attempts    smallint NOT NULL DEFAULT 3,
  -- Lease-based claiming: a worker that dies mid-job releases its lease by
  -- expiry rather than leaving the job stuck forever.
  claimed_by      varchar(64),
  claimed_at      timestamptz,
  lease_expires_at timestamptz,
  started_at      timestamptz,
  finished_at     timestamptz,
  duration_ms     integer,
  result          jsonb,
  error_class     varchar(48),
  error_message   text,
  trace_id        varchar(32),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX job_dedupe_idx ON platform.job (dedupe_key)
  WHERE dedupe_key IS NOT NULL AND status IN ('queued', 'running');
CREATE INDEX job_claimable_idx ON platform.job (queue, priority, run_after)
  WHERE status = 'queued';
CREATE INDEX job_expired_lease_idx ON platform.job (lease_expires_at)
  WHERE status = 'running';
CREATE INDEX job_recent_idx ON platform.job (job_type, created_at DESC);

-- Claim the next job atomically. SKIP LOCKED is what lets several workers
-- drain the same queue without contending on the same row.
CREATE OR REPLACE FUNCTION platform.claim_job(
  p_queue varchar(32), p_worker varchar(64), p_lease_seconds integer DEFAULT 300
) RETURNS platform.job LANGUAGE plpgsql AS $$
DECLARE claimed platform.job;
BEGIN
  UPDATE platform.job j
     SET status = 'running',
         claimed_by = p_worker,
         claimed_at = now(),
         lease_expires_at = now() + make_interval(secs => p_lease_seconds),
         started_at = coalesce(j.started_at, now()),
         attempts = j.attempts + 1
   WHERE j.id = (
     SELECT inner_j.id
       FROM platform.job inner_j
      WHERE inner_j.queue = p_queue
        AND inner_j.status = 'queued'
        AND inner_j.run_after <= now()
      ORDER BY inner_j.priority, inner_j.run_after
      FOR UPDATE SKIP LOCKED
      LIMIT 1
   )
  RETURNING * INTO claimed;
  RETURN claimed;
END $$;

-- Reclaim jobs whose worker died. Run on a schedule.
CREATE OR REPLACE FUNCTION platform.reap_expired_leases() RETURNS integer
  LANGUAGE plpgsql AS $$
DECLARE reaped integer;
BEGIN
  UPDATE platform.job
     SET status = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'queued' END,
         claimed_by = NULL,
         lease_expires_at = NULL,
         error_class = coalesce(error_class, 'lease_expired'),
         error_message = coalesce(error_message, 'worker lease expired without completion')
   WHERE status = 'running' AND lease_expires_at < now();
  GET DIAGNOSTICS reaped = ROW_COUNT;
  RETURN reaped;
END $$;

-- ── Feature flags ───────────────────────────────────────────────────────────
-- Flags carry rollout state because "on for 5% of users" and "on for this
-- account" are both things we need during a careful rollout of anything that
-- touches money.
CREATE TABLE platform.feature_flag (
  key             varchar(64) PRIMARY KEY,
  description     text NOT NULL,
  is_enabled      boolean NOT NULL DEFAULT false,
  rollout_pct     smallint NOT NULL DEFAULT 0 CHECK (rollout_pct BETWEEN 0 AND 100),
  -- Explicit allow/deny lists win over the percentage.
  enabled_user_ids  uuid[] NOT NULL DEFAULT '{}',
  disabled_user_ids uuid[] NOT NULL DEFAULT '{}',
  enabled_account_ids uuid[] NOT NULL DEFAULT '{}',
  -- Typed value for flags that are configuration rather than a boolean, e.g.
  -- the feed ranking weights.
  value           jsonb,
  -- A flag that gates anything financial requires a named owner and a
  -- removal date, so the flag set does not become permanent complexity.
  owner           varchar(64),
  expires_at      date,
  is_financial    boolean NOT NULL DEFAULT false,
  updated_by      uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT flag_financial_needs_owner
    CHECK (NOT is_financial OR (owner IS NOT NULL AND expires_at IS NOT NULL))
);

CREATE OR REPLACE FUNCTION platform.flag_enabled(
  p_key varchar(64), p_user_id uuid DEFAULT NULL, p_account_id uuid DEFAULT NULL
) RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN f.key IS NULL THEN false
    WHEN p_user_id = ANY(f.disabled_user_ids) THEN false
    WHEN p_user_id = ANY(f.enabled_user_ids) THEN true
    WHEN p_account_id = ANY(f.enabled_account_ids) THEN true
    WHEN NOT f.is_enabled THEN false
    WHEN f.rollout_pct >= 100 THEN true
    WHEN f.rollout_pct <= 0 THEN false
    -- Stable bucketing: hash the user id with the flag key so a user's bucket
    -- is consistent across requests but independent between flags.
    ELSE (abs(hashtext(f.key || coalesce(p_user_id::text, ''))) % 100) < f.rollout_pct
  END
  FROM platform.feature_flag f WHERE f.key = p_key
$$;

-- ── Rate limit counters (durable tier; Redis is the hot tier) ──────────────
CREATE TABLE platform.rate_limit_violation (
  id              bigserial PRIMARY KEY,
  subject_type    varchar(16) NOT NULL,   -- user | ip | api_key | account
  subject_id      text NOT NULL,
  endpoint        varchar(120) NOT NULL,
  limit_per_window integer NOT NULL,
  observed_count  integer NOT NULL,
  window_seconds  integer NOT NULL,
  occurred_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX rate_limit_violation_subject_idx
  ON platform.rate_limit_violation (subject_type, subject_id, occurred_at DESC);

-- ── Service registry / health (what the console's system page reads) ───────
CREATE TABLE platform.service_heartbeat (
  service         varchar(48) NOT NULL,
  instance        varchar(64) NOT NULL,
  version         varchar(40),
  status          varchar(16) NOT NULL DEFAULT 'healthy',
  details         jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (service, instance)
);

CREATE INDEX service_heartbeat_stale_idx ON platform.service_heartbeat (last_seen_at);

SELECT platform.attach_touch_triggers('platform');
