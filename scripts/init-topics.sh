#!/usr/bin/env bash
# Create the Kafka topic set with per-topic retention/compaction settings.
set -Eeuo pipefail
BROKER="${BROKER:-redpanda:9092}"
rpk() { command rpk --brokers "${BROKER}" "$@"; }

create() { # name partitions replicas extra-config...
  local name=$1 parts=$2 repl=$3; shift 3
  local args=()
  for kv in "$@"; do args+=(--topic-config "${kv}"); done
  rpk topic create "${name}" -p "${parts}" -r "${repl}" "${args[@]}" 2>/dev/null \
    && echo "  created ${name}" || echo "  exists  ${name}"
}

echo "creating Helios topics on ${BROKER}"
# Market data: high volume, short retention — ClickHouse is the archive.
create md.ticks.v1            24 1 retention.ms=3600000     compression.type=zstd
create md.bars.v1             12 1 retention.ms=604800000   compression.type=zstd
create md.book.snapshots.v1   12 1 retention.ms=1800000     cleanup.policy=delete
create md.corporate-actions.v1 3 1 cleanup.policy=compact
# Strategy plane
create strategy.signals.v1     6 1 retention.ms=2592000000
create strategy.state.v1       6 1 cleanup.policy=compact
create features.computed.v1   12 1 retention.ms=604800000
# Order plane: long retention, ordering per account key matters.
create oms.orders.v1           12 1 retention.ms=7776000000  min.insync.replicas=1
create oms.fills.v1            12 1 retention.ms=7776000000
create oms.rejections.v1        3 1 retention.ms=7776000000
# Risk + notifications
create risk.assessments.v1      6 1 retention.ms=2592000000
create risk.breaches.v1         3 1 retention.ms=7776000000
create notifications.outbound.v1 6 1 retention.ms=604800000
# Dead letter + audit
create helios.dlq.v1            3 1 retention.ms=2592000000
create audit.events.v1          6 1 retention.ms=31536000000 compression.type=zstd

echo "topics:"; rpk topic list
