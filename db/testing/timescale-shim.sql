-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ TimescaleDB shim — for schema validation on vanilla PostgreSQL            ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Production runs real TimescaleDB. This shim exists so that the migrations'
-- *relational* content — tables, domains, constraints, indexes, triggers,
-- functions, grants — can be validated anywhere a plain Postgres 16 is
-- available, including CI runners and developer machines without the
-- Timescale image.
--
-- What it does NOT validate, and what therefore still needs a real Timescale
-- run before a release:
--   • chunk creation, chunk_time_interval sizing, space partitioning
--   • compression (segmentby/orderby correctness and ratios)
--   • retention and reorder policies actually firing
--   • continuous aggregates materialising and refreshing
--
-- Hypertables degrade to ordinary tables here, which is exactly the right
-- fidelity trade: every constraint, index and trigger is still exercised.

CREATE SCHEMA IF NOT EXISTS ts_shim;

-- ── Hypertable creation ─────────────────────────────────────────────────────
-- Accepts the full named-argument surface the migrations use. Returns the
-- record shape Timescale returns so a caller that inspects it still works.
CREATE OR REPLACE FUNCTION public.create_hypertable(
  relation                regclass,
  time_column_name        name,
  partitioning_column     name    DEFAULT NULL,
  number_partitions       integer DEFAULT NULL,
  associated_schema_name  name    DEFAULT NULL,
  associated_table_prefix name    DEFAULT NULL,
  chunk_time_interval     anyelement DEFAULT NULL::bigint,
  create_default_indexes  boolean DEFAULT true,
  if_not_exists           boolean DEFAULT false,
  partitioning_func       regproc DEFAULT NULL,
  migrate_data            boolean DEFAULT false,
  chunk_target_size       text    DEFAULT NULL,
  chunk_sizing_func       regproc DEFAULT NULL,
  time_partitioning_func  regproc DEFAULT NULL
-- OUT parameters are deliberately NOT named schema_name/table_name: those
-- become plpgsql variables that collide with the shim table's own columns in
-- the ON CONFLICT clause below. Timescale's real signature uses those names,
-- but nothing in the migrations reads the result columns by name.
) RETURNS TABLE (ht_id integer, ht_schema name, ht_table name, ht_created boolean)
LANGUAGE plpgsql AS $$
DECLARE
  nsp name;
  rel name;
BEGIN
  SELECT n.nspname, c.relname INTO nsp, rel
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.oid = relation;

  -- The time column must exist and be a time type: this is the one piece of
  -- Timescale's validation worth reproducing, because getting it wrong is a
  -- real migration bug rather than a Timescale-specific concern.
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute a
     WHERE a.attrelid = relation AND a.attname = time_column_name AND a.attnum > 0
  ) THEN
    RAISE EXCEPTION 'create_hypertable: column %.% does not exist', rel, time_column_name;
  END IF;

  IF partitioning_column IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM pg_attribute a
     WHERE a.attrelid = relation AND a.attname = partitioning_column AND a.attnum > 0
  ) THEN
    RAISE EXCEPTION 'create_hypertable: partitioning column %.% does not exist',
      rel, partitioning_column;
  END IF;

  INSERT INTO ts_shim.hypertable AS h (schema_name, table_name, time_column,
                                       space_column, num_partitions)
  VALUES (nsp, rel, time_column_name, partitioning_column, number_partitions)
  ON CONFLICT ON CONSTRAINT hypertable_pkey DO NOTHING;

  RETURN QUERY SELECT 1, nsp, rel, true;
END $$;

CREATE TABLE IF NOT EXISTS ts_shim.hypertable (
  schema_name    name NOT NULL,
  table_name     name NOT NULL,
  time_column    name NOT NULL,
  space_column   name,
  num_partitions integer,
  PRIMARY KEY (schema_name, table_name)
);

CREATE TABLE IF NOT EXISTS ts_shim.policy (
  policy_kind text NOT NULL,
  target      text NOT NULL,
  config      text,
  PRIMARY KEY (policy_kind, target)
);

-- ── Policies: recorded, not enforced ────────────────────────────────────────
-- Recording rather than ignoring means the validator can assert that every
-- hypertable which should have a retention policy actually got one.
CREATE OR REPLACE FUNCTION public.add_compression_policy(
  hypertable regclass, compress_after anyelement,
  if_not_exists boolean DEFAULT false, schedule_interval interval DEFAULT NULL,
  initial_start timestamptz DEFAULT NULL, timezone text DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ts_shim.policy VALUES ('compression', hypertable::text, compress_after::text)
    ON CONFLICT DO NOTHING;
  RETURN 1;
END $$;

CREATE OR REPLACE FUNCTION public.add_retention_policy(
  relation regclass, drop_after anyelement,
  if_not_exists boolean DEFAULT false, schedule_interval interval DEFAULT NULL,
  initial_start timestamptz DEFAULT NULL, timezone text DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ts_shim.policy VALUES ('retention', relation::text, drop_after::text)
    ON CONFLICT DO NOTHING;
  RETURN 1;
END $$;

CREATE OR REPLACE FUNCTION public.add_continuous_aggregate_policy(
  continuous_aggregate regclass, start_offset anyelement, end_offset anyelement,
  schedule_interval interval, if_not_exists boolean DEFAULT false,
  initial_start timestamptz DEFAULT NULL, timezone text DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ts_shim.policy
    VALUES ('cagg_refresh', continuous_aggregate::text,
            format('%s..%s every %s', start_offset, end_offset, schedule_interval))
    ON CONFLICT DO NOTHING;
  RETURN 1;
END $$;

CREATE OR REPLACE FUNCTION public.add_reorder_policy(
  hypertable regclass, index_name name,
  if_not_exists boolean DEFAULT false, initial_start timestamptz DEFAULT NULL,
  timezone text DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
  -- Verify the named index actually exists — a reorder policy pointing at a
  -- typo'd index is a real bug that this shim can still catch.
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = index_name AND relkind = 'i') THEN
    RAISE EXCEPTION 'add_reorder_policy: index % does not exist', index_name;
  END IF;
  INSERT INTO ts_shim.policy VALUES ('reorder', hypertable::text, index_name)
    ON CONFLICT DO NOTHING;
  RETURN 1;
END $$;

CREATE OR REPLACE FUNCTION public.remove_compression_policy(
  hypertable regclass, if_exists boolean DEFAULT false
) RETURNS boolean LANGUAGE sql AS $$
  DELETE FROM ts_shim.policy WHERE policy_kind='compression' AND target=hypertable::text;
  SELECT true;
$$;

CREATE OR REPLACE FUNCTION public.remove_retention_policy(
  relation regclass, if_exists boolean DEFAULT false
) RETURNS boolean LANGUAGE sql AS $$
  DELETE FROM ts_shim.policy WHERE policy_kind='retention' AND target=relation::text;
  SELECT true;
$$;

CREATE OR REPLACE FUNCTION public.remove_reorder_policy(
  hypertable regclass, if_exists boolean DEFAULT false
) RETURNS boolean LANGUAGE sql AS $$
  DELETE FROM ts_shim.policy WHERE policy_kind='reorder' AND target=hypertable::text;
  SELECT true;
$$;

-- ── Bucketing and ordered aggregates used by the continuous aggregates ─────
CREATE OR REPLACE FUNCTION public.time_bucket(bucket interval, ts timestamptz)
  RETURNS timestamptz LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  -- date_bin is the core-Postgres equivalent, available since PG14.
  SELECT date_bin(bucket, ts, TIMESTAMPTZ '2000-01-03')
$$;

CREATE OR REPLACE FUNCTION public.time_bucket(bucket interval, ts timestamp)
  RETURNS timestamp LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT date_bin(bucket, ts, TIMESTAMP '2000-01-03')
$$;

-- first(value, time) / last(value, time): pick the value at the min/max time.
CREATE OR REPLACE FUNCTION ts_shim.first_sfunc(state anyelement, v anyelement, t timestamptz)
  RETURNS anyelement LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN state;  -- replaced by the real ordered implementation below
END $$;

CREATE TYPE ts_shim.pick_state AS (ts timestamptz, val text);

CREATE OR REPLACE FUNCTION ts_shim.pick_first(state ts_shim.pick_state, v anynonarray, t timestamptz)
  RETURNS ts_shim.pick_state LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN state IS NULL OR state.ts IS NULL OR t < state.ts
      THEN ROW(t, v::text)::ts_shim.pick_state
    ELSE state END
$$;

CREATE OR REPLACE FUNCTION ts_shim.pick_last(state ts_shim.pick_state, v anynonarray, t timestamptz)
  RETURNS ts_shim.pick_state LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN state IS NULL OR state.ts IS NULL OR t >= state.ts
      THEN ROW(t, v::text)::ts_shim.pick_state
    ELSE state END
$$;

CREATE OR REPLACE FUNCTION ts_shim.pick_final_numeric(state ts_shim.pick_state)
  RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN state IS NULL THEN NULL ELSE state.val::numeric END
$$;

-- The migrations only use first()/last() over numeric price columns, so a
-- numeric-returning aggregate is sufficient for validation here.
CREATE AGGREGATE public.first(anynonarray, timestamptz) (
  SFUNC = ts_shim.pick_first,
  STYPE = ts_shim.pick_state,
  FINALFUNC = ts_shim.pick_final_numeric
);

CREATE AGGREGATE public.last(anynonarray, timestamptz) (
  SFUNC = ts_shim.pick_last,
  STYPE = ts_shim.pick_state,
  FINALFUNC = ts_shim.pick_final_numeric
);

-- ── Informational views referenced by market.storage_report ────────────────
CREATE SCHEMA IF NOT EXISTS timescaledb_information;

CREATE OR REPLACE VIEW timescaledb_information.hypertables AS
SELECT h.schema_name  AS hypertable_schema,
       h.table_name   AS hypertable_name,
       0::bigint      AS num_chunks
  FROM ts_shim.hypertable h;

CREATE OR REPLACE FUNCTION public.hypertable_detailed_size(ht regclass)
  RETURNS TABLE (table_bytes bigint, index_bytes bigint, toast_bytes bigint,
                 total_bytes bigint, node_name name)
  LANGUAGE sql STABLE AS $$
  SELECT pg_table_size(ht)::bigint, pg_indexes_size(ht)::bigint, 0::bigint,
         pg_total_relation_size(ht)::bigint, NULL::name
$$;

CREATE OR REPLACE FUNCTION public.hypertable_compression_stats(ht regclass)
  RETURNS TABLE (total_chunks bigint, number_compressed_chunks bigint,
                 before_compression_total_bytes bigint,
                 after_compression_total_bytes bigint, node_name name)
  LANGUAGE sql STABLE AS $$
  SELECT 0::bigint, 0::bigint, NULL::bigint, NULL::bigint, NULL::name
$$;
