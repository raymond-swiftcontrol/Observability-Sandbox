# Helios — Architecture

This document explains how Helios is put together and, more usefully, *why*.
Anywhere the design is non-obvious it is because of a specific failure we are
trying to make structurally impossible rather than merely unlikely.

---

## 1. The shape of the system

Helios is a mobile-first quant trading platform with a social layer. A trader
researches an idea, backtests it, deploys it, has orders risk-checked and
routed, watches the result, and — if they choose — shares a verified record of
what actually happened.

```
                        ┌──────────────────────────┐
   React Native  ──────▶│  api-gateway (NestJS)    │
   (Expo, iOS/Android)  │  GraphQL · REST · WS     │
                        │  authn/authz · RLS ctx   │
   web-console  ───────▶│  rate limits · idempotency│
   (Next.js, ops)       └──┬────┬────┬────┬────┬───┘
                           │    │    │    │    │
        ┌──────────────────┘    │    │    │    └──────────────────┐
        │ gRPC                  │HTTP│HTTP│ gRPC                  │ gRPC
  ┌─────▼──────────┐   ┌────────▼─┐ ┌▼──────────┐   ┌─────────────▼───┐
  │ market-data-   │   │ quant-   │ │ risk-     │   │ execution-      │
  │ ingestor (Go)  │   │ engine   │ │ engine    │◀──│ gateway (Go)    │
  │                │   │ (Python) │ │ (Python)  │   │ OMS/EMS         │
  └───────┬────────┘   └────┬─────┘ └─────┬─────┘   └────────┬────────┘
          │                 │             │                  │
          │      ┌──────────▼──┐   ┌──────▼───────┐  ┌───────▼────────┐
          │      │ social-     │   │ broker-sync  │  │ notification-  │
          │      │ service     │   │              │  │ worker         │
          │      └──────┬──────┘   └──────┬───────┘  └───────┬────────┘
          │             │                 │                  │
  ┌───────▼─────────────▼─────────────────▼──────────────────▼────────┐
  │        Redpanda / Kafka — md.* · strategy.* · oms.* · risk.*       │
  │                      social.* · broker.* · audit.*                 │
  └───┬──────────────────┬──────────────────┬─────────────────────────┘
      │                  │                  │
┌─────▼────────┐  ┌──────▼──────┐   ┌───────▼──────┐   ┌──────────────┐
│ TimescaleDB  │  │ ClickHouse  │   │    Redis     │   │  S3 / MinIO  │
│ 12 schemas   │  │ tick archive│   │ cache·queues │   │ artifacts·   │
│ 154 tables   │  │ analytics   │   │ feed·pubsub  │   │ feature store│
└──────────────┘  └─────────────┘   └──────────────┘   └──────────────┘
```

Everything emits OpenTelemetry traces, metrics and structured logs into the
collector. The repository doubles as an observability sandbox, so instrumentation
is a requirement of a service being considered done, not an afterthought.

---

## 2. Why these service boundaries

The split is by **failure domain and scaling profile**, not by noun.

**`execution-gateway` is separate from everything** because it is the only
service on the money path. Its latency budget is milliseconds, its correctness
requirements are absolute, and it must not be affected by anything else's load.
A feed of 2M quotes/second and a social fan-out storm both have to be unable to
slow down an order.

**`market-data-ingestor` is separate** because it is the highest-throughput
component by three orders of magnitude, and it is the one that benefits most
from being written in a language with predictable GC behaviour under sustained
allocation.

**`quant-engine` is separate** because backtests are long, memory-hungry, and
burstable. They belong on spot instances with a queue in front, and they must
never share a process with anything that has a latency SLO.

**`risk-engine` is separate but on the order path** — it is called synchronously
by the execution gateway before every order. This is the one place where we
deliberately accept a network hop in the hot path, because a risk check that
lives inside the OMS is a risk check that can be skipped by a code change to
the OMS.

**`social-service` is separate** because its write volume is high, its value per
write is low, and a social incident must not degrade order entry. This is the
single most important boundary in the system from an operational standpoint: it
means "the feed is down" and "you cannot trade" are independent events.

**`broker-sync` is separate from `execution-gateway`** even though both talk to
brokers, because one is latency-critical and the other runs long retrying jobs
that may back off for minutes. Sharing a process would couple them.

---

## 3. The data model

Twelve schemas in one PostgreSQL 16 + TimescaleDB instance. One database rather
than one-per-service, deliberately: the financial invariants here are
cross-entity (an order, a fill, a position, a lot and a ledger entry must agree)
and enforcing those across a network boundary means giving them up.

| Schema | Owns |
| --- | --- |
| `identity` | Users, credentials, sessions, MFA, devices, RBAC, API keys, consent |
| `reference` | Venues, calendars, instruments, derivatives, index membership, corporate actions |
| `market` | Trades, quotes, bars, L2 books, option quotes, feed health (hypertables) |
| `fundamental` | Filings, statements, ratios, estimates, events, short interest, macro |
| `book` | Accounts, double-entry ledger, cash, positions, tax lots, transfers, equity |
| `oms` | Orders, event log, fills, routing decisions, algos, execution quality |
| `research` | Strategies, versions, deployments, signals, backtests, feature store |
| `risk` | Limits, pre-trade assessments, VaR, exposure, stress, breaches, kill switch |
| `social` | Profiles, follows, posts, verified attachments, groups, DMs, moderation |
| `broker` | Provider catalogue, connections, sync cursors, reconciliation, imports |
| `platform` | Outbox, jobs, idempotency, feature flags, tenancy helpers |
| `audit` | Append-only event and change log |

### 3.1 Money is never a float

`reference.price` is `numeric(28,12)`, `reference.quantity` is `numeric(38,18)`,
`reference.money` is `numeric(28,8)`. Twelve decimal places on price because FX
minor pairs and crypto need them; eighteen on quantity because of fractional
shares and satoshis. Go uses `shopspring/decimal`, TypeScript uses
`decimal.js-light`. Float appears only in statistical computation over returns,
and must carry a comment where it does.

### 3.2 The ledger is double-entry and the database enforces it

`book.ledger_entry` carries a **deferred constraint trigger** that raises if a
transaction's signed amounts do not sum to zero within each currency. Deferred,
so legs may be inserted in any order; checked before COMMIT, so an unbalanced
transaction cannot exist.

`book.cash_balance` and `book.position` are *projections*. When a projection and
the ledger disagree, the ledger is right. Every balance shown to a user is
derivable by summing `book.ledger_entry`.

Per-currency is the subtle part: legs that net to zero overall but not within
each currency represent an **unrecorded FX conversion**, which is a real bug
that a naive total-sum check would pass.

### 3.3 Order state lives in the database

`oms.is_valid_transition` encodes the state machine; `oms.apply_order_event` is
the only sanctioned mutation path. No service writes `UPDATE oms.order SET
status`. This means a buggy service — or a broker sending callbacks out of
order — cannot drive an order into an impossible state.

The transition table deliberately permits `pending_cancel → filled`. The race
between our cancel and the venue's match is real, and a state machine that
forbade it would reject a fill that actually happened.

`oms.order_event` is the append-only source of truth; `oms.order` is a
projection maintained by trigger, so the aggregate cannot drift from its fills.

### 3.4 Market data is stored raw

Bars are stored as printed by the venue. Adjusted prices are derived on read via
`reference.adjustment_factor`, which multiplies price factors over a date range
in log space to avoid numeric drift over long histories. A late corporate action
therefore never requires rewriting history.

Only 1-minute and 1-day bars are ingested; 5m/15m/1h/1w are Timescale continuous
aggregates. Storing each resolution independently is how bar sets silently come
to disagree with one another.

Compression is segmented on `instrument_id` — the column queries filter on — and
ordered by `ts` — the column they range-scan. If a compression ratio drops below
about 5x, the first thing to check is whether `compress_segmentby` still matches
the dominant query predicate.

### 3.5 Point-in-time correctness is structural

Lookahead bias is an engineering bug here, not a statistics problem, so the
schema makes the correct query the natural one:

- `fundamental.company_snapshot.as_of` is *when the data became knowable*, not
  the period end. Research filters on it.
- `fundamental.macro_first_print` exposes vintage-1 observations only. Revised
  macro data incorporates information published later.
- `reference.index_constituent` is effective-dated, so survivorship bias cannot
  be introduced by forgetting a filter.
- `reference.resolve_symbol(symbol, as_of)` resolves a ticker as of a date, so a
  2015 backtest resolves 2015 tickers. Instruments are keyed by UUID; symbols
  are recycled after delistings and are never a key.
- `research.features_as_of()` filters on `available_at`, not `ts`. A feature
  computed from a bar is not knowable at that bar's timestamp if it carries a
  publication lag.
- Labels live in `research.label_definition`, deliberately not sharing a
  namespace with model inputs. A label is computed from the future by
  construction; letting it sit next to features is how forward returns end up as
  a model input.

---

## 4. Risk and execution

### 4.1 The pre-trade gate fails closed

`execution-gateway` calls `risk-engine` before every order, with a hard timeout.
For a **live account, an unreachable risk engine rejects the order.** Failing
open would convert an availability problem into a capital problem. Paper
accounts may fail open, with a counted metric, behind the
`pretrade_fail_open_paper` flag.

The gate returns **every rule evaluated**, not a verdict:
`risk.assessment_rule_result` stores each rule's current value, projected value,
threshold and utilisation. A rejection can therefore say *"gross exposure would
reach 3.2x against a 2.0x limit"* rather than "rejected". The same rows answer
both "why was my order rejected?" and "what did you check?".

### 4.2 The kill switch is a table, not a boolean

`risk.kill_switch` records scope, what it actually does (block new orders,
cancel working orders, liquidate), who activated it, why, and — separately — who
released it and why. Release requires a reason. There is no automatic expiry: a
switch that turns itself off is not a kill switch.

---

## 5. The social layer

### 5.1 Verification means a real fill

A trade attachment is labelled `verified` only when it references a fill that
either came from a Helios-routed order or arrived through a healthy broker sync,
with the side, instrument, price and execution time **echoed onto the attachment
at attach time**.

The verdict is resolved once and stored, never recomputed on read. Recomputing
would make read latency depend on broker availability and would let history
change under the reader. A verification timeout yields `unverified` and a
background job may later upgrade it — it must never yield `verified`.

When later broker data contradicts the claim, the badge is revoked and the
author notified. The post body is untouched: we do not silently rewrite what
someone said.

### 5.2 Notional is withheld by default

Percentage returns are computed server-side. Quantity, notional and account
equity are stripped by the serialiser unless the author's profile is at `full`
disclosure **and** the specific post opts in. Stripping is an allowlist, not a
blocklist, and the regression suite asserts on the serialised wire format rather
than on service return values — because a leak is a privacy incident, not a bug
report.

### 5.3 Feed fan-out is hybrid

Pure fan-out-on-write collapses when an author with 200k followers posts. Pure
fan-out-on-read collapses when a user follows 2k accounts. So: authors below
`feed_ranking_weights.fanout_follower_ceiling` (default 5,000) fan out on write
into Redis sorted sets; authors above it are merged in at read time from a
per-author timeline cache.

**The feed must be correct with Redis empty.** The cache is an optimisation and
never the source of truth; a cold or evicted feed rebuilds from Postgres.

Ranking penalises an author posting the same instrument repeatedly within 24
hours and rewards written rationale. Weights live in `platform.feature_flag` so
they are tunable without a deploy, and every scored request emits the component
breakdown as span attributes — "why is my feed bad" is undebuggable without it.

### 5.4 Automation may not irreversibly punish

An automated detection rule may shadow-limit, warn or clear. Only a human, or a
rule explicitly designated `auto_removable`, may remove content or suspend an
account. Enforced by a trigger on `social.moderation_action`, because the rule
depends on another table and CHECK constraints may not contain subqueries.

Reporter identity lives on `social.report` and no policy exposes it to the
reported user.

---

## 6. Brokerage connectivity

Three paths to the same destination, in descending fidelity: a native API link,
an aggregator link for the long tail, or manual import.

**Read-only is a compile-time property.** The adapter layer defines two
interfaces — `ReadOnlyBrokerAdapter` has no `submitOrder` method at all, rather
than one that refuses. An aggregator connection is typed read-only, so "this
connection cannot trade" cannot be forgotten. `broker.can_route_orders()`
requires three independent facts to agree: the connection says it may trade, the
provider supports trading, and the integration is native.

**Credentials never enter the database.** `broker.connection.secret_ref` holds a
pointer into Secrets Manager or Vault, with a shape check against the common
mistake of pasting the token into the column meant to reference it.
`broker.provider.base_url` is the only source of outbound hostnames — the SSRF
boundary for the whole sync path.

**Cost basis quality is explicit.** Every lot carries `sourced`, `reconstructed`
or `estimated`. Reconstruction from transaction history is only accepted when
replaying the history reproduces the broker's reported quantity *exactly*;
otherwise the history is not complete, a gap is recorded, and the basis falls
back to `estimated`. Quietly trusting a replay that does not reconcile is how
wrong tax numbers get shipped.

**Sync never destroys what it cannot explain.** A manually entered position the
broker does not report is retained and flagged, never deleted. Broker figures
never silently overwrite the Helios book; a discrepancy becomes a typed
reconciliation break, and only a break exactly explained by a known corporate
action is auto-resolved.

---

## 7. Eventing

`platform.outbox` implements the transactional outbox: producers insert the
event in the same transaction as the state change, and a relay publishes it.
"Write the row and publish the event" is not atomic across Postgres and Kafka,
and this converts a lost-event bug into a delayed-event one, which is
recoverable. Delivery is at-least-once, so **every consumer must be idempotent**.

Topic retention is set per topic in `scripts/init-topics.sh`: market data is
high-volume and short-retention (ClickHouse is the archive), the order plane is
90 days with ordering per account key, and `audit.events.v1` is a year.

Malformed market data goes to `helios.dlq.v1` rather than being dropped, so feed
defects are visible instead of silent.

---

## 8. Security posture

- **RLS is the second line of defence.** Every user-scoped table has a policy
  keyed on `platform.current_user_id()`, which the gateway sets per transaction
  with `SET LOCAL`. An unset context yields NULL and therefore denies — the
  correct failure direction. `FORCE ROW LEVEL SECURITY` is applied so a service
  cannot bypass by owning a table.
- Social blocks are enforced in the policy *as well as* the query layer, which
  turns a forgotten filter from a privacy incident into a missing-results bug.
- **Refresh tokens are families.** Presenting a rotated token revokes the whole
  family, which is how token theft becomes detectable rather than silent.
- Step-up MFA is required for permissions flagged `requires_step_up` — every
  action that moves money or changes a risk limit.
- `audit` grants INSERT and SELECT and revokes UPDATE/DELETE/TRUNCATE from every
  service role, so append-only is enforced by the database rather than by
  discipline. Seven-year retention.
- Secrets Manager IAM policies are scoped per service by path prefix:
  `broker-sync` cannot read the JWT signing key.

---

## 9. What is verified, and what is not

`make db-validate` applies all 833 migration statements one at a time to a
throwaway vanilla Postgres with a TimescaleDB shim. Statement-level execution
means a failure names one statement rather than one file. On its first run it
found six real bugs: four index predicates using `now()`/`CURRENT_DATE` (index
predicates must be IMMUTABLE), a foreign key declared before its target table, a
column named `overlaps` (a SQL operator keyword), and a generated column using
`timestamptz + interval`, which is STABLE rather than IMMUTABLE.

`make db-invariants` runs 40 tests that *attempt the violations*: unbalanced
ledger transactions including the per-currency case, double-posted fills,
illegal order transitions, automated content removal, self-follows, pending
follows counting as followers, verified badges without provenance, aggregator
connections routing orders, credential-shaped secret refs, reading a feature
before its `available_at`, and walk-forward folds whose test window precedes
training.

**Not covered by either**, and still requiring a real TimescaleDB run before a
release: chunk creation and sizing, compression ratios, retention and reorder
policies firing, and continuous aggregates materialising.

---

## 10. Decisions recorded elsewhere

Architecture decisions live in [`docs/adr/`](adr/). Operational procedures live
in [`docs/runbooks/`](runbooks/). Deployment is in
[`docs/DEPLOYMENT.md`](DEPLOYMENT.md), and running the whole thing on your own
machine is in [`docs/SELF_HOSTING.md`](SELF_HOSTING.md).
