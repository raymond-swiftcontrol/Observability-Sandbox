# Self-hosting Helios

Helios is designed to run entirely on your own machine, with **no vendor API
keys and no cloud account**. Market data comes from a deterministic simulator,
orders route to an internal matching simulator, and the seed data gives you a
real instrument universe and two funded demo accounts.

This is not a degraded demo mode. It is the same code path production runs, with
the vendor and broker adapters pointed at simulators.

---

## Prerequisites

| Tool | Version | Why |
| --- | --- | --- |
| Docker | 24+ | Postgres, ClickHouse, Redis, Redpanda, MinIO, observability |
| Node | 22+ | Gateway, workers, console, mobile |
| pnpm | 10+ | Workspace management |
| Python | 3.11 | Quant and risk engines |
| Go | 1.24 | Market data ingestor, execution gateway |

You need roughly 8 GB of free RAM and 20 GB of disk for the full stack. The
`core` profile below runs in about 3 GB if that is tight.

---

## 1. First run

```bash
git clone https://github.com/raymond-swiftcontrol/Observability-Sandbox.git helios
cd helios
cp .env.example .env          # the defaults work; no keys needed

make bootstrap                # installs JS, Python and Go dependencies
make stack-up                 # brings up infrastructure and waits for health
make db-migrate               # applies every migration
make db-seed                  # reference data, demo accounts, 2y of bars
make dev                      # runs every service with hot reload
```

Then, in another terminal:

```bash
cd apps/mobile && pnpm start  # press i for iOS, a for Android, or scan with Expo Go
```

Sign in with `demo@helios.test` / `helios-demo`.

---

## 2. What you get

| Surface | URL |
| --- | --- |
| GraphQL playground | http://localhost:4000/graphql |
| REST / OpenAPI | http://localhost:4000/docs |
| Quant engine docs | http://localhost:8100/docs |
| Risk engine docs | http://localhost:8200/docs |
| Web console | http://localhost:3000 |
| Grafana | http://localhost:3001 (`admin` / `admin`) |
| Prometheus | http://localhost:9090 |
| Redpanda console | http://localhost:8080 |
| MinIO console | http://localhost:9001 (`minioadmin` / `minioadmin`) |
| Mailpit (caught email) | http://localhost:8025 |

Seeded accounts:

| Email | Role | Account |
| --- | --- | --- |
| `demo@helios.test` | trader | $100k paper margin account |
| `quant@helios.test` | pro | $250k portfolio-margin systematic book |
| `ops@helios.test` | operator | Console access, kill switch |

All three use the password `helios-demo`. The account seed **refuses to run**
unless `helios.environment` is `local` or `docker`, so it cannot be applied to a
real deployment by accident.

---

## 3. Market data without a vendor

`MARKET_DATA_MODE` controls where prices come from:

| Mode | Behaviour |
| --- | --- |
| `synthetic` | Fully local generator. Deterministic under `SIM_SEED`. **Default.** |
| `replay` | Replays a recorded session from `data/sessions/`. |
| `live` | Real vendor feeds. Requires `VENDOR_*` keys in `.env`. |

The synthetic generator produces geometric Brownian motion with regime
switching, a realistic intraday volume profile (the U-shape around the open and
close), occasional gaps, and periodic splits. Because it is seeded, two runs
produce identical data — which is what makes backtest golden-file tests possible
at all.

```bash
make synth SESSION=demo        # generate a session to data/synthetic
make replay SESSION=demo       # replay it into Kafka
```

The `vendor-sim` container also exposes a websocket at `ws://localhost:7070/stream`
that behaves like a real vendor feed, including deliberate sequence gaps and
disconnects, so the ingestor's reconnect and gap-detection paths get exercised
locally rather than only in production.

---

## 4. Trading without a broker

`BROKER_MODE=paper` (the default) routes orders to the internal simulator in
`apps/execution-gateway/internal/broker/sim`. It models partial fills, queue
position, latency and rejections against the live simulated book — so a market
order does not simply fill at the last price, and a limit order away from the
touch sits there.

Live trading is gated by **two** independent switches, both off by default:

```bash
FEATURE_LIVE_TRADING=false     # .env
```
```sql
-- and the database flag, which requires an owner and an expiry
SELECT * FROM platform.feature_flag WHERE key = 'live_trading';
```

Enabling live trading also requires a broker connection whose `can_trade` is
true and whose provider is a native integration. See
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md#6-brokerage-connectivity).

---

## 5. Running less than everything

The full stack is heavy. Docker Compose profiles let you run a subset:

```bash
# Just the database, for schema work
docker compose up -d postgres

# Core trading path: db, cache, broker, no observability
docker compose up -d postgres redis redpanda redpanda-init minio minio-init

# Add the observability stack
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d

# Everything, with the services containerised too
docker compose -f docker-compose.yml \
               -f docker-compose.observability.yml \
               -f docker-compose.apps.yml up -d
```

Optional profiles: `ha` (a Postgres read replica, to exercise replica-aware
query routing), `profiling` (Pyroscope), `loadtest` (k6).

---

## 6. Schema work without TimescaleDB

If you cannot pull the TimescaleDB image — a restricted network, an air-gapped
machine — you can still validate the schema against a vanilla Postgres 16:

```bash
make db-validate      # applies all 833 statements to a throwaway database
make db-invariants    # then runs the 40 invariant tests
```

`db/testing/timescale-shim.sql` provides the Timescale surface: hypertables
degrade to ordinary tables, policies are recorded rather than enforced, and
continuous aggregates become materialised views. Every constraint, index,
trigger, function and policy is still exercised.

**What this does not cover**, and what still needs a real TimescaleDB before you
trust a release: chunk creation and sizing, compression ratios, retention and
reorder policies actually firing, and continuous aggregates materialising. The
validator prints this caveat every run so it does not get forgotten.

---

## 7. Testing

```bash
make test             # unit: vitest + pytest + go test -race
make test-contract    # gateway ↔ service contract tests
make test-e2e         # Detox (mobile) + Playwright (console)
make backtest-golden  # regression on reference strategies
make load-test        # k6: quote fan-out, order burst
make lint             # every language
make typecheck        # TS + mypy
```

The invariant suite is the one worth running before any schema change:

```bash
make db-invariants
```

It attempts the violations rather than asserting the happy path — unbalanced
ledger transactions, illegal order transitions, automated content removal,
credential-shaped secret references, reading a feature before it was knowable.

---

## 8. Resetting

```bash
make db-reset         # nuke volumes, re-migrate, re-seed
make stack-nuke       # stop everything and destroy volumes
```

`make db-reset` is the fastest way out of a confusing state, and it is cheap:
the seed takes under a minute.

---

## 9. Configuration reference

Every setting is in `.env.example` with a comment. The ones that matter most for
self-hosting:

| Variable | Default | Notes |
| --- | --- | --- |
| `MARKET_DATA_MODE` | `replay` | Set `synthetic` for a fully offline run |
| `BROKER_MODE` | `paper` | `live` additionally requires the feature flag |
| `FEATURE_LIVE_TRADING` | `false` | Keep it false unless you mean it |
| `DATABASE_URL` | local | Point at your own Postgres if you prefer |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `localhost:4317` | Unset to disable telemetry |
| `OTEL_TRACES_SAMPLER_ARG` | `0.25` | Raise to 1.0 when debugging |
| `SIM_SEED` | `42` | Change for different synthetic data |

---

## 10. Production notes

If you are deploying this rather than running it locally, read
[`docs/DEPLOYMENT.md`](DEPLOYMENT.md) first. The short version of what changes:

- Replace every credential in `.env.example`. The defaults are deliberately
  obvious placeholders.
- `JWT_ACCESS_SECRET` and `JWT_REFRESH_SECRET` must be independent 32-byte
  random values.
- Point `DATABASE_URL` at a Postgres with real TimescaleDB, and confirm the
  compression and retention policies are actually running
  (`SELECT * FROM market.storage_report`).
- Broker credentials go in a secret store. `broker.connection.secret_ref` holds
  a reference; a real credential in that column will fail its check constraint,
  but do not rely on that as your control.
- The demo account seed will refuse to run — this is intentional. Load only
  `db/seeds/001` through `008`.

## ⚠️ A word about running this with real money

Helios is engineering infrastructure, not investment advice, and it ships with
no warranty of fitness for trading real capital. Backtested performance is not
indicative of future results. If you connect a live broker, you are responsible
for the consequences and for compliance with the rules of any venue you reach.
