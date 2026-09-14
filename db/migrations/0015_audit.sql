-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0015 · Append-only audit trail                                           ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Two distinct needs, so two mechanisms:
--   • audit.event   — deliberate, semantic records ("this user released the
--                     kill switch"), written by services with intent.
--   • audit.change  — automatic row-level before/after capture on the tables
--                     where an undetected mutation would be a serious problem.
-- Neither is ever updated or deleted; the grants below make that structural
-- rather than a matter of discipline.

CREATE TYPE audit.actor_kind AS ENUM ('user', 'service', 'system', 'admin', 'broker');

CREATE TABLE audit.event (
  id              bigserial PRIMARY KEY,
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  -- Actor
  actor_kind      audit.actor_kind NOT NULL,
  actor_user_id   uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  actor_service   varchar(48),
  -- Impersonation has to be visible: "support acting as user X" is a different
  -- event from "user X did this", and conflating them defeats the audit.
  on_behalf_of_user_id uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  -- What
  action          varchar(64) NOT NULL,     -- order.submitted, limit.relaxed…
  resource_type   varchar(48) NOT NULL,
  resource_id     text,
  outcome         varchar(16) NOT NULL DEFAULT 'success',
  -- Context
  summary         text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip_address      inet,
  user_agent      text,
  request_id      text,
  trace_id        varchar(32),
  session_id      uuid,
  -- Severity drives retention and whether it reaches the security channel.
  severity        varchar(12) NOT NULL DEFAULT 'info',
  is_sensitive    boolean NOT NULL DEFAULT false
);

SELECT create_hypertable('audit.event', 'occurred_at',
  chunk_time_interval => INTERVAL '30 days',
  migrate_data => true);

CREATE INDEX audit_event_actor_idx
  ON audit.event (actor_user_id, occurred_at DESC) WHERE actor_user_id IS NOT NULL;
CREATE INDEX audit_event_resource_idx
  ON audit.event (resource_type, resource_id, occurred_at DESC);
CREATE INDEX audit_event_action_idx ON audit.event (action, occurred_at DESC);
CREATE INDEX audit_event_trace_idx ON audit.event (trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX audit_event_sensitive_idx ON audit.event (occurred_at DESC)
  WHERE is_sensitive;

ALTER TABLE audit.event SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'action, resource_type',
  timescaledb.compress_orderby   = 'occurred_at DESC'
);
SELECT add_compression_policy('audit.event', INTERVAL '90 days');
-- Seven years: the retention floor for trading records in most jurisdictions
-- we would operate in. Deliberately longer than anything else in the system.
SELECT add_retention_policy('audit.event', INTERVAL '7 years');

-- ── Automatic row-level change capture ─────────────────────────────────────
CREATE TABLE audit.change (
  id              bigserial PRIMARY KEY,
  changed_at      timestamptz NOT NULL DEFAULT now(),
  schema_name     text NOT NULL,
  table_name      text NOT NULL,
  record_id       text NOT NULL,
  operation       char(1) NOT NULL CHECK (operation IN ('I', 'U', 'D')),
  -- Only the columns that actually changed, for UPDATE. Storing whole rows on
  -- a busy table turns the audit log into the largest table in the database.
  changed_columns text[],
  old_values      jsonb,
  new_values      jsonb,
  actor_user_id   uuid,
  actor_role      text NOT NULL DEFAULT current_user,
  request_id      text,
  trace_id        varchar(32)
);

SELECT create_hypertable('audit.change', 'changed_at',
  chunk_time_interval => INTERVAL '30 days',
  migrate_data => true);

CREATE INDEX audit_change_record_idx
  ON audit.change (schema_name, table_name, record_id, changed_at DESC);
CREATE INDEX audit_change_actor_idx
  ON audit.change (actor_user_id, changed_at DESC) WHERE actor_user_id IS NOT NULL;

ALTER TABLE audit.change SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'schema_name, table_name',
  timescaledb.compress_orderby   = 'changed_at DESC'
);
SELECT add_compression_policy('audit.change', INTERVAL '30 days');
SELECT add_retention_policy('audit.change', INTERVAL '7 years');

-- The capture trigger. Column-diffing on UPDATE keeps the volume proportional
-- to real change rather than to write traffic.
CREATE OR REPLACE FUNCTION audit.capture_change() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  old_json   jsonb;
  new_json   jsonb;
  changed    text[];
  rec_id     text;
  -- Columns never worth auditing: they change on every write and carry no
  -- decision-relevant information.
  ignored    constant text[] := ARRAY['updated_at', 'last_seen_at', 'marked_at'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    old_json := to_jsonb(OLD);
    rec_id   := coalesce(old_json->>'id', old_json->>'public_id', '(composite)');
    INSERT INTO audit.change (schema_name, table_name, record_id, operation,
                              old_values, actor_user_id, request_id)
    VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, rec_id, 'D',
            old_json, platform.current_user_id(), platform.current_request_id());
    RETURN OLD;
  END IF;

  new_json := to_jsonb(NEW);
  rec_id   := coalesce(new_json->>'id', new_json->>'public_id', '(composite)');

  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit.change (schema_name, table_name, record_id, operation,
                              new_values, actor_user_id, request_id)
    VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, rec_id, 'I',
            new_json, platform.current_user_id(), platform.current_request_id());
    RETURN NEW;
  END IF;

  old_json := to_jsonb(OLD);
  SELECT array_agg(key) INTO changed
    FROM jsonb_each(new_json) n
   WHERE NOT (n.key = ANY(ignored))
     AND n.value IS DISTINCT FROM (old_json -> n.key);

  -- Nothing of substance changed; do not manufacture an audit row.
  IF changed IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO audit.change (schema_name, table_name, record_id, operation,
                            changed_columns, old_values, new_values,
                            actor_user_id, request_id)
  VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, rec_id, 'U', changed,
          (SELECT jsonb_object_agg(k, old_json -> k) FROM unnest(changed) k),
          (SELECT jsonb_object_agg(k, new_json -> k) FROM unnest(changed) k),
          platform.current_user_id(), platform.current_request_id());
  RETURN NEW;
END $$;

-- Attach to the tables where an unexplained mutation would be serious. Market
-- data and feature values are deliberately excluded: they are append-only and
-- auditing them would multiply the largest tables in the system.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'identity.user', 'identity.credential', 'identity.user_role', 'identity.api_key',
    'book.account', 'book.portfolio', 'book.broker_connection', 'book.transfer',
    'oms.order',
    'research.deployment',
    'risk.limit_rule', 'risk.kill_switch',
    'platform.feature_flag'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_audit_change
         AFTER INSERT OR UPDATE OR DELETE ON %s
         FOR EACH ROW EXECUTE FUNCTION audit.capture_change()', t);
  END LOOP;
END $$;

-- Convenience writer so services do not hand-assemble inserts.
CREATE OR REPLACE FUNCTION audit.record(
  p_action        varchar(64),
  p_resource_type varchar(48),
  p_resource_id   text DEFAULT NULL,
  p_summary       text DEFAULT NULL,
  p_metadata      jsonb DEFAULT '{}'::jsonb,
  p_severity      varchar(12) DEFAULT 'info',
  p_sensitive     boolean DEFAULT false
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE new_id bigint;
BEGIN
  INSERT INTO audit.event (
    actor_kind, actor_user_id, actor_service, action, resource_type, resource_id,
    summary, metadata, request_id, severity, is_sensitive
  ) VALUES (
    CASE WHEN platform.current_user_id() IS NOT NULL THEN 'user'::audit.actor_kind
         ELSE 'service'::audit.actor_kind END,
    platform.current_user_id(),
    current_user,
    p_action, p_resource_type, p_resource_id, p_summary, p_metadata,
    platform.current_request_id(), p_severity, p_sensitive
  ) RETURNING id INTO new_id;
  RETURN new_id;
END $$;

-- Append-only, structurally. Services get INSERT and SELECT and nothing else,
-- so a compromised service role cannot rewrite history.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    'helios_gateway', 'helios_marketdata', 'helios_quant',
    'helios_risk', 'helios_execution', 'helios_notify'
  ] LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA audit TO %I', r);
    EXECUTE format('GRANT INSERT, SELECT ON audit.event, audit.change TO %I', r);
    EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON audit.event, audit.change FROM %I', r);
  END LOOP;
  EXECUTE 'GRANT USAGE ON SCHEMA audit TO helios_readonly';
  EXECUTE 'GRANT SELECT ON audit.event, audit.change TO helios_readonly';
END $$;

COMMENT ON SCHEMA audit IS
  'Append-only. INSERT and SELECT are granted; UPDATE, DELETE and TRUNCATE are revoked from every service role, so immutability is enforced by the database rather than by convention.';
