<div align="center">

# ☀️ Helios

**A quantitative trading platform for systematic traders — mobile first.**

Research → backtest → risk-check → execute → monitor, on one event-driven spine.

[![CI](https://github.com/raymond-swiftcontrol/Observability-Sandbox/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
[![Infra Plan](https://github.com/raymond-swiftcontrol/Observability-Sandbox/actions/workflows/infra-plan.yml/badge.svg)](.github/workflows/infra-plan.yml)

</div>

---

## What this is

Helios is a full-stack, polyglot trading platform built around a React Native mobile
client. It is designed as a *realistic* quant stack rather than a toy: market data
ingestion, a feature store, a vectorised backtester, a portfolio optimiser, a
pre-trade risk gate, an order management system, and a streaming notification layer —
all wired through Kafka and observable end-to-end with OpenTelemetry.

The repository doubles as an **observability sandbox**: every service emits traces,
metrics and structured logs, and `infra/observability` ships the Grafana/Tempo/Loki/
Prometheus stack plus pre-built dashboards and SLO alert rules.

## Who it's for

| Persona | What Helios gives them |
| --- | --- |
| Systematic retail trader | Strategy library, backtests on their phone, paper + live routing |
| Discretionary trader w/ quant leanings | Factor dashboards, regime signals, options greeks, risk limits |
| Small prop desk | Multi-account books, per-desk risk limits, kill switch, audit trail |
| Platform engineer | A non-trivial, instrumented, deployable distributed system |

## Feature surface

**Market data** — multi-venue normalisation (equities, FX, crypto, options), L1/L2 books,
tick→bar aggregation in 8 resolutions, corporate-action adjustment, replay harness.

**Research** — 60+ engineered features, a point-in-time-correct feature store on Parquet,
cross-sectional factor models, regime detection (HMM), walk-forward cross-validation.

**Backtesting** — event-driven and vectorised engines, realistic slippage/fee/borrow
models, intraday fill simulation against L2 snapshots, 40+ performance statistics,
Monte-Carlo robustness, parameter sweeps on a distributed worker pool.

**Portfolio** — mean-variance, risk parity, hierarchical risk parity, Black-Litterman,
Kelly sizing with drawdown guards, turnover-aware rebalancing.

**Risk** — historical / parametric / Monte-Carlo VaR, expected shortfall, Black-Scholes
and binomial greeks, factor exposure decomposition, stress scenarios, pre-trade limit
checks and a desk-level kill switch.

**Execution** — OMS/EMS with a smart order router, TWAP/VWAP/POV/Iceberg algos,
idempotent order lifecycle, broker adapters (Alpaca, IBKR, Binance, internal simulator).

**Mobile** — 30+ screens: watchlists, Skia-rendered candlestick/depth charts, order
ticket with risk preview, positions & P&L, strategy monitor, backtest explorer, alerts,
biometric unlock, offline cache.

## Architecture at a glance

```
                     ┌──────────────────────────────────────────┐
  React Native  ───▶ │  api-gateway (NestJS · GraphQL + REST)   │
  (Expo, iOS/Android)│  auth · BFF · subscriptions · rate limit │
                     └───┬───────────┬───────────┬──────────────┘
                         │ gRPC      │ HTTP      │ gRPC
           ┌─────────────▼──┐  ┌─────▼───────┐  ┌▼────────────────┐
           │ market-data    │  │ quant-engine│  │ execution-      │
           │ ingestor (Go)  │  │ (Python)    │  │ gateway (Go)    │
           └───────┬────────┘  └──────┬──────┘  └────────┬────────┘
                   │                  │                  │
                   │            ┌─────▼──────┐           │
                   │            │ risk-engine│◀──────────┘
                   │            │ (Python)   │  pre-trade gate
                   │            └─────┬──────┘
     ┌─────────────▼──────────────────▼───────────────────────────┐
     │          Redpanda / Kafka  —  md.* · strategy.* · oms.*     │
     └──────┬────────────────┬─────────────────┬──────────────────┘
            │                │                 │
    ┌───────▼──────┐ ┌───────▼──────┐ ┌────────▼─────────┐
    │ TimescaleDB  │ │  ClickHouse  │ │ notification-    │
    │ (OLTP + TS)  │ │ (tick/analytics)│ worker (BullMQ) │
    └──────────────┘ └──────────────┘ └──────────────────┘
```

Full detail, including data-flow walkthroughs and failure modes, lives in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Decisions are recorded as ADRs in
[`docs/adr/`](docs/adr/).

## Repository layout

```
apps/
  mobile/                 React Native + Expo client (expo-router, Skia charts)
  api-gateway/            NestJS BFF — GraphQL, REST, WS subscriptions, authZ
  market-data-ingestor/   Go — vendor WS fan-in, normalisation, bar aggregation
  quant-engine/           Python FastAPI — features, backtests, optimisation
  risk-engine/            Python FastAPI — VaR, greeks, limits, stress tests
  execution-gateway/       Go — OMS/EMS, smart order router, broker adapters
  notification-worker/    TypeScript — alert evaluation, push/email fan-out
  web-console/            Next.js — desk operations & admin console
packages/
  shared-types/           Zod-first domain contracts shared across TS services
  quant-core/             Pure-TS quant math (indicators, stats, sizing)
  ui-kit/                 Cross-platform design system (RN + RN-web)
  sdk/                    Typed client for the Helios API
  observability/          OTel bootstrap, logger, metric helpers
db/
  migrations/             Forward-only SQL migrations (Postgres 16 + Timescale)
  seeds/                  Reference + demo data
  analytics/              ClickHouse DDL and materialised views
infra/
  terraform/              AWS: VPC, EKS, Aurora, MSK, ElastiCache, S3, IAM…
  k8s/ · helm/            Deployment manifests and the Helios umbrella chart
  observability/          Prometheus, Tempo, Loki, Grafana dashboards, SLOs
docs/                     Architecture, runbooks, ADRs, data dictionary
scripts/                  Developer tooling (migrate, seed, replay, load-test)
```

## Quick start

```bash
# 1. prerequisites: docker, node 22+, pnpm 10, python 3.11, go 1.24
cp .env.example .env
make bootstrap          # installs JS/Python/Go deps, builds packages

# 2. bring up infrastructure (postgres+timescale, redpanda, redis, clickhouse, minio)
make stack-up
make db-migrate
make db-seed            # ~8k instruments, 3 demo accounts, 2y of daily bars

# 3. run the services
make dev                # all services with hot reload via turbo + air + uvicorn

# 4. run the mobile app
cd apps/mobile && pnpm start       # then press i / a, or scan with Expo Go
```

Useful entry points once the stack is up:

| Surface | URL |
| --- | --- |
| GraphQL playground | http://localhost:4000/graphql |
| REST / OpenAPI docs | http://localhost:4000/docs |
| Quant engine docs | http://localhost:8100/docs |
| Risk engine docs | http://localhost:8200/docs |
| Web console | http://localhost:3000 |
| Grafana | http://localhost:3001 (`admin` / `admin`) |
| Redpanda console | http://localhost:8080 |

## Deploying

```bash
make infra-plan ENV=staging      # terraform plan against the staging workspace
make infra-apply ENV=staging
make deploy ENV=staging          # helm upgrade --install of the umbrella chart
make mobile-release CHANNEL=beta # EAS build + submit, OTA update
```

The full procedure — including the blue/green cutover, migration gating and rollback
drill — is in [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md), and incident playbooks are in
[`docs/runbooks/`](docs/runbooks/).

## Testing

```bash
make test           # unit: vitest + pytest + go test
make test-contract  # pact-style contract tests between gateway and services
make test-e2e       # detox (mobile) + playwright (console) against ephemeral stack
make backtest-golden # regression: golden-file check on reference strategies
make load-test      # k6 scenarios: quote fan-out, order burst, backtest storm
```

## ⚠️ Disclaimer

Helios is engineering infrastructure, **not** investment advice, and ships with no
warranty of fitness for trading real capital. Live trading is gated behind
`FEATURE_LIVE_TRADING` plus a broker credential you must supply yourself. Backtested
performance is not indicative of future results. You are responsible for compliance
with the rules of any venue you connect to.
