#!/usr/bin/env bash
# Run every Helios service with hot reload, multiplexed into one terminal.
# Uses overmind/tmux when available, otherwise plain background jobs.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if ! docker ps --filter 'name=helios-postgres' --format '{{.Names}}' | grep -q .; then
  echo "infra not running — starting it first"; make stack-up
fi

if command -v overmind >/dev/null 2>&1; then
  exec overmind start -f Procfile.dev
fi

echo "overmind not found; falling back to background jobs (Ctrl-C stops all)"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT INT TERM

run() { printf '\033[36m▸ %s\033[0m\n' "$1"; shift; ("$@" 2>&1 | sed "s/^/[$1] /") & pids+=($!); }

run gateway      pnpm --filter @helios/api-gateway dev
run notification pnpm --filter @helios/notification-worker dev
run console      pnpm --filter @helios/web-console dev
run quant        bash -c 'cd apps/quant-engine && .venv/bin/uvicorn helios_quant.main:app --reload --port 8100'
run risk         bash -c 'cd apps/risk-engine && .venv/bin/uvicorn helios_risk.main:app --reload --port 8200'
run marketdata   bash -c 'cd apps/market-data-ingestor && go run ./cmd/ingestor'
run execution    bash -c 'cd apps/execution-gateway && go run ./cmd/gateway'
wait
